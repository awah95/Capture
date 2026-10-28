import AppKit
import XCTest
@testable import Captur

@MainActor
final class CapturWindowPresentationTests: XCTestCase {
    func testClosingWindowIsExcludedWhileAppKitStillReportsItVisible() {
        let closing = StubWindow(isVisible: true, canBecomeKey: true)

        XCTAssertFalse(CapturWindowPresentation.windowsWantRegularPolicy(
            in: [closing], excluding: closing))
    }

    func testAnotherVisibleOrdinaryWindowKeepsRegularPolicy() {
        let closing = StubWindow(isVisible: true, canBecomeKey: true)
        let other = StubWindow(isVisible: true, canBecomeKey: true)

        XCTAssertTrue(CapturWindowPresentation.windowsWantRegularPolicy(
            in: [closing, other], excluding: closing))
    }

    func testKeyCapablePanelDoesNotKeepRegularPolicy() {
        let hud = StubPanel(isVisible: true, canBecomeKey: true)

        XCTAssertFalse(CapturWindowPresentation.windowsWantRegularPolicy(in: [hud]))
    }
}

/// These windows never order on screen. Overriding the two facts the policy reads
/// keeps the lifecycle tests deterministic and prevents them from stealing focus.
private final class StubWindow: NSWindow {
    private let stubIsVisible: Bool
    private let stubCanBecomeKey: Bool

    override var isVisible: Bool { stubIsVisible }
    override var canBecomeKey: Bool { stubCanBecomeKey }

    init(isVisible: Bool, canBecomeKey: Bool) {
        stubIsVisible = isVisible
        stubCanBecomeKey = canBecomeKey
        super.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    }
}

private final class StubPanel: NSPanel {
    private let stubIsVisible: Bool
    private let stubCanBecomeKey: Bool

    override var isVisible: Bool { stubIsVisible }
    override var canBecomeKey: Bool { stubCanBecomeKey }

    init(isVisible: Bool, canBecomeKey: Bool) {
        stubIsVisible = isVisible
        stubCanBecomeKey = canBecomeKey
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered,
                   defer: false)
    }
}
