import Carbon.HIToolbox
import XCTest
@testable import Captur

/// The 1–9 mode switch (spec §4.1), at both levels: the pure rule that decides
/// which combos are taken, and the Carbon-facing registration that actually takes
/// them.
///
/// Both matter for the same reason. Nine **plain digits** are occupied system-wide
/// for the length of a recording, so a registration that outlives its recording
/// leaves the user unable to type a number anywhere on the machine. That is the
/// worst bug this feature can ship, and it is a bug in exactly these two places.
final class ModeDigitHotkeyTests: XCTestCase {

    // MARK: - The rule

    func testNineModesTakeNineDigitsInBothForms() {
        let bindings = ModeDigitHotkeys.bindings(modeCount: 9, pushToTalk: .modifier(.rightOption))

        XCTAssertEqual(bindings.count, 18)
        XCTAssertEqual(bindings.filter { $0.combo.carbonModifiers == 0 }.map(\.digit),
                       [1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(bindings.filter { $0.combo.carbonModifiers != 0 }.map(\.digit),
                       [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    func testBothFormsOfADigitUseTheSameKeyCode() {
        let bindings = ModeDigitHotkeys.bindings(modeCount: 3, pushToTalk: .modifier(.rightOption))
        for digit in 1...3 {
            let forms = bindings.filter { $0.digit == digit }
            XCTAssertEqual(forms.count, 2)
            XCTAssertEqual(Set(forms.map(\.combo.keyCode)).count, 1,
                           "⌥1 and 1 are the same physical key")
        }
    }

    func testTheDigitKeyCodesAreCarbonsTopRow() {
        // 6 and 7 are transposed relative to the digits. That is Carbon's layout,
        // and getting it wrong silently binds the wrong key.
        XCTAssertEqual(ModeDigitHotkeys.digitKeyCodes,
                       [18, 19, 20, 21, 23, 22, 26, 28, 25])
        XCTAssertEqual(ModeDigitHotkeys.digitKeyCodes.count, 9)
    }

    func testTheModifiedFormMatchesThePushToTalkKeyActuallyHeld() {
        XCTAssertEqual(ModeDigitHotkeys.carbonModifier(for: PushToTalkKey.rightOption), UInt32(optionKey))
        XCTAssertEqual(ModeDigitHotkeys.carbonModifier(for: PushToTalkKey.rightCommand), UInt32(cmdKey))
        // Neither of these is a modifier `RegisterEventHotKey` can express, and a
        // disabled key is not being held in the first place.
        XCTAssertNil(ModeDigitHotkeys.carbonModifier(for: PushToTalkKey.fnGlobe))
        XCTAssertNil(ModeDigitHotkeys.carbonModifier(for: PushToTalkKey.disabled))
    }

    func testAKeyWithNoCarbonModifierProducesOnlyThePlainForm() {
        for key in [PushToTalkKey.fnGlobe, .disabled] {
            let bindings = ModeDigitHotkeys.bindings(modeCount: 4, pushToTalk: .modifier(key))
            XCTAssertEqual(bindings.count, 4, "\(key)")
            XCTAssertTrue(bindings.allSatisfy { $0.combo.carbonModifiers == 0 }, "\(key)")
        }
    }

    func testMoreModesThanDigitsAreCappedAtNine() {
        let bindings = ModeDigitHotkeys.bindings(modeCount: 40, pushToTalk: .modifier(.rightOption))
        XCTAssertEqual(bindings.filter { $0.combo.carbonModifiers == 0 }.count, 9,
                       "a tenth mode is reached through the picker, not a key that does not exist")
    }

    func testFewerModesTakeFewerDigits() {
        let bindings = ModeDigitHotkeys.bindings(modeCount: 2, pushToTalk: .modifier(.rightOption))
        XCTAssertEqual(bindings.map(\.digit).sorted(), [1, 1, 2, 2],
                       "an unregistered digit is a digit the user can still type")
    }

    func testNoModesTakeNothing() {
        XCTAssertTrue(ModeDigitHotkeys.bindings(modeCount: 0, pushToTalk: .modifier(.rightOption)).isEmpty)
        XCTAssertTrue(ModeDigitHotkeys.bindings(modeCount: -3, pushToTalk: .modifier(.rightOption)).isEmpty)
    }

    // MARK: - The registration

    /// Records what Carbon was asked for and lets a test refuse a specific combo,
    /// which cannot be arranged against real Carbon without genuinely occupying a
    /// key system-wide.
    private final class FakeRegistrar: CarbonHotkeyRegistering {
        struct Attempt: Hashable {
            let keyCode: UInt32
            let modifiers: UInt32
        }

        var refusing: Set<Attempt> = []
        private(set) var attempts: [Attempt] = []
        private(set) var live: [ObjectIdentifier: Attempt] = [:]

        var liveAttempts: [Attempt] { Array(live.values) }

        /// Only the digit registrations, so an assertion is not perturbed by the
        /// global combos `activate()` rebuilds alongside them.
        var liveDigitAttempts: [Attempt] {
            liveAttempts.filter { ModeDigitHotkeys.digitKeyCodes.contains($0.keyCode) }
        }

        func register(keyCode: UInt32,
                      modifiers: UInt32,
                      signature: OSType,
                      id: UInt32) -> Result<CarbonHotkeyHandle, HotkeyError> {
            let attempt = Attempt(keyCode: keyCode, modifiers: modifiers)
            attempts.append(attempt)
            if refusing.contains(attempt) { return .failure(.registrationFailed(-9878)) }
            let handle = CarbonHotkeyHandle(ref: nil)
            live[ObjectIdentifier(handle)] = attempt
            return .success(handle)
        }

        func unregister(_ handle: CarbonHotkeyHandle) {
            live[ObjectIdentifier(handle)] = nil
        }
    }

    @MainActor
    func testRegisteringTakesEveryComboAndUnregisteringGivesThemAllBack() throws {
        let registrar = FakeRegistrar()
        let manager = HotkeyManager(registrar: registrar)
        let bindings = ModeDigitHotkeys.bindings(modeCount: 9, pushToTalk: .modifier(.rightOption))

        try manager.registerModeDigits(bindings) { _ in }
        XCTAssertEqual(registrar.liveAttempts.count, 18)

        manager.unregisterModeDigits()
        XCTAssertTrue(registrar.liveAttempts.isEmpty,
                      "a leaked plain-digit registration breaks the number keys machine-wide")
    }

    @MainActor
    func testRegisteringTwiceReplacesRatherThanAccumulates() throws {
        let registrar = FakeRegistrar()
        let manager = HotkeyManager(registrar: registrar)

        try manager.registerModeDigits(
            ModeDigitHotkeys.bindings(modeCount: 9, pushToTalk: .modifier(.rightOption))) { _ in }
        try manager.registerModeDigits(
            ModeDigitHotkeys.bindings(modeCount: 2, pushToTalk: .modifier(.rightOption))) { _ in }

        XCTAssertEqual(registrar.liveAttempts.count, 4)
        manager.unregisterModeDigits()
        XCTAssertTrue(registrar.liveAttempts.isEmpty)
    }

    @MainActor
    func testARefusedComboIsThrownButTheOthersAreStillRegistered() {
        let registrar = FakeRegistrar()
        let manager = HotkeyManager(registrar: registrar)
        // Occupy plain "3".
        registrar.refusing = [FakeRegistrar.Attempt(keyCode: 20, modifiers: 0)]

        XCTAssertThrowsError(
            try manager.registerModeDigits(
                ModeDigitHotkeys.bindings(modeCount: 9, pushToTalk: .modifier(.rightOption))) { _ in }
        ) { error in
            XCTAssertEqual(error as? ModeDigitRefusal,
                           ModeDigitRefusal(digit: 3, underlying: .registrationFailed(-9878)),
                           "the refusal has to name the key the user just lost")
        }

        XCTAssertEqual(registrar.liveAttempts.count, 17,
                       "one occupied digit costs the user that digit, not the other eight")
        manager.unregisterModeDigits()
        XCTAssertTrue(registrar.liveAttempts.isEmpty)
    }

    @MainActor
    func testSuspendReleasesTheDigitsAndResumePutsThemBack() throws {
        let registrar = FakeRegistrar()
        let manager = HotkeyManager(registrar: registrar)

        try manager.registerModeDigits(
            ModeDigitHotkeys.bindings(modeCount: 9, pushToTalk: .modifier(.rightOption))) { _ in }
        manager.suspend()
        XCTAssertTrue(registrar.liveDigitAttempts.isEmpty,
                      "the Settings recorder must be able to type a digit")

        manager.resume()
        XCTAssertEqual(registrar.liveDigitAttempts.count, 18,
                       "resume puts back exactly what suspend took away")
        manager.unregisterModeDigits()
        XCTAssertTrue(registrar.liveDigitAttempts.isEmpty)
    }

    @MainActor
    func testTheModeDigitsDoNotDisturbTheCaptureTransients() throws {
        let registrar = FakeRegistrar()
        let manager = HotkeyManager(registrar: registrar)
        manager.setCaptureActive(true)
        let withoutDigits = registrar.liveAttempts.count

        try manager.registerModeDigits(
            ModeDigitHotkeys.bindings(modeCount: 9, pushToTalk: .modifier(.rightOption))) { _ in }
        manager.unregisterModeDigits()

        XCTAssertEqual(registrar.liveAttempts.count, withoutDigits,
                       "Esc and ⏎ survive a mode-digit round trip")
        manager.setCaptureActive(false)
    }
}
