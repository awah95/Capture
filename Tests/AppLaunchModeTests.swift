import AppKit
import XCTest
@testable import Captur

/// The test bundle is injected into the *app*, so `applicationDidFinishLaunching`
/// runs during `xcodebuild test`. Without a guard that means every test run builds
/// the composition root: global Carbon hotkeys get registered, a status item appears,
/// and a second Captur fights the one the owner is dictating into. These tests pin
/// the detection rule, and `testTheseTestsAreNotRunningTheCompositionRoot` proves the
/// guard actually held in this very process rather than asserting it in the abstract.
final class AppLaunchModeTests: XCTestCase {

    func testXCTestConfigurationFileMeansTests() {
        XCTAssertTrue(AppLaunchMode.isRunningTests(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
            testCaseClassIsLinked: false))
    }

    func testALinkedXCTestCaseClassMeansTests() {
        // `xcodebuild test-without-building` and Xcode's own runner do not always set
        // the configuration path, but XCTest is necessarily loaded into the process.
        XCTAssertTrue(AppLaunchMode.isRunningTests(environment: [:],
                                                   testCaseClassIsLinked: true))
    }

    func testAnEmptyStringConfigurationPathIsNotTests() {
        XCTAssertFalse(AppLaunchMode.isRunningTests(
            environment: ["XCTestConfigurationFilePath": ""],
            testCaseClassIsLinked: false))
    }

    func testAnOrdinaryLaunchIsNotTests() {
        XCTAssertFalse(AppLaunchMode.isRunningTests(
            environment: ["HOME": "/Users/someone"],
            testCaseClassIsLinked: false))
    }

    func testTheLiveDetectorReportsTestsInsideATestRun() {
        XCTAssertTrue(AppLaunchMode.isRunningTests())
    }

    @MainActor
    func testTheseTestsAreNotRunningTheCompositionRoot() {
        // If the guard regresses, this fails — and it fails for the real reason,
        // because it reads the app delegate's own record of what it decided to do.
        XCTAssertEqual(AppDelegate.launchDecision, .suppressedForTests,
                       "the app under test built its composition root; global hotkeys "
                       + "and a status item are now live in a test process")
    }
}
