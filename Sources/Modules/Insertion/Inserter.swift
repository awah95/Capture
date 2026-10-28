import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class Inserter: TextInserting {
    private nonisolated static let pasteKeyCode: CGKeyCode = 9
    private nonisolated static let pasteboardRestoreDelayNanoseconds: UInt64 = 300_000_000

    /// Everything that touches the system, in one place.
    ///
    /// The ladder cannot be tested through the real implementations: it posts ⌘V into
    /// whatever app is frontmost and rewrites the pasteboard. With the system behind
    /// these five closures, the claims that matter — nothing inserted *and* nothing
    /// copied into a secure field, an unconfirmed paste leaving the transcript on the
    /// clipboard — become things a test executes rather than things a reader believes.
    struct Environment {
        var accessibilityTrusted: () -> Bool
        var focusedTarget: () -> InsertionTarget?
        /// Pinned vocabulary terms, whose capitalization is never second-guessed (§8).
        var pinnedTerms: () -> Set<String>
        /// Returns the closure that posts ⌘V, or nil when the events cannot be built —
        /// which is what `cgEventAvailable` means to the plan.
        var makePaste: () -> (() -> Void)?
        /// The wait for the paste to land, before the read-back and the restore.
        var pasteSettleDelay: () async -> Void
        var selectionContext: @MainActor (String?) -> Task<ContextSnapshot, Never> = { bundle in
            var mode = Mode.clean
            mode.contextOptions.selectedText = true
            let request = ContextCaptureRequest(initialMode: mode, explicitModeID: mode.id,
                targetBundleID: bundle, appMap: [:], websiteMap: [:], defaultModeID: mode.id,
                availableModes: [mode])
            return ContextCollector.start(bundleID: bundle, request: request)
        }


        static func live(pinnedTerms: @escaping () -> Set<String> = { [] }) -> Environment {
            Environment(
                accessibilityTrusted: { AXIsProcessTrusted() },
                focusedTarget: { AXFocus.focusedTarget() },
                pinnedTerms: pinnedTerms,
                makePaste: {
                    guard let events = Inserter.makePasteEvents() else { return nil }
                    return {
                        events.keyDown.post(tap: .cghidEventTap)
                        events.keyUp.post(tap: .cghidEventTap)
                    }
                },
                pasteSettleDelay: {
                    try? await Task.sleep(
                        nanoseconds: Inserter.pasteboardRestoreDelayNanoseconds)
                }
            )
        }
    }

    private let pasteboard: NSPasteboard
    private let clipboardPublisher: ClipboardPublisher
    private let environment: Environment

    init(pasteboard: NSPasteboard = .general, environment: Environment = .live()) {
        self.pasteboard = pasteboard
        self.environment = environment
        clipboardPublisher = ClipboardPublisher(pasteboard: pasteboard)
    }

    func hasAccessibilityPermission() -> Bool {
        environment.accessibilityTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func frontmostAppBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    func insertSelectionEdit(_ text: String, originalSelection: String, targetBundleID: String?) async -> InsertionOutcome {
        // A no-op or failed edit already has its desired text in place. Do not run
        // read-back/paste fallback: unchanged content cannot confirm a write.
        guard text != originalSelection else { return .insertedDirect }
        let current = await ContextCollector.value(of: environment.selectionContext(targetBundleID))
        if current.protectedField && !current.targetUnavailable { return .refusedSecureField }
        guard !current.targetUnavailable, !current.selectionTruncated,
              current.selectedText == originalSelection else {
            return publishFallback(text, captureID: UUID(), reason: "selection changed — the edited text is on your clipboard")
        }
        return await insert(text, preserveFormatting: true)
    }

    func insert(_ text: String) async -> InsertionOutcome {
        await insert(text, preserveFormatting: false)
    }

    private func insert(_ text: String, preserveFormatting: Bool) async -> InsertionOutcome {
        let captureID = UUID()
        let axTrusted = environment.accessibilityTrusted()
        let focused = axTrusted ? environment.focusedTarget() : nil
        let focusedKind = focused?.kind ?? .none

        // Read the caret's context before anything is written, and never from a secure
        // field: asking a password box for the character before the caret is reading the
        // password, which is the opposite of what the refusal below promises.
        let precedingCharacter = focusedKind == .secure ? nil : focused?.precedingCharacter()
        let payload = preserveFormatting ? text : InsertionContext.payload(
            text,
            precedingCharacter: precedingCharacter,
            pinnedTerms: environment.pinnedTerms()
        )

        let axWrite: AXWriteResult
        if let focused, focusedKind != .secure {
            axWrite = focused.write(payload)
        } else {
            axWrite = .notAttempted
        }

        let postPaste: (() -> Void)?
        if focusedKind == .secure || axWrite == .confirmed {
            postPaste = nil
        } else {
            postPaste = environment.makePaste()
        }

        let plan = planInsertion(
            axTrusted: axTrusted,
            focusedElementKind: focusedKind,
            axWrite: axWrite,
            cgEventAvailable: postPaste != nil
        )

        switch plan {
        case .insertedDirect:
            return .insertedDirect

        case .refusedSecureField:
            // Two separate promises, and only one of them is about insertion: nothing is
            // typed AND nothing is copied (spec §8, §17). The pasteboard is not read,
            // written or restored on this path — it is simply left as the user left it.
            // The transcript still reaches the record log, which is what "available in
            // History" means.
            return .refusedSecureField

        case let .clipboardFallback(reason):
            return publishFallback(
                payload,
                captureID: captureID,
                reason: reason
            )

        case .pastedViaKeyboard:
            guard let postPaste else {
                return publishFallback(
                    payload,
                    captureID: captureID,
                    reason: "keyboard paste unavailable"
                )
            }

            let snapshot = PasteboardSnapshot.capture(from: pasteboard)

            pasteboard.clearContents()
            guard pasteboard.setString(payload, forType: .string),
                  pasteboard.changeCount != snapshot.changeCount else {
                return publishFallback(
                    payload,
                    captureID: captureID,
                    reason: "clipboard write failed"
                )
            }
            RecentClipboard.noteOwnChange(pasteboard)
            let insertedTextChangeCount = pasteboard.changeCount

            // Re-read focus rather than reusing the element captured above: the user
            // may have moved on while the transcript was in flight, which is the
            // normal case for anything longer than a phrase.
            let target = axTrusted ? environment.focusedTarget() : nil

            // …and where they moved on to may be a password box. ⌘V would type the
            // transcript straight into it, so this is the one refusal that has to clean
            // up after itself: the transcript is already on the pasteboard by now.
            if target?.kind == .secure {
                restorePasteboardIfOwned(
                    pasteboard,
                    snapshot: snapshot,
                    ownedChangeCount: insertedTextChangeCount
                )
                return .refusedSecureField
            }

            let before = target?.textValue()

            postPaste()

            await environment.pasteSettleDelay()

            let after = target?.textValue()
            let pasteConfirmed = before != nil && after != nil && before != after

            // Restoring the previous clipboard is right only when the paste is known
            // to have landed. When it cannot be confirmed, the transcript stays on
            // the clipboard: a replaced clipboard is a nuisance, a dictation that
            // exists nowhere is the failure this whole ladder exists to prevent.
            guard pasteConfirmed else {
                return .clipboardFallback(
                    reason: "paste could not be confirmed — the text is on your clipboard")
            }

            restorePasteboardIfOwned(
                pasteboard,
                snapshot: snapshot,
                ownedChangeCount: insertedTextChangeCount
            )

            return .pastedViaKeyboard
        }
    }

    private func publishFallback(
        _ text: String,
        captureID: UUID,
        reason: String
    ) -> InsertionOutcome {
        clipboardPublisher.publish(
            text,
            captureID: captureID,
            isFinal: true
        )
        return .clipboardFallback(reason: reason)
    }

    /// Nonisolated because the live `Environment` builds its paste closure outside the
    /// main actor; constructing CGEvents touches no shared state.
    private nonisolated static func makePasteEvents() -> (keyDown: CGEvent, keyUp: CGEvent)? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.pasteKeyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.pasteKeyCode,
                  keyDown: false
              ) else {
            return nil
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        return (keyDown, keyUp)
    }

}

struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    let changeCount: Int

    @MainActor
    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var typesToData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typesToData[type] = data
                }
            }
            return typesToData
        }
        return PasteboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }
}

/// Restores only while the temporary transcript is still the current pasteboard
/// generation. A user copy during the paste delay therefore always wins.
///
/// Restores the full prior pasteboard contents (all types on all items), not just
/// plain text, so a prior image/file/RTF clipboard isn't destroyed by the paste fallback.
@MainActor
@discardableResult
func restorePasteboardIfOwned(
    _ pasteboard: NSPasteboard,
    snapshot: PasteboardSnapshot,
    ownedChangeCount: Int
) -> Bool {
    guard pasteboard.changeCount == ownedChangeCount else {
        return false
    }

    pasteboard.clearContents()
    if !snapshot.items.isEmpty {
        let items = snapshot.items.map { typesToData -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in typesToData {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
    RecentClipboard.noteOwnChange(pasteboard)
    return true
}
