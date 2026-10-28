import AppKit
import Carbon.HIToolbox

/// Prints the push-to-talk binding the app **actually loaded**, and what Carbon said when
/// asked to register it.
///
/// It exists because "the chord was never registered" and "the chord was registered but the
/// keystroke did not reach it" produce the identical observable: nothing happens when you
/// press the keys. Neither the stored preference nor the source tells them apart — the
/// preference can be right while the wiring drops it, and the wiring can be right while
/// Carbon refuses the combo because something else owns it.
///
/// Reads through the real `AppSettings` and registers through the real `HotkeyManager`, so
/// what it reports is what the app does, not a re-implementation that could agree with the
/// source and disagree with the running process.
@MainActor
enum HotkeyBindingProbe {

    static func run() {
        let settings = AppSettings()
        let bindings = settings.hotkeyBindings

        print("--- what the app loaded ---")
        print("  push-to-talk:  \(describe(bindings.pushToTalk))")
        print("  toggle:        \(ShortcutNotation.display(bindings.toggleDictation))")
        print("  thought:       \(ShortcutNotation.display(bindings.toggleThought))")
        print("  history:       \(ShortcutNotation.display(bindings.showHistoryPalette))")
        print("")

        // The mechanism question, which is the one that decides everything downstream.
        if let combo = bindings.pushToTalk.chordCombo {
            print("  mechanism:     Carbon chord (press + release edges)")
            print("  digit form:    "
                  + ShortcutNotation.glyphs(
                      forCarbon: ModeDigitHotkeys.carbonModifier(for: bindings.pushToTalk) ?? 0)
                  + "1…9 while held")
            probeRegistration(of: combo)
        } else if bindings.pushToTalk.modifierKey != .disabled {
            print("  mechanism:     flagsChanged monitor on "
                  + SettingsViewModel.pushToTalkTitle(bindings.pushToTalk.modifierKey))
            print("  note:          a bare modifier is not a Carbon hotkey, so nothing is")
            print("                 registered and nothing can refuse it.")
        } else {
            print("  mechanism:     none — push-to-talk is OFF")
        }

        print("")
        print("Reminder: this process is not the app you are using. A refusal here can mean")
        print("the RUNNING Captur already owns the combo, which is the good case.")
        NSApplication.shared.terminate(nil)
    }

    private static func describe(_ binding: PushToTalkBinding) -> String {
        switch binding.normalized {
        case .chord(let combo): return "\(ShortcutNotation.display(combo))  (custom chord)"
        case .modifier(let key): return SettingsViewModel.pushToTalkTitle(key)
        case .disabled: return "Off"
        }
    }

    /// Asks Carbon for the chord through the shipping registrar and says what came back.
    private static func probeRegistration(of combo: KeyCombo) {
        let registrar = CarbonHotkeyRegistrar()
        switch registrar.register(keyCode: combo.keyCode,
                                  modifiers: combo.carbonModifiers,
                                  signature: 0x50524F42,   // 'PROB'
                                  id: 1) {
        case .success(let handle):
            print("  carbon:        ACCEPTED the chord in this process")
            registrar.unregister(handle)
        case .failure(.registrationFailed(let status)):
            print("  carbon:        REFUSED (OSStatus \(status)) — something owns this combo")
        }
    }
}
