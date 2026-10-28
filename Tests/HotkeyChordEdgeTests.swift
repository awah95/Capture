import Carbon.HIToolbox
import XCTest
@testable import Captur

/// The two-edge behaviour of a chord push-to-talk binding, driven through `HotkeyManager`
/// with a fake registrar.
///
/// What is being pinned is the routing rule: a chord press means "start", a chord release
/// means "stop", and a release of ANY OTHER hotkey means nothing at all. Getting the last
/// one wrong is not subtle — ⌥Space would start a dictation on the way down and stop it on
/// the way up, so the toggle would never work again.
///
/// Carbon itself is not under test here. Whether the release edge arrives at all was
/// settled by measurement instead, with `--probe-hotkey-release` against real keys; no
/// fake can answer that question, and a test that pretended to would be exactly the kind
/// of lying stub this project has already lost two bugs to.
@MainActor
final class HotkeyChordEdgeTests: XCTestCase {

    /// Records the id Carbon was handed for each combo, so a test can dispatch an edge to
    /// the right registration rather than guessing at registration order.
    private final class IDRecordingRegistrar: CarbonHotkeyRegistering {
        private(set) var ids: [(id: UInt32, keyCode: UInt32, modifiers: UInt32)] = []
        private(set) var unregisterCount = 0
        var refusing: Set<UInt32> = []          // keyCodes to refuse

        func register(keyCode: UInt32,
                      modifiers: UInt32,
                      signature: OSType,
                      id: UInt32) -> Result<CarbonHotkeyHandle, HotkeyError> {
            if refusing.contains(keyCode) { return .failure(.registrationFailed(-9878)) }
            ids.append((id: id, keyCode: keyCode, modifiers: modifiers))
            return .success(CarbonHotkeyHandle(ref: nil))
        }

        func unregister(_ handle: CarbonHotkeyHandle) { unregisterCount += 1 }

        func id(forKeyCode keyCode: UInt32, modifiers: UInt32) -> UInt32? {
            ids.last(where: { $0.keyCode == keyCode && $0.modifiers == modifiers })?.id
        }
    }

    private let chordKeyCode = UInt32(kVK_ANSI_D)
    private var chordModifiers: UInt32 { UInt32(cmdKey) | UInt32(shiftKey) }
    private var chord: KeyCombo {
        KeyCombo(keyCode: chordKeyCode, carbonModifiers: chordModifiers)
    }

    /// Collects what the manager dispatched. A reference type so the manager's escaping
    /// `onAction` closure and the test body look at the same list.
    private final class ActionBox {
        var actions: [HotkeyAction] = []
    }

    private func makeManager() -> (HotkeyManager, IDRecordingRegistrar, ActionBox) {
        let registrar = IDRecordingRegistrar()
        let manager = HotkeyManager(registrar: registrar)
        let box = ActionBox()
        manager.onAction = { action in box.actions.append(action) }
        return (manager, registrar, box)
    }

    private func chordBindings() -> HotkeyBindings {
        var bindings = HotkeyBindings.default
        bindings.pushToTalk = .chord(chord)
        return bindings
    }

    // MARK: - Registration

    func testAChordBindingIsRegisteredWithCarbon() throws {
        let (manager, registrar, _) = makeManager()
        try manager.apply(chordBindings())

        XCTAssertNotNil(registrar.id(forKeyCode: chordKeyCode, modifiers: chordModifiers),
                        "⌘⇧D was never handed to Carbon")
    }

    func testAModifierBindingRegistersNoExtraHotkey() throws {
        let (manager, registrar, _) = makeManager()
        try manager.apply(.default)   // Right ⌥ — a bare modifier, not registerable

        XCTAssertNil(registrar.id(forKeyCode: 61, modifiers: 0))
        XCTAssertEqual(registrar.ids.count, 3, "only the three toggle combos")
    }

    /// A refusal has no caller in a position to `try` it — `rebuildPushToTalk` is reached
    /// from `activate()` — so it has to travel out through `apply`.
    func testARefusedChordIsReportedRatherThanSilentlyDropped() {
        let (manager, registrar, _) = makeManager()
        registrar.refusing = [chordKeyCode]

        XCTAssertThrowsError(try manager.apply(chordBindings()))
    }

    // MARK: - The edges

    func testAChordPressStartsAndAChordReleaseStops() throws {
        let (manager, registrar, box) = makeManager()
        try manager.apply(chordBindings())
        let id = try XCTUnwrap(registrar.id(forKeyCode: chordKeyCode, modifiers: chordModifiers))

        manager.handleHotKey(id: id, released: false)
        manager.handleHotKey(id: id, released: true)

        XCTAssertEqual(box.actions, [.pushToTalkDown, .pushToTalkUp])
    }

    /// The rule that keeps every other shortcut working. A toggle fires on the way down
    /// only; if its release also dispatched, ⌥Space would start and immediately stop.
    func testAReleaseOfANonChordHotkeyIsIgnored() throws {
        let (manager, registrar, box) = makeManager()
        try manager.apply(chordBindings())
        let toggleID = try XCTUnwrap(registrar.id(forKeyCode: 49, modifiers: UInt32(optionKey)))

        manager.handleHotKey(id: toggleID, released: false)
        manager.handleHotKey(id: toggleID, released: true)

        XCTAssertEqual(box.actions, [.toggleDictation], "the release must not dispatch anything")
    }

    /// Holding the chord and letting go repeatedly must alternate cleanly. Measured on real
    /// keys as one press and one release per hold, with no auto-repeat, so a second down
    /// without an intervening up is not something this path has to absorb — but the
    /// alternation itself is what the latch upstream depends on.
    func testRepeatedHoldsAlternateDownAndUp() throws {
        let (manager, registrar, box) = makeManager()
        try manager.apply(chordBindings())
        let id = try XCTUnwrap(registrar.id(forKeyCode: chordKeyCode, modifiers: chordModifiers))

        for _ in 0..<3 {
            manager.handleHotKey(id: id, released: false)
            manager.handleHotKey(id: id, released: true)
        }

        XCTAssertEqual(box.actions, [.pushToTalkDown, .pushToTalkUp,
                                   .pushToTalkDown, .pushToTalkUp,
                                   .pushToTalkDown, .pushToTalkUp])
    }

    // MARK: - Suspend / resume

    /// The Settings recorder suspends the manager so it can capture ⌘⇧D without the app
    /// starting a recording out from under it. A chord that stayed registered would make
    /// recording its own replacement impossible.
    func testSuspendReleasesTheChordAndResumePutsItBack() throws {
        let (manager, registrar, box) = makeManager()
        try manager.apply(chordBindings())
        let firstID = try XCTUnwrap(registrar.id(forKeyCode: chordKeyCode,
                                                 modifiers: chordModifiers))

        manager.suspend()
        // The old id is gone; dispatching it must not resurrect a recording.
        manager.handleHotKey(id: firstID, released: false)
        XCTAssertEqual(box.actions, [], "a suspended manager holds no chord")

        manager.resume()
        let secondID = try XCTUnwrap(registrar.id(forKeyCode: chordKeyCode,
                                                  modifiers: chordModifiers))
        manager.handleHotKey(id: secondID, released: false)
        XCTAssertEqual(box.actions, [.pushToTalkDown])
    }

    /// Switching from a chord to Right ⌥ has to hand the chord back, or ⌘⇧D stays
    /// swallowed system-wide for the life of the process.
    func testSwitchingAwayFromAChordUnregistersIt() throws {
        let (manager, registrar, box) = makeManager()
        try manager.apply(chordBindings())
        let id = try XCTUnwrap(registrar.id(forKeyCode: chordKeyCode, modifiers: chordModifiers))

        try manager.apply(.default)   // back to Right ⌥

        manager.handleHotKey(id: id, released: false)
        XCTAssertEqual(box.actions, [], "the retired chord must no longer dispatch")
    }

    // MARK: - The watchdog

    /// Not a maximum recording length, and the interval says so: anything short enough to
    /// interrupt a real hold would be one.
    func testTheHoldWatchdogIsFarPastAnyRealHold() {
        XCTAssertGreaterThanOrEqual(HotkeyManager.holdWatchdogInterval, 60,
                                    "a watchdog that can end a genuine hold is a bug, not a limit")
    }
}
