import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Carbon modifier bits

/// The four modifier bits `RegisterEventHotKey` understands, named.
///
/// They are re-exported from Carbon rather than hard-coded so the app and the OS
/// cannot drift apart, and they are pinned by a test against both the Carbon constants
/// and the literal values `HotkeyBindings.default` already encodes (`0x0800` = ⌥,
/// `0x0A00` = ⌥⇧, `0x1800` = ⌃⌥). A wrong bit here does not crash: every stored
/// shortcut quietly starts meaning something else.
enum CarbonModifiers {
    static let command = UInt32(cmdKey)      // 0x0100
    static let shift = UInt32(shiftKey)      // 0x0200
    static let option = UInt32(optionKey)    // 0x0800
    static let control = UInt32(controlKey)  // 0x1000

    /// Every bit a shortcut may carry. Anything else in an `NSEvent`'s flags — Caps
    /// Lock, Fn, the numeric-pad marker — is not a shortcut modifier.
    static let all = command | shift | option | control

    /// ⌘, ⌥ and ⌃. A global hotkey needs at least one of them; see
    /// `ShortcutNotation.missingPrimaryModifier`.
    static let primary = command | option | control
}

// MARK: - What a captured keystroke means

/// The verdict on one key-down while a recorder is live.
enum ShortcutCapture: Equatable {
    /// Bare Escape: stop recording and keep the previous binding.
    case cancel
    /// A modifier on its own. Not a combo — keep waiting rather than commit ⌘+nothing,
    /// which Carbon cannot register.
    case ignore
    /// A real key, but not one that can safely be a global hotkey. The reason is shown
    /// to the user.
    case rejected(String)
    case captured(KeyCombo)
}

// MARK: - Conversion and formatting

/// `NSEvent` → Carbon, and Carbon → the glyphs macOS puts in a menu.
///
/// Everything here is a pure static function on purpose. This is the part of the
/// recorder that breaks silently — a dropped bit or a reordered glyph produces a
/// screen that looks right and a shortcut that is not the one shown — so it is pinned
/// by `ShortcutRecorderFieldTests`. The SwiftUI wrapper below is not the risky part.
enum ShortcutNotation {

    /// Shown where a binding is `nil`. Never an empty string: a blank control reads as
    /// "something is broken" rather than "nothing is bound".
    static let unsetLabel = "Not set"

    static let missingPrimaryModifier =
        "Use at least one of ⌘, ⌥ or ⌃ — on its own that key would stop working in every app."

    // MARK: NSEvent → Carbon

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.command) { bits |= CarbonModifiers.command }
        if flags.contains(.shift) { bits |= CarbonModifiers.shift }
        if flags.contains(.option) { bits |= CarbonModifiers.option }
        if flags.contains(.control) { bits |= CarbonModifiers.control }
        return bits
    }

    /// The inverse, used only to prove the mapping is lossless.
    static func modifierFlags(fromCarbon bits: UInt32) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if bits & CarbonModifiers.command != 0 { flags.insert(.command) }
        if bits & CarbonModifiers.shift != 0 { flags.insert(.shift) }
        if bits & CarbonModifiers.option != 0 { flags.insert(.option) }
        if bits & CarbonModifiers.control != 0 { flags.insert(.control) }
        return flags
    }

    // MARK: Carbon → glyphs

    /// Modifier glyphs in the one order macOS uses: ⌃⌥⇧⌘. A settings screen that
    /// disagrees with the menu bar teaches the user two different shortcuts.
    static func glyphs(forCarbon bits: UInt32) -> String {
        var text = ""
        if bits & CarbonModifiers.control != 0 { text += "⌃" }
        if bits & CarbonModifiers.option != 0 { text += "⌥" }
        if bits & CarbonModifiers.shift != 0 { text += "⇧" }
        if bits & CarbonModifiers.command != 0 { text += "⌘" }
        return text
    }

    static func display(_ combo: KeyCombo?) -> String {
        guard let combo else { return unsetLabel }
        return glyphs(forCarbon: combo.carbonModifiers) + keyLabel(forKeyCode: combo.keyCode)
    }

    /// A Carbon virtual keycode's printed name.
    ///
    /// A fixed table rather than `UCKeyTranslate`: the label has to be stable for the
    /// life of a stored binding, and a layout-sensitive lookup would rename the user's
    /// shortcut when they switch to a Dvorak or AZERTY layout even though the *physical*
    /// key Carbon registered has not moved.
    static func keyLabel(forKeyCode keyCode: UInt32) -> String {
        if let named = names[keyCode] { return named }
        // Never an empty string: an unrecognized key has to look unrecognized.
        return "Key \(keyCode)"
    }

    // MARK: Interpreting one key-down

    static func interpret(keyCode: UInt32, flags: NSEvent.ModifierFlags) -> ShortcutCapture {
        // A modifier key-down is not a combo. (AppKit delivers these as `flagsChanged`
        // rather than `keyDown`, so this is the belt to that braces.)
        if isModifierKeyCode(keyCode) { return .ignore }

        let bits = carbonModifiers(from: flags)

        // Bare Escape means "stop recording". ⌘⎋ is a legitimate shortcut.
        if keyCode == UInt32(kVK_Escape), bits == 0 { return .cancel }

        // A global hotkey with no ⌘/⌥/⌃ swallows that key everywhere on the machine.
        // ⇧ alone is the same trap in disguise: ⇧A would eat every capital A.
        guard bits & CarbonModifiers.primary != 0 else { return .rejected(missingPrimaryModifier) }

        return .captured(KeyCombo(keyCode: keyCode, carbonModifiers: bits))
    }

    static func isModifierKeyCode(_ keyCode: UInt32) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    // MARK: Tables

    private static let modifierKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_RightCommand),
        UInt32(kVK_Shift), UInt32(kVK_RightShift),
        UInt32(kVK_Option), UInt32(kVK_RightOption),
        UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_CapsLock), UInt32(kVK_Function)
    ]

    private static let names: [UInt32: String] = {
        var map: [UInt32: String] = [:]

        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z")
        ]
        let digits: [(Int, String)] = [
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9")
        ]
        let punctuation: [(Int, String)] = [
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="),
            (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"),
            (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"),
            (kVK_ANSI_Grave, "`")
        ]
        // Glyphs, not words, for the keys macOS itself draws as glyphs in a menu.
        let named: [(Int, String)] = [
            (kVK_Space, "Space"), (kVK_Return, "↩"), (kVK_ANSI_KeypadEnter, "⌤"),
            (kVK_Tab, "⇥"), (kVK_Escape, "⎋"), (kVK_Delete, "⌫"), (kVK_ForwardDelete, "⌦"),
            (kVK_Home, "↖"), (kVK_End, "↘"), (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"),
            (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
            (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
            (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12")
        ]

        for (code, label) in letters + digits + punctuation + named {
            map[UInt32(code)] = label
        }
        return map
    }()
}

// MARK: - The live key monitor

/// Consumes key-downs while a recorder is live, and — the part that matters — stops
/// consuming them the moment it is not.
///
/// A *local* monitor, returning nil to swallow the event: the Settings window is key
/// while recording, so a local monitor is enough, and unlike a global one it cannot
/// eat another app's keystrokes if it is ever leaked. `stop()` is idempotent and runs
/// from `deinit` as well as from the view's lifecycle, so no route out of a recording
/// leaves a monitor installed.
@MainActor
final class ShortcutKeyMonitor: ObservableObject {
    private var monitor: Any?

    init() {}

    deinit {
        // `deinit` is nonisolated; `removeMonitor` is safe to call from it, and leaving
        // a monitor installed would swallow keystrokes for the life of the process.
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func start(_ handler: @escaping (NSEvent) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return nil          // recorded, not typed
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - The field

/// One shortcut row: a label, a click-to-record button, and the reason it cannot be
/// edited when that is the case.
///
/// Stateless about the binding itself — every decision (what is recording, what is
/// stored, what Carbon refused) belongs to `SettingsViewModel`, which is where it can
/// be tested. This view's only job is turning keystrokes into `ShortcutCapture` values
/// and glyphs onto the screen.
struct ShortcutRecorderField: View {
    let title: String
    let combo: KeyCombo?
    let isRecording: Bool
    var isEditable: Bool = true
    /// Shown instead of the button's help when the row cannot be edited. Spec-adjacent
    /// rule for this project: never render a control that silently does nothing.
    var disabledReason: String?
    /// The inline result of the last attempt — a Carbon refusal, or a keystroke that is
    /// not safe as a global hotkey.
    var errorMessage: String?

    var onBeginRecording: () -> Void
    var onCancel: () -> Void
    var onCapture: (KeyCombo) -> Void
    var onReject: (String) -> Void
    var onClear: () -> Void

    @StateObject private var monitor = ShortcutKeyMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 12)

                Button(buttonTitle) {
                    if isRecording { onCancel() } else { onBeginRecording() }
                }
                .disabled(!isEditable)
                .frame(minWidth: 120)
                .help(isEditable
                      ? "Click, then press the keys you want."
                      : (disabledReason ?? ""))

                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(!isEditable || combo == nil)
                .help("Remove this shortcut")
                .accessibilityLabel("Remove \(title) shortcut")
            }

            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(errorMessage == nil ? .secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: isRecording) { _, recording in
            if recording {
                monitor.start { event in handle(event) }
            } else {
                monitor.stop()
            }
        }
        // The window can close mid-recording. The view model resumes the hotkey
        // manager; this makes sure the monitor goes with it.
        .onDisappear { monitor.stop() }
    }

    private var buttonTitle: String {
        if isRecording { return "Press keys… (⎋ to cancel)" }
        return ShortcutNotation.display(combo)
    }

    private var caption: String? {
        if let errorMessage { return errorMessage }
        if !isEditable { return disabledReason }
        return nil
    }

    private func handle(_ event: NSEvent) {
        switch ShortcutNotation.interpret(keyCode: UInt32(event.keyCode),
                                          flags: event.modifierFlags) {
        case .cancel:
            onCancel()
        case .ignore:
            break
        case .rejected(let reason):
            onReject(reason)
        case .captured(let combo):
            onCapture(combo)
        }
    }
}
