import Carbon.HIToolbox
import XCTest
@testable import Captur

/// Coverage for chord push-to-talk (⌘⇧D and the like): the stored shape, the legacy shape
/// it has to keep reading, which mechanism a binding selects, and the conflict rule.
///
/// The migration cases are the load-bearing ones. `AppSettings` decodes `hotkeyBindings`
/// with `try?` and falls back to `HotkeyBindings.default`, so a decode this type cannot
/// handle does not surface as an error — it silently resets every shortcut the user had
/// customized. These tests are the only thing standing between a shape change and that.
///
/// `@MainActor` because `AppSettings` is: one case reads a legacy blob through the real
/// store rather than only through `JSONDecoder`, since the `try?` that would hide a failure
/// lives there and not in the decoder.
@MainActor
final class PushToTalkChordTests: XCTestCase {

    // MARK: - The legacy shape

    /// Exactly what a pre-chord install has on disk: `pushToTalk` as a bare raw string.
    private func legacyJSON(_ key: String) -> Data {
        Data("""
        {
          "pushToTalk": "\(key)",
          "toggleDictation": { "keyCode": 49, "carbonModifiers": 2048 },
          "toggleThought": { "keyCode": 49, "carbonModifiers": 2560 },
          "showHistoryPalette": { "keyCode": 49, "carbonModifiers": 6144 }
        }
        """.utf8)
    }

    func testALegacyStringPushToTalkStillDecodes() throws {
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: legacyJSON("rightOption"))
        XCTAssertEqual(decoded.pushToTalk, .modifier(.rightOption))
    }

    /// The whole point of the legacy path: the OTHER three shortcuts survive. If
    /// push-to-talk failed to decode, the entire object would throw and `AppSettings`
    /// would quietly substitute the defaults.
    func testALegacyBlobKeepsEveryOtherShortcut() throws {
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: legacyJSON("fnGlobe"))
        XCTAssertEqual(decoded.pushToTalk, .modifier(.fnGlobe))
        XCTAssertEqual(decoded.toggleDictation, KeyCombo(keyCode: 49, carbonModifiers: 0x0800))
        XCTAssertEqual(decoded.toggleThought, KeyCombo(keyCode: 49, carbonModifiers: 0x0A00))
        XCTAssertEqual(decoded.showHistoryPalette, KeyCombo(keyCode: 49, carbonModifiers: 0x1800))
    }

    func testEveryLegacyKeyNameDecodes() throws {
        for key in PushToTalkKey.allCases {
            let decoded = try JSONDecoder().decode(HotkeyBindings.self,
                                                   from: legacyJSON(key.rawValue))
            XCTAssertEqual(decoded.pushToTalk,
                           PushToTalkBinding.modifier(key).normalized,
                           "legacy \(key.rawValue)")
        }
    }

    /// A legacy blob read through `AppSettings` itself — the real path, including the
    /// `try?` that would hide a failure.
    func testALegacyBlobSurvivesAppSettings() throws {
        let defaults = UserDefaults(suiteName: "captur.tests.ptt.\(UUID().uuidString)")!
        defaults.set(legacyJSON("rightCommand"), forKey: "captur.hotkeyBindings")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.hotkeyBindings.pushToTalk, .modifier(.rightCommand))
        XCTAssertEqual(settings.hotkeyBindings.toggleDictation,
                       KeyCombo(keyCode: 49, carbonModifiers: 0x0800),
                       "a failed push-to-talk decode would have reset this to the default")
    }

    func testAnUnknownLegacyKeyNameIsRejectedRatherThanGuessed() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(HotkeyBindings.self, from: legacyJSON("leftPinky")))
    }

    // MARK: - The new shape

    func testAChordRoundTrips() throws {
        let chord = KeyCombo(keyCode: UInt32(kVK_ANSI_D),
                             carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey))
        var bindings = HotkeyBindings.default
        bindings.pushToTalk = .chord(chord)

        let data = try JSONEncoder().encode(bindings)
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: data)

        XCTAssertEqual(decoded.pushToTalk, .chord(chord))
        XCTAssertEqual(decoded.pushToTalk.chordCombo, chord)
    }

    func testDisabledRoundTrips() throws {
        var bindings = HotkeyBindings.default
        bindings.pushToTalk = .disabled
        let data = try JSONEncoder().encode(bindings)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyBindings.self, from: data).pushToTalk,
                       .disabled)
    }

    /// Two spellings of "off" must not both survive a round trip, or a picker comparing
    /// against `.disabled` would show the wrong row for a binding that means the same thing.
    func testModifierDisabledNormalizesToDisabled() throws {
        XCTAssertEqual(PushToTalkBinding.modifier(.disabled).normalized, .disabled)

        var bindings = HotkeyBindings.default
        bindings.pushToTalk = .modifier(.disabled)
        let data = try JSONEncoder().encode(bindings)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyBindings.self, from: data).pushToTalk,
                       .disabled)
    }

    // MARK: - Which mechanism a binding selects

    /// The invariant that keeps a hold from starting TWO recordings: a chord binding must
    /// leave the flagsChanged detector inert, because Carbon owns both of its edges.
    func testAChordLeavesTheModifierDetectorInert() {
        let chord = KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(cmdKey))
        let binding = PushToTalkBinding.chord(chord)

        XCTAssertEqual(binding.modifierKey, .disabled)

        var detector = PushToTalkDetector(binding: binding)
        // Right Option going down must produce nothing at all under a chord binding.
        XCTAssertEqual(detector.process(keyCode: 61, flags: .option), .none)
        XCTAssertEqual(detector.process(keyCode: 61, flags: []), .none)
    }

    func testAModifierBindingLeavesNoChordToRegister() {
        XCTAssertNil(PushToTalkBinding.modifier(.rightOption).chordCombo)
        XCTAssertNil(PushToTalkBinding.disabled.chordCombo)
    }

    func testAModifierBindingStillDrivesTheDetector() {
        var detector = PushToTalkDetector(binding: .modifier(.rightOption))
        XCTAssertEqual(detector.process(keyCode: 61, flags: .option), .down)
        XCTAssertEqual(detector.process(keyCode: 61, flags: []), .up)
    }

    // MARK: - Mode digits follow the chord's modifiers

    /// While ⌘⇧D is held, a digit arrives as ⌘⇧1 — so that is the second form the
    /// recording has to register. Derived from the binding, not a per-key table, which is
    /// the only way a *custom* chord's modifiers can be right.
    func testTheModifiedDigitFormFollowsAChordsModifiers() {
        let mods = UInt32(cmdKey) | UInt32(shiftKey)
        let chord = KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: mods)

        XCTAssertEqual(ModeDigitHotkeys.carbonModifier(for: PushToTalkBinding.chord(chord)), mods)

        let bindings = ModeDigitHotkeys.bindings(modeCount: 3, pushToTalk: .chord(chord))
        XCTAssertEqual(bindings.count, 6, "three digits in two forms each")
        XCTAssertEqual(Set(bindings.map(\.combo.carbonModifiers)), [0, mods])
    }

    // MARK: - The conflict rule

    func testAChordAlreadyUsedByAToggleIsReportedAsAConflict() {
        let bindings = HotkeyBindings.default
        // ⌥Space is the dictation toggle by default.
        let taken = KeyCombo(keyCode: 49, carbonModifiers: 0x0800)

        XCTAssertEqual(bindings.conflict(with: taken, excluding: "Push-to-talk"),
                       "Start / stop dictation")
    }

    func testASlotDoesNotConflictWithItself() {
        let bindings = HotkeyBindings.default
        let taken = KeyCombo(keyCode: 49, carbonModifiers: 0x0800)

        XCTAssertNil(bindings.conflict(with: taken, excluding: "Start / stop dictation"),
                     "re-recording the same shortcut onto its own row is not a conflict")
    }

    func testAFreeComboHasNoConflict() {
        let free = KeyCombo(keyCode: UInt32(kVK_ANSI_D),
                            carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey))
        XCTAssertNil(HotkeyBindings.default.conflict(with: free, excluding: "Push-to-talk"))
    }

    /// A modifier push-to-talk is not a Carbon registration, so it cannot collide with a
    /// chord and must not appear in the conflict set.
    func testAModifierPushToTalkIsNotInTheRegisteredCombos() {
        let labels = HotkeyBindings.default.registeredCombos.map(\.label)
        XCTAssertFalse(labels.contains("Push-to-talk"))
    }

    func testAChordPushToTalkIsInTheRegisteredCombos() {
        var bindings = HotkeyBindings.default
        let chord = KeyCombo(keyCode: UInt32(kVK_ANSI_D),
                             carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey))
        bindings.pushToTalk = .chord(chord)

        let entry = bindings.registeredCombos.first { $0.label == "Push-to-talk" }
        XCTAssertEqual(entry?.combo, chord)
    }

    // MARK: - ⌘⇧D specifically

    /// The binding this work was requested for, end to end through the recorder's own
    /// validation: it must be accepted, stored, and read back as a chord.
    func testCommandShiftDIsAcceptedAndStored() throws {
        let capture = ShortcutNotation.interpret(keyCode: UInt32(kVK_ANSI_D),
                                                 flags: [.command, .shift])
        guard case .captured(let combo) = capture else {
            return XCTFail("⌘⇧D was not accepted by the recorder: \(capture)")
        }
        XCTAssertEqual(combo.carbonModifiers, UInt32(cmdKey) | UInt32(shiftKey))
        XCTAssertEqual(ShortcutNotation.display(combo), "⇧⌘D")

        var bindings = HotkeyBindings.default
        bindings.pushToTalk = .chord(combo)
        let data = try JSONEncoder().encode(bindings)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyBindings.self, from: data).pushToTalk,
                       .chord(combo))
    }
}
