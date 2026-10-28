import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Captur

/// The Carbon registration path had no tests at all, and that is where it was hiding a
/// defect: `HotkeyManager.register` discarded the `OSStatus`, so a combo Carbon refused
/// was silently not registered and `apply` — declared `throws`, with
/// `HotkeyError.registrationFailed` sitting unused — returned normally.
///
/// The consequence was not academic. Task 25's shortcut recorder reverts a combo the
/// system already owns ("⌘Space is taken by Spotlight") and shows the user why; it
/// decides that by catching the throw. Against the old manager it could never fire, so
/// the app would persist a shortcut that silently does nothing after the next launch.
/// Transient failures were swallowed the same way, which is worse: Esc cancels a live
/// capture, and a failed Esc registration meant a recording nobody could cancel and
/// nobody was told about.
final class HotkeyRegistrationTests: XCTestCase {

    /// Records what was asked of Carbon and refuses exactly what a test tells it to.
    private final class FakeRegistrar: CarbonHotkeyRegistering {
        struct Attempt: Hashable {
            let keyCode: UInt32
            let modifiers: UInt32
        }

        /// Combos to refuse, and the status to refuse them with.
        var refusing: [FakeRegistrar.Attempt: OSStatus] = [:]
        private(set) var attempts: [Attempt] = []
        private(set) var registered: [Attempt] = []
        private(set) var unregisterCount = 0

        func register(keyCode: UInt32,
                      modifiers: UInt32,
                      signature: OSType,
                      id: UInt32) -> Result<CarbonHotkeyHandle, HotkeyError> {
            let attempt = Attempt(keyCode: keyCode, modifiers: modifiers)
            attempts.append(attempt)
            if let status = refusing[attempt] { return .failure(.registrationFailed(status)) }
            registered.append(attempt)
            return .success(CarbonHotkeyHandle(ref: nil))
        }

        func unregister(_ handle: CarbonHotkeyHandle) {
            unregisterCount += 1
            if let index = registered.firstIndex(where: { _ in true }) {
                registered.remove(at: index)
            }
        }
    }

    private let space = KeyCombo(keyCode: 49, carbonModifiers: UInt32(optionKey))
    private let thought = KeyCombo(keyCode: 49, carbonModifiers: UInt32(optionKey | shiftKey))

    @MainActor
    private func makeManager() -> (HotkeyManager, FakeRegistrar) {
        let registrar = FakeRegistrar()
        return (HotkeyManager(registrar: registrar), registrar)
    }

    // MARK: apply

    @MainActor
    func testApplyThrowsTheStatusCarbonRefusedWith() {
        let (manager, registrar) = makeManager()
        registrar.refusing[.init(keyCode: 49, modifiers: UInt32(optionKey))] = OSStatus(-9878)

        var bindings = HotkeyBindings.default
        bindings.toggleDictation = space

        XCTAssertThrowsError(try manager.apply(bindings)) { error in
            XCTAssertEqual(error as? HotkeyError, .registrationFailed(OSStatus(-9878)))
        }
    }

    @MainActor
    func testApplySucceedsWhenCarbonAcceptsEverything() {
        let (manager, registrar) = makeManager()
        XCTAssertNoThrow(try manager.apply(.default))
        XCTAssertEqual(registrar.registered.count, 3, "three combo bindings ship by default")
    }

    @MainActor
    func testARefusedComboDoesNotStopTheOthersFromRegistering() {
        // A conflict on one shortcut must not cost the user the other two. The throw
        // reports the failure; it does not abandon the rest of the table.
        let (manager, registrar) = makeManager()
        registrar.refusing[.init(keyCode: 49, modifiers: UInt32(optionKey))] = OSStatus(-9878)

        XCTAssertThrowsError(try manager.apply(.default))
        XCTAssertEqual(registrar.registered.count, 2)
        XCTAssertFalse(registrar.registered.contains(.init(keyCode: 49, modifiers: UInt32(optionKey))))
    }

    @MainActor
    func testTheManagerKEEPSTheRegistrationsThatSucceededAlongsideARefusal() {
        // Counting what the registrar was *asked* is not enough: a manager that forgets
        // the registrations it got would leak them (nothing left to unregister) and
        // would stop dispatching those keys, while every attempt-counting assertion
        // still passed. Teardown is the observable proxy — re-applying must hand back
        // exactly the two it is still holding.
        let (manager, registrar) = makeManager()
        registrar.refusing[.init(keyCode: 49, modifiers: UInt32(optionKey))] = OSStatus(-9878)

        XCTAssertThrowsError(try manager.apply(.default))
        let handedBackBefore = registrar.unregisterCount

        XCTAssertThrowsError(try manager.apply(.default))

        XCTAssertEqual(registrar.unregisterCount - handedBackBefore, 2,
                       "the two accepted registrations must still be held, and released")
    }

    @MainActor
    func testTheFirstRefusalIsReportedWhenSeveralComboAreTaken() {
        let (manager, registrar) = makeManager()
        registrar.refusing[.init(keyCode: 49, modifiers: UInt32(optionKey))] = OSStatus(-9878)
        registrar.refusing[.init(keyCode: 49, modifiers: UInt32(optionKey | shiftKey))] = OSStatus(-9870)

        XCTAssertThrowsError(try manager.apply(.default)) { error in
            XCTAssertEqual(error as? HotkeyError, .registrationFailed(OSStatus(-9878)),
                           "the first refusal in binding order is the one reported")
        }
    }

    @MainActor
    func testASuspendedApplyDefersRegistrationAndThereforeCannotThrow() {
        // Documented behaviour rather than an accident: `apply` while suspended stores
        // the bindings and registers nothing, so there is no Carbon verdict yet. The
        // recorder resumes BEFORE applying for exactly this reason.
        let (manager, registrar) = makeManager()
        registrar.refusing[.init(keyCode: 49, modifiers: UInt32(optionKey))] = OSStatus(-9878)
        manager.suspend()

        XCTAssertNoThrow(try manager.apply(.default))
        XCTAssertTrue(registrar.attempts.isEmpty)
    }

    @MainActor
    func testResumeAfterASuspendedApplyReportsTheRefusalThroughTheCallback() {
        // resume() is not a throwing call, so the deferred verdict has to arrive
        // somewhere. It arrives here — otherwise a refusal booked while suspended
        // would vanish.
        let (manager, registrar) = makeManager()
        registrar.refusing[.init(keyCode: 49, modifiers: UInt32(optionKey))] = OSStatus(-9878)

        var failures: [(HotkeyAction, HotkeyError)] = []
        manager.onRegistrationFailure = { failures.append(($0, $1)) }

        manager.suspend()
        XCTAssertNoThrow(try manager.apply(.default))
        manager.resume()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.0, .toggleDictation)
        XCTAssertEqual(failures.first?.1, .registrationFailed(OSStatus(-9878)))
    }

    // MARK: Transients

    @MainActor
    func testARefusedTransientIsReportedRatherThanSwallowed() {
        // Esc cancels a live capture. A silently failed Esc registration is a recording
        // the user cannot cancel, with nothing on screen to say so.
        let (manager, registrar) = makeManager()
        registrar.refusing[.init(keyCode: 53, modifiers: 0)] = OSStatus(-9878)

        var failures: [(HotkeyAction, HotkeyError)] = []
        manager.onRegistrationFailure = { failures.append(($0, $1)) }

        try? manager.apply(.default)
        manager.setCaptureActive(true)

        XCTAssertEqual(failures.map(\.0), [.cancelCapture])
        XCTAssertEqual(failures.first?.1, .registrationFailed(OSStatus(-9878)))
    }

    @MainActor
    func testAnAcceptedTransientReportsNothing() {
        let (manager, _) = makeManager()
        var failures: [(HotkeyAction, HotkeyError)] = []
        manager.onRegistrationFailure = { failures.append(($0, $1)) }

        try? manager.apply(.default)
        manager.setCaptureActive(true)

        XCTAssertTrue(failures.isEmpty)
    }

    @MainActor
    func testRegisterTransientStillThrowsForItsDirectCaller() {
        // `registerTransient` is called by the capsule for ⌘R, which handles its own
        // error. That contract does not change.
        let (manager, registrar) = makeManager()
        registrar.refusing[.init(keyCode: 15, modifiers: UInt32(cmdKey))] = OSStatus(-9878)

        XCTAssertThrowsError(
            try manager.registerTransient(KeyCombo(keyCode: 15, carbonModifiers: UInt32(cmdKey)),
                                          action: .retryLast)
        ) { error in
            XCTAssertEqual(error as? HotkeyError, .registrationFailed(OSStatus(-9878)))
        }
    }

    @MainActor
    func testCaptureTeardownUnregistersWhatItRegistered() {
        let (manager, registrar) = makeManager()
        try? manager.apply(.default)
        let afterCombos = registrar.unregisterCount

        manager.setCaptureActive(true)
        manager.setCaptureActive(false)

        XCTAssertGreaterThan(registrar.unregisterCount, afterCombos,
                             "Esc and ⏎ must be handed back when the capture ends")
    }

    @MainActor
    func testTheProductionRegistrarIsTheDefault() {
        // The seam exists for testability; it must not change what ships.
        let manager = HotkeyManager()
        XCTAssertTrue(manager.registrarIsCarbon,
                      "constructing HotkeyManager() must still talk to real Carbon")
    }
}
