import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Captur

/// The two things in the shortcut recorder that break silently: the `NSEvent` →
/// Carbon modifier conversion, and the glyph formatting. Both are pure static
/// functions precisely so they can be pinned here; the SwiftUI wrapper around them
/// is not the risky part.
final class ShortcutRecorderFieldTests: XCTestCase {

    // MARK: - The Carbon bits themselves

    /// The bitmask values are not folklore — they come from Carbon, and the app's own
    /// shipped defaults already encode them. If either side drifts, every stored
    /// shortcut silently means something else.
    func testCarbonModifierBitsMatchCarbon() {
        XCTAssertEqual(CarbonModifiers.command, UInt32(cmdKey))
        XCTAssertEqual(CarbonModifiers.shift, UInt32(shiftKey))
        XCTAssertEqual(CarbonModifiers.option, UInt32(optionKey))
        XCTAssertEqual(CarbonModifiers.control, UInt32(controlKey))

        // And the literal values the design spec quotes.
        XCTAssertEqual(CarbonModifiers.command, 0x0100)
        XCTAssertEqual(CarbonModifiers.shift, 0x0200)
        XCTAssertEqual(CarbonModifiers.option, 0x0800)
        XCTAssertEqual(CarbonModifiers.control, 0x1000)
    }

    /// Verified against reality rather than against the prompt: `HotkeyBindings.default`
    /// already claims ⌥Space / ⌥⇧Space / ⌃⌥Space in its comments, so the formatter has
    /// to agree with the bindings the app ships with.
    func testShippedDefaultsFormatAsTheirDocumentedGlyphs() {
        let defaults = HotkeyBindings.default
        XCTAssertEqual(ShortcutNotation.display(defaults.toggleDictation), "⌥Space")
        XCTAssertEqual(ShortcutNotation.display(defaults.toggleThought), "⌥⇧Space")
        XCTAssertEqual(ShortcutNotation.display(defaults.showHistoryPalette), "⌃⌥Space")
    }

    // MARK: - NSEvent flags → Carbon

    func testEachModifierFlagMapsToItsCarbonBit() {
        XCTAssertEqual(ShortcutNotation.carbonModifiers(from: [.command]), CarbonModifiers.command)
        XCTAssertEqual(ShortcutNotation.carbonModifiers(from: [.shift]), CarbonModifiers.shift)
        XCTAssertEqual(ShortcutNotation.carbonModifiers(from: [.option]), CarbonModifiers.option)
        XCTAssertEqual(ShortcutNotation.carbonModifiers(from: [.control]), CarbonModifiers.control)
    }

    func testCombinedFlagsOrTogetherAndMatchTheShippedDefaults() {
        XCTAssertEqual(ShortcutNotation.carbonModifiers(from: [.option, .shift]), 0x0A00)
        XCTAssertEqual(ShortcutNotation.carbonModifiers(from: [.control, .option]), 0x1800)
        XCTAssertEqual(
            ShortcutNotation.carbonModifiers(from: [.command, .option, .control, .shift]),
            CarbonModifiers.command | CarbonModifiers.option
                | CarbonModifiers.control | CarbonModifiers.shift)
    }

    /// Caps Lock, Fn and the numeric-pad flag are not shortcut modifiers. Letting any
    /// of them through would make an otherwise identical keypress record a different
    /// combo depending on whether Caps Lock happened to be on.
    func testNonShortcutFlagsAreIgnored() {
        XCTAssertEqual(ShortcutNotation.carbonModifiers(from: [.capsLock]), 0)
        XCTAssertEqual(ShortcutNotation.carbonModifiers(from: [.function]), 0)
        XCTAssertEqual(ShortcutNotation.carbonModifiers(from: [.numericPad]), 0)
        XCTAssertEqual(
            ShortcutNotation.carbonModifiers(from: [.command, .capsLock, .numericPad]),
            CarbonModifiers.command)
    }

    func testCarbonBitsRoundTripBackToFlags() {
        for bits: UInt32 in [0, 0x0100, 0x0200, 0x0800, 0x1000, 0x0A00, 0x1800, 0x1B00] {
            let flags = ShortcutNotation.modifierFlags(fromCarbon: bits)
            XCTAssertEqual(ShortcutNotation.carbonModifiers(from: flags), bits,
                           "round trip lost information for \(String(bits, radix: 16))")
        }
    }

    // MARK: - Glyphs

    /// macOS renders modifiers in one fixed order — ⌃⌥⇧⌘ — and a menu bar that
    /// disagrees with the settings screen teaches the user two different shortcuts.
    func testGlyphOrderIsCanonical() {
        let all = CarbonModifiers.command | CarbonModifiers.shift
            | CarbonModifiers.option | CarbonModifiers.control
        XCTAssertEqual(ShortcutNotation.glyphs(forCarbon: all), "⌃⌥⇧⌘")
        XCTAssertEqual(ShortcutNotation.glyphs(forCarbon: 0), "")
    }

    func testKeyLabelsUseTheStandardNames() {
        XCTAssertEqual(ShortcutNotation.keyLabel(forKeyCode: UInt32(kVK_Space)), "Space")
        XCTAssertEqual(ShortcutNotation.keyLabel(forKeyCode: UInt32(kVK_Return)), "↩")
        XCTAssertEqual(ShortcutNotation.keyLabel(forKeyCode: UInt32(kVK_Tab)), "⇥")
        XCTAssertEqual(ShortcutNotation.keyLabel(forKeyCode: UInt32(kVK_Escape)), "⎋")
        XCTAssertEqual(ShortcutNotation.keyLabel(forKeyCode: UInt32(kVK_Delete)), "⌫")
        XCTAssertEqual(ShortcutNotation.keyLabel(forKeyCode: UInt32(kVK_ANSI_A)), "A")
        XCTAssertEqual(ShortcutNotation.keyLabel(forKeyCode: UInt32(kVK_ANSI_0)), "0")
        XCTAssertEqual(ShortcutNotation.keyLabel(forKeyCode: UInt32(kVK_UpArrow)), "↑")
        XCTAssertEqual(ShortcutNotation.keyLabel(forKeyCode: UInt32(kVK_F1)), "F1")
    }

    /// An unknown keycode must say so rather than render as an empty string that looks
    /// like "no shortcut".
    func testUnknownKeyCodeIsLabelledHonestly() {
        let label = ShortcutNotation.keyLabel(forKeyCode: 999)
        XCTAssertTrue(label.contains("999"), "expected the raw keycode in \(label)")
        XCTAssertFalse(label.isEmpty)
    }

    func testDisplayCombinesGlyphsAndKeyLabel() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_A),
                             carbonModifiers: CarbonModifiers.control | CarbonModifiers.shift)
        XCTAssertEqual(ShortcutNotation.display(combo), "⌃⇧A")
    }

    func testDisplayOfNoBindingIsExplicit() {
        XCTAssertEqual(ShortcutNotation.display(nil), ShortcutNotation.unsetLabel)
        XCTAssertFalse(ShortcutNotation.unsetLabel.isEmpty)
    }

    // MARK: - Interpreting a captured keystroke

    /// A bare modifier press is not a combo. The recorder has to keep waiting rather
    /// than commit "⌘ + nothing", which Carbon cannot register.
    func testBareModifierKeyCodesAreIgnored() {
        let modifierKeyCodes: [Int] = [
            kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
            kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl,
            kVK_CapsLock, kVK_Function
        ]
        for keyCode in modifierKeyCodes {
            XCTAssertEqual(
                ShortcutNotation.interpret(keyCode: UInt32(keyCode), flags: [.command]),
                .ignore,
                "keycode \(keyCode) should not commit a combo")
        }
    }

    func testBareEscapeCancels() {
        XCTAssertEqual(ShortcutNotation.interpret(keyCode: UInt32(kVK_Escape), flags: []), .cancel)
    }

    /// ⌘⎋ is a legitimate shortcut; only *bare* Escape means "stop recording".
    func testModifiedEscapeIsACombination() {
        XCTAssertEqual(
            ShortcutNotation.interpret(keyCode: UInt32(kVK_Escape), flags: [.command]),
            .captured(KeyCombo(keyCode: UInt32(kVK_Escape),
                               carbonModifiers: CarbonModifiers.command)))
    }

    /// A global hotkey with no ⌘/⌥/⌃ swallows that key in every app on the machine.
    /// ⇧ alone is the same trap wearing a disguise — ⇧A would eat every capital A.
    func testAKeyWithoutAPrimaryModifierIsRejectedWithAReason() {
        for flags in [NSEvent.ModifierFlags(), [.shift]] as [NSEvent.ModifierFlags] {
            guard case .rejected(let reason) =
                    ShortcutNotation.interpret(keyCode: UInt32(kVK_ANSI_A), flags: flags)
            else {
                return XCTFail("expected a rejection for flags \(flags.rawValue)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testAValidComboIsCapturedAndMatchesTheShippedDefault() {
        XCTAssertEqual(
            ShortcutNotation.interpret(keyCode: UInt32(kVK_Space), flags: [.option]),
            .captured(HotkeyBindings.default.toggleDictation!))
    }
}
