import Foundation

/// Why the app needs to know it is under test.
///
/// `CapturTests` is a unit-test bundle hosted by the app, so `xcodebuild test`
/// *launches Captur* and runs `applicationDidFinishLaunching`. Building the
/// composition root there is not a harmless side effect: it registers global Carbon
/// hotkeys (⌥Space, Right ⌥, Esc, ⏎), installs a status item, and binds an audio
/// engine — in a process that exists to run assertions. Two Capturs then compete for
/// the same hotkeys and the same default input device, which is exactly the collision
/// the working method forbids agents from causing by launching the app by hand. A test
/// run was doing it silently.
///
/// The detection is a pure function of the environment so it can be tested without
/// being under test, which is the only way to check the negative case.
enum AppLaunchMode {

    /// Two signals, because neither alone is reliable. Xcode and
    /// `xcodebuild test` set `XCTestConfigurationFilePath`; some runners
    /// (`test-without-building`, attaching a debugger to a built test bundle) do not,
    /// but XCTest is necessarily linked into the process by then.
    static func isRunningTests(environment: [String: String],
                              testCaseClassIsLinked: Bool) -> Bool {
        if let path = environment["XCTestConfigurationFilePath"], !path.isEmpty {
            return true
        }
        return testCaseClassIsLinked
    }

    static func isRunningTests() -> Bool {
        isRunningTests(environment: ProcessInfo.processInfo.environment,
                       testCaseClassIsLinked: NSClassFromString("XCTestCase") != nil)
    }
}

/// What `applicationDidFinishLaunching` decided to do, kept so a test can assert the
/// guard held in its own process rather than trusting that it did.
enum LaunchDecision: Equatable, Sendable {
    case notLaunchedYet
    /// A normal launch: composition root built, hotkeys and menu bar live.
    case ranComposition
    /// One of the `--diagnose` / `--probe-*` / `--permissions` instruments.
    case ranInstrument(String)
    case suppressedForTests
}
