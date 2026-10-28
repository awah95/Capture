import XCTest
import AppKit
@testable import Captur

final class HotkeyTests: XCTestCase {

    // MARK: Bindings JSON round-trip

    func testDefaultBindingsRoundTrip() throws {
        let data = try JSONEncoder().encode(HotkeyBindings.default)
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: data)
        XCTAssertEqual(decoded, .default)
    }

    func testDefaultBindingsExactValues() {
        let d = HotkeyBindings.default
        XCTAssertEqual(d.pushToTalk, .modifier(.rightOption))
        XCTAssertEqual(d.toggleDictation, KeyCombo(keyCode: 49, carbonModifiers: 0x0800))
        XCTAssertEqual(d.toggleThought, KeyCombo(keyCode: 49, carbonModifiers: 0x0A00))
        XCTAssertEqual(d.showHistoryPalette, KeyCombo(keyCode: 49, carbonModifiers: 0x1800))
    }

    func testBindingsWithNilCombosRoundTrip() throws {
        let bindings = HotkeyBindings(
            pushToTalk: .modifier(.fnGlobe),
            toggleDictation: nil,
            toggleThought: KeyCombo(keyCode: 49, carbonModifiers: 0x0A00),
            showHistoryPalette: nil
        )
        let data = try JSONEncoder().encode(bindings)
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: data)
        XCTAssertEqual(decoded, bindings)
        XCTAssertNil(decoded.toggleDictation)
        XCTAssertNil(decoded.showHistoryPalette)
    }

    func testAllPushToTalkKeysRoundTrip() throws {
        for key in PushToTalkKey.allCases {
            let bindings = HotkeyBindings(
                pushToTalk: .modifier(key),
                toggleDictation: nil, toggleThought: nil, showHistoryPalette: nil
            )
            let data = try JSONEncoder().encode(bindings)
            let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: data)
            // `.modifier(.disabled)` normalizes to `.disabled` — the same binding by a
            // single spelling, which is the invariant, not a discrepancy.
            XCTAssertEqual(decoded.pushToTalk, PushToTalkBinding.modifier(key).normalized)
        }
    }

    // MARK: PushToTalkDetector — Right Option

    func testRightOptionPressAndRelease() {
        var d = PushToTalkDetector(key: .rightOption)
        XCTAssertEqual(d.process(keyCode: 61, flags: [.option]), .down)
        XCTAssertTrue(d.isDown)
        XCTAssertEqual(d.process(keyCode: 61, flags: []), .up)
        XCTAssertFalse(d.isDown)
    }

    func testRightOptionSubThresholdTapEmitsBothEdges() {
        // A press-and-release under 150ms still produces both events — no debounce.
        var d = PushToTalkDetector(key: .rightOption)
        XCTAssertEqual(d.process(keyCode: 61, flags: [.option]), .down)
        XCTAssertEqual(d.process(keyCode: 61, flags: []), .up)
    }

    func testRightOptionRepeatedFlagNoiseWhileHeld() {
        var d = PushToTalkDetector(key: .rightOption)
        XCTAssertEqual(d.process(keyCode: 61, flags: [.option]), .down)
        // Repeated flagsChanged with the flag still present must not re-emit.
        XCTAssertEqual(d.process(keyCode: 61, flags: [.option]), .none)
        XCTAssertEqual(d.process(keyCode: 61, flags: [.option]), .none)
        XCTAssertTrue(d.isDown)
        XCTAssertEqual(d.process(keyCode: 61, flags: []), .up)
    }

    func testRightOptionReleaseWithoutPressIsNone() {
        var d = PushToTalkDetector(key: .rightOption)
        XCTAssertEqual(d.process(keyCode: 61, flags: []), .none)
        XCTAssertFalse(d.isDown)
    }

    func testLeftOptionDoesNotTriggerRightOption() {
        // Left option shares .option but reports keyCode 58 — must be ignored.
        var d = PushToTalkDetector(key: .rightOption)
        XCTAssertEqual(d.process(keyCode: 58, flags: [.option]), .none)
        XCTAssertFalse(d.isDown)
        XCTAssertEqual(d.process(keyCode: 58, flags: []), .none)
    }

    func testOtherModifierInterferenceKeepsRightOptionDown() {
        var d = PushToTalkDetector(key: .rightOption)
        XCTAssertEqual(d.process(keyCode: 61, flags: [.option]), .down)
        // Press shift (keyCode 56) while option held — different key, still down.
        XCTAssertEqual(d.process(keyCode: 56, flags: [.option, .shift]), .none)
        XCTAssertTrue(d.isDown)
        // Release shift — option still held.
        XCTAssertEqual(d.process(keyCode: 56, flags: [.option]), .none)
        XCTAssertTrue(d.isDown)
        // Now release option.
        XCTAssertEqual(d.process(keyCode: 61, flags: []), .up)
    }

    // MARK: PushToTalkDetector — Right Command

    func testRightCommandPressAndRelease() {
        var d = PushToTalkDetector(key: .rightCommand)
        XCTAssertEqual(d.process(keyCode: 54, flags: [.command]), .down)
        XCTAssertEqual(d.process(keyCode: 54, flags: []), .up)
    }

    func testRightCommandIgnoresOptionKey() {
        var d = PushToTalkDetector(key: .rightCommand)
        XCTAssertEqual(d.process(keyCode: 61, flags: [.option]), .none)
        XCTAssertFalse(d.isDown)
    }

    // MARK: PushToTalkDetector — fnGlobe

    func testFnGlobePressAndRelease() {
        var d = PushToTalkDetector(key: .fnGlobe)
        // fn is identified by the .function transition; keyCode is ignored.
        XCTAssertEqual(d.process(keyCode: 63, flags: [.function]), .down)
        XCTAssertTrue(d.isDown)
        XCTAssertEqual(d.process(keyCode: 63, flags: []), .up)
        XCTAssertFalse(d.isDown)
    }

    func testFnGlobeRepeatedNoise() {
        var d = PushToTalkDetector(key: .fnGlobe)
        XCTAssertEqual(d.process(keyCode: 63, flags: [.function]), .down)
        XCTAssertEqual(d.process(keyCode: 0, flags: [.function]), .none)
        XCTAssertEqual(d.process(keyCode: 63, flags: [.function]), .none)
        XCTAssertEqual(d.process(keyCode: 63, flags: []), .up)
    }

    func testFnGlobeOtherModifierWhileHeld() {
        var d = PushToTalkDetector(key: .fnGlobe)
        XCTAssertEqual(d.process(keyCode: 63, flags: [.function]), .down)
        // Press option while fn held: .function still present → stays down.
        XCTAssertEqual(d.process(keyCode: 61, flags: [.function, .option]), .none)
        XCTAssertTrue(d.isDown)
        XCTAssertEqual(d.process(keyCode: 63, flags: []), .up)
    }

    // MARK: PushToTalkDetector — disabled

    func testDisabledNeverEmits() {
        var d = PushToTalkDetector(key: .disabled)
        XCTAssertEqual(d.process(keyCode: 61, flags: [.option]), .none)
        XCTAssertEqual(d.process(keyCode: 54, flags: [.command]), .none)
        XCTAssertEqual(d.process(keyCode: 63, flags: [.function]), .none)
        XCTAssertFalse(d.isDown)
    }

    // MARK: PushToTalkLatch — hold vs tap-to-latch (spec §4.1)

    func testHoldingLongerThanTheTapWindowStopsOnRelease() {
        var latch = PushToTalkLatch()
        XCTAssertEqual(latch.down(at: 10.0), .start)
        // Just past the window. Deliberately not exactly `tapThreshold`: 0.35 has no
        // exact binary representation, so an on-the-nose comparison would be asserting
        // the rounding of a Double rather than the behaviour of the latch.
        XCTAssertEqual(latch.up(at: 10.0 + PushToTalkLatch.tapThreshold + 0.01), .stop)
        XCTAssertFalse(latch.isActive)
    }

    func testTapUnderTheThresholdLatchesAndTheNextTapStops() {
        var latch = PushToTalkLatch()
        XCTAssertEqual(latch.down(at: 10.0), .start)
        // Released after 120 ms: a tap, so the recording keeps running.
        XCTAssertEqual(latch.up(at: 10.12), .none)
        XCTAssertTrue(latch.isActive, "a latched recording is still running")
        XCTAssertEqual(latch.down(at: 12.0), .stop, "tapping again ends it")
        XCTAssertFalse(latch.isActive)
        XCTAssertEqual(latch.up(at: 12.05), .none, "the release of the ending tap does nothing")
    }

    func testRepeatedDownWhileHeldNeverRestartsTheCapture() {
        var latch = PushToTalkLatch()
        XCTAssertEqual(latch.down(at: 1.0), .start)
        XCTAssertEqual(latch.down(at: 1.1), .none)
        XCTAssertEqual(latch.up(at: 3.0), .stop)
    }

    func testReleaseWithoutAPressIsIgnored() {
        var latch = PushToTalkLatch()
        XCTAssertEqual(latch.up(at: 5.0), .none)
        XCTAssertFalse(latch.isActive)
    }

    func testResetMakesTheNextTapStartRatherThanStop() {
        var latch = PushToTalkLatch()
        XCTAssertEqual(latch.down(at: 1.0), .start)
        XCTAssertEqual(latch.up(at: 1.05), .none)      // latched
        latch.reset()                                   // ended by Esc or the menu bar
        XCTAssertEqual(latch.down(at: 2.0), .start,
                       "a latch left over from a recording that ended elsewhere must not stop the next one")
    }

    // MARK: Esc-gating logic (pure)

    func testEscGateAllBranches() {
        XCTAssertTrue(EscGate.shouldRegisterEsc(captureActive: true, suspended: false))
        XCTAssertFalse(EscGate.shouldRegisterEsc(captureActive: false, suspended: false))
        // Suspended (Settings recorder open) never registers Esc, even mid-capture.
        XCTAssertFalse(EscGate.shouldRegisterEsc(captureActive: true, suspended: true))
        XCTAssertFalse(EscGate.shouldRegisterEsc(captureActive: false, suspended: true))
    }

    // MARK: Capture-gated transients (Esc + Return) — pure

    func testCaptureTransientsAreEscapeAndReturnWhileCapturing() {
        let live = CaptureTransients.bindings(captureActive: true, suspended: false)
        XCTAssertEqual(live.count, 2)
        XCTAssertEqual(live[.cancelCapture], KeyCombo(keyCode: 53, carbonModifiers: 0))
        XCTAssertEqual(live[.endCapture], KeyCombo(keyCode: 36, carbonModifiers: 0),
                       "plain Return, no modifiers — spec §4.1 ends a latched recording")
    }

    func testCaptureTransientsAreEmptyWheneverTheMicrophoneIsNotHeld() {
        // This is the teardown guarantee: no capture, no Return key stolen from the
        // rest of the system. Getting this wrong breaks Return machine-wide.
        XCTAssertTrue(CaptureTransients.bindings(captureActive: false, suspended: false).isEmpty)
        XCTAssertTrue(CaptureTransients.bindings(captureActive: false, suspended: true).isEmpty)
        XCTAssertTrue(CaptureTransients.bindings(captureActive: true, suspended: true).isEmpty,
                      "a suspended manager (Settings recorder open) holds no transients either")
    }

    func testEscGateAgreesWithTheGeneralTransientRule() {
        for captureActive in [true, false] {
            for suspended in [true, false] {
                let viaGate = EscGate.shouldRegisterEsc(captureActive: captureActive, suspended: suspended)
                let viaBindings = CaptureTransients
                    .bindings(captureActive: captureActive, suspended: suspended)[.cancelCapture] != nil
                XCTAssertEqual(viaGate, viaBindings, "captureActive=\(captureActive) suspended=\(suspended)")
            }
        }
    }

    func testEveryHotkeyActionHasAStableRawValue() {
        // The raw values are the wire format for any future persisted binding map;
        // renaming one silently would repoint a user's shortcut at another action.
        XCTAssertEqual(Set(HotkeyAction.allCases.map(\.rawValue)).count, HotkeyAction.allCases.count)
        XCTAssertEqual(HotkeyAction.endCapture.rawValue, "endCapture")
        XCTAssertEqual(HotkeyAction.retryLast.rawValue, "retryLast")
    }
}
