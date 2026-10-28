import XCTest
@testable import Captur

final class AppDisplayNameTests: XCTestCase {

    func testARecordedNameAlwaysWins() {
        // `dev.warp.Warp-Stable` is called "Warp". No string surgery knows that, so a
        // recorded name must never be second-guessed.
        XCTAssertEqual(
            AppDisplayName.label(bundleID: "dev.warp.Warp-Stable", recordedName: "Warp"),
            "Warp")
    }

    func testAnEmptyRecordedNameFallsBackRatherThanRenderingBlank() {
        XCTAssertEqual(
            AppDisplayName.label(bundleID: "com.google.Chrome", recordedName: ""),
            "Chrome")
    }

    func testTheLastComponentIsTheName() {
        XCTAssertEqual(AppDisplayName.derived(from: "com.google.Chrome"), "Chrome")
        XCTAssertEqual(AppDisplayName.derived(from: "com.apple.Safari"), "Safari")
    }

    func testHyphensAndUnderscoresBecomeSpaces() {
        XCTAssertEqual(AppDisplayName.derived(from: "dev.warp.Warp-Stable"), "Warp Stable")
        XCTAssertEqual(AppDisplayName.derived(from: "com.example.My_App"), "My App")
    }

    func testARunTogetherNameIsLeftAlone() {
        // Splitting "claudefordesktop" needs a dictionary, and a wrong split reads worse
        // than none.
        XCTAssertEqual(AppDisplayName.derived(from: "com.anthropic.claudefordesktop"),
                       "claudefordesktop")
    }

    func testAnIdentifierWithNoDotsIsItsOwnName() {
        XCTAssertEqual(AppDisplayName.derived(from: "Terminal"), "Terminal")
    }

    func testATrailingDotDoesNotProduceAnEmptyLabel() {
        // I expected the whole identifier back here and was wrong: `split` drops empty
        // components, so a trailing dot yields the last *non-empty* one — which is the
        // better answer anyway. Kept as a test because the failure mode it guards
        // against, an empty label, is silent.
        XCTAssertEqual(AppDisplayName.derived(from: "com.example."), "example")
    }

    func testAnIdentifierOfNothingButDotsFallsBackToItself() {
        XCTAssertEqual(AppDisplayName.derived(from: "..."), "...")
    }

    func testNothingIsInventedWhenThereIsNothingToShow() {
        XCTAssertNil(AppDisplayName.label(bundleID: nil, recordedName: nil))
        XCTAssertNil(AppDisplayName.label(bundleID: "", recordedName: nil))
    }
}
