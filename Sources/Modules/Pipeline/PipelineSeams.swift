import AVFoundation
import Foundation

/// The recorder surface the pipeline drives.
///
/// Declared by the consumer rather than the producer so the pipeline can be tested
/// against a double that owns real files without dragging CoreAudio's FLAC encoder
/// into every pipeline test. `SegmentRecorder` satisfies it as written.
///
/// Deliberately not `@MainActor`: `ingest` is called once per converted buffer on
/// `AudioQueue`, and per-buffer work never touches the main actor.
protocol SegmentRecording: AnyObject, Sendable {
    var onSegmentClosed: ((AudioSegment) -> Void)? { get set }
    func begin(captureID: UUID) throws
    func ingest(_ buffer: AVAudioPCMBuffer)
    func finish() -> SessionRecording
    func discard()
    func deleteSegmentFiles()
}

extension SegmentRecorder: SegmentRecording {}

/// The record-log surface the pipeline writes through.
///
/// A seam rather than the concrete actor so the persist-before-network ordering can
/// be asserted against an in-memory double, and so most pipeline tests do not have
/// to touch the filesystem to prove something that has nothing to do with files.
protocol DictationRecordLogging: Sendable {
    func append(_ record: DictationRecord) async throws
    func all() async throws -> [DictationRecord]
    func record(id: UUID) async throws -> DictationRecord?
    func update(id: UUID, mutate: (inout DictationRecord) -> Void) async throws
}

extension DictationRecordLog: DictationRecordLogging {}

// MARK: - The 1–9 mode switch

/// One 1–9 registration: the mode ordinal the key selects, and the exact combo
/// Carbon is asked for.
struct ModeDigitBinding: Equatable, Sendable {
    /// 1-based, so it reads as the key the user actually presses.
    let digit: Int
    let combo: KeyCombo
}

/// Which combos the 1–9 mode switch occupies while a capture is recording, as a
/// pure function of the two facts that decide them (spec §4.1).
///
/// Pure and separately tested because this is the rule that breaks the user's
/// keyboard if it is wrong. Nine *plain digits* are taken system-wide for the
/// length of a recording; the safety is entirely in the teardown, so the shape of
/// what gets registered has to be inspectable without Carbon.
enum ModeDigitHotkeys {

    /// Carbon virtual keycodes for the top-row digits 1–9, in order. Note 6 and 7
    /// (`22`, `23`) are transposed relative to the digits — that is Carbon's
    /// layout, not a typo.
    static let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// Spec §4.1: while the push-to-talk modifier is physically held, the digit
    /// arrives as a modified combo (⌥1, not 1), so **both** forms are registered.
    ///
    /// `nil` means the held key contributes no Carbon modifier bit, so there is no
    /// second form to register. `RegisterEventHotKey` only understands
    /// cmd/shift/option/control — Fn/Globe is not expressible, and a disabled
    /// push-to-talk key is not held at all.
    static func carbonModifier(for key: PushToTalkKey) -> UInt32? {
        switch key {
        case .rightOption: return 0x0800    // optionKey
        case .rightCommand: return 0x0100   // cmdKey
        case .fnGlobe, .disabled: return nil
        }
    }

    /// The same question for a whole binding.
    ///
    /// A chord answers it directly: holding ⌘⇧D means ⌘ and ⇧ are physically down, so the
    /// digit arrives as ⌘⇧1 and that is the second form to register. This is why the digit
    /// modifier is derived from the binding rather than hard-coded per key — a custom
    /// shortcut's modifiers are whatever the user recorded.
    static func carbonModifier(for binding: PushToTalkBinding) -> UInt32? {
        if let combo = binding.chordCombo {
            return combo.carbonModifiers == 0 ? nil : combo.carbonModifiers
        }
        return carbonModifier(for: binding.modifierKey)
    }

    /// The registrations for a recording that can switch between `modeCount` modes.
    ///
    /// Capped at nine because there are nine digits; a tenth mode is reachable
    /// through the picker, not through a key that does not exist.
    static func bindings(modeCount: Int, pushToTalk: PushToTalkBinding) -> [ModeDigitBinding] {
        let count = min(max(modeCount, 0), digitKeyCodes.count)
        guard count > 0 else { return [] }
        let modifier = carbonModifier(for: pushToTalk)

        return (0..<count).flatMap { index -> [ModeDigitBinding] in
            let digit = index + 1
            let keyCode = digitKeyCodes[index]
            var forms = [ModeDigitBinding(
                digit: digit, combo: KeyCombo(keyCode: keyCode, carbonModifiers: 0))]
            if let modifier {
                forms.append(ModeDigitBinding(
                    digit: digit, combo: KeyCombo(keyCode: keyCode, carbonModifiers: modifier)))
            }
            return forms
        }
    }
}

/// A refused 1–9 registration, carrying the digit it was about.
///
/// `HotkeyError` alone would say only that *something* was refused, and the one
/// useful thing to tell the user is which key they have lost for this recording.
struct ModeDigitRefusal: Error, Equatable {
    let digit: Int
    let underlying: HotkeyError
}

/// The 1–9 registration surface, declared by the pipeline rather than added to
/// `HotkeyManaging`.
///
/// It cannot go through `registerTransient`: that API is keyed by `HotkeyAction`,
/// a fixed enum with one combo per case, and this needs up to eighteen
/// registrations that all mean "switch to the Nth mode". `HotkeyManager` satisfies
/// it as written.
@MainActor
protocol ModeDigitHotkeyRegistering: AnyObject {
    /// Replaces any previous set. Everything registrable is registered before the
    /// first refusal is thrown as a `ModeDigitRefusal`, so one occupied digit costs
    /// the user that digit rather than the other eight.
    func registerModeDigits(_ bindings: [ModeDigitBinding],
                            onDigit: @escaping (Int) -> Void) throws
    func unregisterModeDigits()
}

// MARK: - Mode services

/// Everything the mode pass, the vocabulary and the 1–9 hotkeys reach for.
///
/// Grouped rather than added as eight more parameters to an initializer that
/// already takes twelve. Every field defaults to the inert value, so a pipeline
/// built without this behaves exactly as it did before modes were wired — which is
/// what the pipeline tests written before Task 16 assert, and why they needed no
/// edit.
///
/// **An absent `chat` is a skip, not a passthrough.** A pipeline with LLM modes and
/// no client inserts the raw transcript and says the mode was skipped, rather than
/// quietly behaving like Verbatim while the capsule claims otherwise.
@MainActor
struct ModeServices {
    /// The mode's LLM pass. `nil` = no client was injected.
    var chat: (any GroqChatting)? = nil
    /// Production refinement path. `chat` remains as a compatibility seam for
    /// focused tests; when this is present it always wins.
    var refinement: (any RefinementCompleting)? = nil
    var localCleanup: (any LocalCleanCompleting)? = nil
    var cleanupRegistry: LocalCleanupRegistry = .builtIn
    var prewarmLocalCleanup: (ModeCleanupChoice) -> Void = { _ in }
    /// Credentials are selected only after the mode resolves its provider.
    var refinementAPIKey: (RefinementProviderID) -> String? = { _ in nil }
    /// Spec §6.3's second rung: `[bundleID: modeID]`, read once, at `begin`.
    var contextEnabled: () -> Bool = { true }
    var contextSnapshot: (String?, ContextCaptureRequest) -> Task<ContextSnapshot, Never> = { _, _ in Task { .empty } }
    var perWebsiteMap: () -> [String: String] = { [:] }
    var clipboardAtStart: (() -> String?)? = nil
    var clipboardBeforeWebsiteResolution: () -> Bool = { false }
    var clipboardStartReader: (() -> (() -> String?))? = nil
    var clipboardEndReader: ((Date) -> (() -> ClipboardContextUpdate))? = nil
    var clipboardAtEnd: (Date) -> ClipboardContextUpdate = { _ in .unchanged }
    var saveContextMetadata: () -> Bool = { true }
    var perAppModeMap: () -> [String: String] = { [:] }
    /// The user's vocabulary. Read at `begin` for the request, and **read again**
    /// at completion for the usage write-back, so a list edited mid-dictation is
    /// never overwritten with the snapshot taken before the edit.
    var vocabulary: () -> [VocabularyTerm] = { [] }
    /// One whole-list write per dictation. `VocabularyStore.replaceAll` satisfies
    /// it; a per-term `upsert` would rewrite the file once per matched term.
    var saveVocabulary: ([VocabularyTerm]) -> Void = { _ in }
    /// The user's replacement rules, in apply order. `ReplacementStore.replacements`
    /// satisfies it.
    var replacements: () -> [Replacement] = { [] }
    /// Read **only** when the resolved mode sets `includeClipboardContext` —
    /// reading the pasteboard is the privacy-relevant act, not sending it.
    var clipboard: () -> String? = { nil }
    /// Which push-to-talk key is bound, so the modified digit forms match the
    /// modifier that is actually being held.
    var hotkeyBindings: () -> HotkeyBindings = { .default }
    /// `nil` = the 1–9 switch is simply unavailable; nothing else changes.
    var modeDigits: (any ModeDigitHotkeyRegistering)?
}
