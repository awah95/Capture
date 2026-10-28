import ServiceManagement
import XCTest
@testable import Captur

// MARK: - Double

/// A controllable stand-in for `SMAppService.mainApp`.
///
/// **No test in this suite may construct `SystemLoginItemService`.** `register()` writes
/// a real login item into the owner's system state, which would make an unsigned debug
/// build launch at every login, and `unregister()` would just as happily remove one the
/// owner installed themselves. Both live behind this seam and the real implementation is
/// named exactly once, in `LoginItem`'s default argument.
@MainActor
final class FakeLoginItemService: LoginItemService {
    var reported: LoginItemStatus = .notRegistered
    /// What `register()` throws, if anything.
    var registerError: Error?
    var unregisterError: Error?
    /// A status the service moves to once `register()` has been called, so the
    /// "registered but macOS wants approval" path is reachable.
    var statusAfterRegister: LoginItemStatus?
    var statusAfterUnregister: LoginItemStatus?

    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSystemSettingsCount = 0

    func status() -> LoginItemStatus { reported }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        reported = statusAfterRegister ?? .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        reported = statusAfterUnregister ?? .notRegistered
    }

    func openSystemSettings() { openSystemSettingsCount += 1 }
}

// MARK: - Tests

@MainActor
final class LoginItemTests: XCTestCase {

    private var service: FakeLoginItemService!

    override func setUp() {
        super.setUp()
        service = FakeLoginItemService()
    }

    private func makeItem() -> LoginItem {
        LoginItem(service: service)
    }

    // MARK: The four statuses

    func testAnEnabledLoginItemReadsAsOnWithNothingToExplain() {
        service.reported = .enabled
        let item = makeItem()

        XCTAssertEqual(item.status, .enabled)
        XCTAssertTrue(item.isOn)
        XCTAssertFalse(item.needsApproval)
        XCTAssertNil(item.advice, "nothing is wrong, so nothing should be said")
    }

    func testANotRegisteredLoginItemReadsAsOffWithNothingToExplain() {
        service.reported = .notRegistered
        let item = makeItem()

        XCTAssertFalse(item.isOn)
        XCTAssertFalse(item.needsApproval)
        XCTAssertNil(item.advice)
    }

    /// `.requiresApproval` is neither an error nor a success: macOS has accepted the
    /// registration but the user disabled it in System Settings → Login Items. A plain
    /// toggle here silently flips back, so the UI has to say what to do instead.
    func testRequiresApprovalIsNeitherOnNorAnErrorAndSaysWhereToGo() {
        service.reported = .requiresApproval
        let item = makeItem()

        XCTAssertEqual(item.status, .requiresApproval)
        XCTAssertFalse(item.isOn, "a toggle showing 'on' here would flip back on its own")
        XCTAssertTrue(item.needsApproval)
        let advice = item.advice ?? ""
        XCTAssertFalse(advice.isEmpty)
        XCTAssertTrue(advice.contains("System Settings"),
                      "the user has to be told where the switch is: \(advice)")
    }

    /// `.notFound` means launchd cannot find this copy of the app — the normal cause is
    /// running it from a build directory rather than `/Applications` (spec §2).
    func testNotFoundExplainsThatTheAppIsNotWhereMacOSCanLaunchIt() {
        service.reported = .notFound
        let item = makeItem()

        XCTAssertFalse(item.isOn)
        XCTAssertFalse(item.needsApproval)
        let advice = item.advice ?? ""
        XCTAssertFalse(advice.isEmpty)
        XCTAssertTrue(advice.contains("Applications"), advice)
    }

    /// The mapping from Apple's enum, exercised for all four cases. Reading these enum
    /// values touches nothing — no service is constructed and no registration happens.
    func testTheSMAppServiceStatusMappingCoversAllFourCases() {
        XCTAssertEqual(LoginItemStatus(SMAppService.Status.enabled), .enabled)
        XCTAssertEqual(LoginItemStatus(SMAppService.Status.notRegistered), .notRegistered)
        XCTAssertEqual(LoginItemStatus(SMAppService.Status.requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItemStatus(SMAppService.Status.notFound), .notFound)
    }

    // MARK: Turning it on and off

    func testTurningItOnRegistersOnceAndReReadsTheStatus() {
        let item = makeItem()
        item.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(service.unregisterCount, 0)
        XCTAssertTrue(item.isOn)
        XCTAssertNil(item.advice)
    }

    func testTurningItOffUnregistersOnce() {
        service.reported = .enabled
        let item = makeItem()
        item.setEnabled(false)

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(item.isOn)
    }

    /// Idempotence in both directions: SwiftUI will happily set a binding to the value
    /// it already has, and a second `register()` is a system call for no reason.
    func testSettingTheStateItIsAlreadyInDoesNothing() {
        service.reported = .enabled
        let item = makeItem()
        item.setEnabled(true)
        XCTAssertEqual(service.registerCount, 0)

        service.reported = .notRegistered
        item.refresh()
        item.setEnabled(false)
        XCTAssertEqual(service.unregisterCount, 0)
    }

    /// The trap: registration *succeeded*, so a naive implementation shows the toggle
    /// on — and then the app does not launch at login and the toggle reverts on the next
    /// visit with no explanation.
    func testASuccessfulRegistrationThatStillNeedsApprovalIsNotReportedAsOn() {
        service.statusAfterRegister = .requiresApproval
        let item = makeItem()
        item.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertFalse(item.isOn)
        XCTAssertTrue(item.needsApproval)
        XCTAssertFalse(item.advice?.isEmpty ?? true)
    }

    func testAFailedRegistrationSurfacesAndTheToggleReflectsRealityNotTheAttempt() {
        service.registerError = FakeFailure.boom("no bundle")
        let item = makeItem()
        item.setEnabled(true)

        XCTAssertFalse(item.isOn, "the toggle claimed success for a registration that threw")
        XCTAssertFalse(item.advice?.isEmpty ?? true)
        XCTAssertEqual(item.status, .notRegistered, "the status must be re-read, not assumed")
    }

    func testAFailedUnregistrationSurfacesAndLeavesTheItemOn() {
        service.reported = .enabled
        service.unregisterError = FakeFailure.boom("busy")
        let item = makeItem()
        item.setEnabled(false)

        XCTAssertTrue(item.isOn, "the item is still registered, so the toggle must still say so")
        XCTAssertFalse(item.advice?.isEmpty ?? true)
    }

    /// A previous failure must not stick around once the user has fixed the cause.
    func testARetryThatSucceedsClearsTheEarlierFailure() {
        service.registerError = FakeFailure.boom("no bundle")
        let item = makeItem()
        item.setEnabled(true)
        XCTAssertNotNil(item.advice)

        service.registerError = nil
        item.setEnabled(true)

        XCTAssertTrue(item.isOn)
        XCTAssertNil(item.advice)
    }

    func testRefreshReReadsAStatusThatChangedElsewhere() {
        let item = makeItem()
        XCTAssertFalse(item.isOn)

        // The user enabled it in System Settings → Login Items while Captur was open.
        service.reported = .enabled
        XCTAssertFalse(item.isOn, "something is polling SMAppService behind the app's back")

        item.refresh()
        XCTAssertTrue(item.isOn)
    }

    func testOpeningSystemSettingsGoesThroughTheSeam() {
        service.reported = .requiresApproval
        let item = makeItem()
        item.openSystemSettings()

        XCTAssertEqual(service.openSystemSettingsCount, 1)
    }
}
