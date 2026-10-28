import XCTest
@testable import Captur

/// `MenuBarController` owns an `NSStatusItem`, which a unit test has no business
/// creating — so these cover the two pure functions that decide what that item shows.
/// Constructing the controller does not touch the status bar; only `install()` does.
@MainActor
final class MenuBarControllerTests: XCTestCase {

    private func makeController(
        showOverview: (() -> Void)? = nil,
        showHistory: (() -> Void)? = nil,
        showSettings: (() -> Void)? = nil,
        showSetup: (() -> Void)? = nil
    ) -> MenuBarController {
        MenuBarController(actions: .init(
            startDictation: {},
            stopDictation: {},
            cancelDictation: {},
            showHistory: showHistory,
            showSettings: showSettings,
            showDiagnostics: {},
            showSetup: showSetup,
            quit: {},
            showOverview: showOverview))
    }

    // MARK: - The menu is not rebuilt every second

    /// The regression this guards: `.recording` carries `elapsed`, which the pipeline
    /// republishes every whole second. If the menu's identity were derived from the
    /// phase itself, `statusItem.menu` would be replaced once a second for the whole
    /// dictation — and replacing an open menu dismisses it, exactly when the user is
    /// reaching for "Stop Dictation".
    func testTheMenuShapeIgnoresTheElapsedSecond() {
        let controller = makeController()
        let first = controller.menuShape(for: .recording(elapsed: 1, modeName: "Verbatim"))
        let thirtieth = controller.menuShape(for: .recording(elapsed: 30, modeName: "Verbatim"))
        XCTAssertEqual(first, thirtieth)
    }

    func testTheMenuShapeIgnoresTheModeName() {
        let controller = makeController()
        XCTAssertEqual(controller.menuShape(for: .recording(elapsed: 5, modeName: "Verbatim")),
                       controller.menuShape(for: .recording(elapsed: 5, modeName: "Email")))
    }

    func testTheMenuShapeChangesWhenTheMicrophoneIsTakenAndGivenBack() {
        let controller = makeController()
        let idle = controller.menuShape(for: .idle)
        let recording = controller.menuShape(for: .recording(elapsed: 0, modeName: "Verbatim"))
        XCTAssertNotEqual(idle, recording)
        XCTAssertFalse(idle.holdsMicrophone)
        XCTAssertFalse(controller.menuShape(for: .success(words: 10, wpm: 100)).holdsMicrophone)
    }

    /// Arming already holds the microphone, so the menu offers Stop from the first
    /// moment — not once the first buffer lands.
    func testArmingAlreadyOffersStop() {
        let controller = makeController()
        let phases: [PipelinePhase] = [
            .arming,
            .recording(elapsed: 0, modeName: "Verbatim")
        ]

        for phase in phases {
            XCTAssertTrue(controller.menuShape(for: phase).holdsMicrophone)
            let titles = controller.buildMenu(phase: phase).items.map(\.title)
            XCTAssertTrue(titles.contains("Stop Dictation"), "missing Stop for \(phase)")
            XCTAssertTrue(titles.contains("Cancel"), "missing Cancel for \(phase)")
            XCTAssertFalse(titles.contains("Start Dictation"), "offered Start for \(phase)")
        }
    }

    func testSupplyingAHistoryActionChangesTheMenuShape() {
        let without = makeController().menuShape(for: .idle)
        let with = makeController(showHistory: {}).menuShape(for: .idle)
        XCTAssertNotEqual(without, with)
    }

    func testSupplyingAnOverviewActionChangesTheMenuShape() {
        let without = makeController().menuShape(for: .idle)
        let with = makeController(showOverview: {}).menuShape(for: .idle)
        XCTAssertFalse(without.hasOverview)
        XCTAssertTrue(with.hasOverview)
        XCTAssertNotEqual(without, with)
    }

    func testTheStatusLabelIgnoresElapsedAndModeNames() {
        let controller = makeController()
        XCTAssertEqual(controller.menuStatusTitle(
            for: .recording(elapsed: 1, modeName: "Verbatim")), "Listening")
        XCTAssertEqual(controller.menuStatusTitle(
            for: .recording(elapsed: 99, modeName: "Email")), "Listening")
        XCTAssertEqual(controller.menuShape(
            for: .recording(elapsed: 1, modeName: "Verbatim")),
                       controller.menuShape(
            for: .recording(elapsed: 99, modeName: "Email")))
    }

    func testTheMenuStatusCoversEveryPipelineStage() {
        let controller = makeController()
        XCTAssertEqual(controller.menuStatus(for: .idle), .ready)
        XCTAssertEqual(controller.menuStatus(for: .arming), .starting)
        XCTAssertEqual(controller.menuStatus(
            for: .recording(elapsed: 0, modeName: "Verbatim")), .listening)
        XCTAssertEqual(controller.menuStatus(for: .transcribing), .processing)
        XCTAssertEqual(controller.menuStatus(for: .refining(modeName: "Email")), .processing)
        XCTAssertEqual(controller.menuStatus(for: .success(words: 12, wpm: 90)), .complete)
        XCTAssertEqual(controller.menuStatus(
            for: .error(message: "Offline", retryable: true)), .failed)
    }

    func testTheNativeMenuKeepsEveryExistingDestination() {
        let menu = makeController(showOverview: {}, showHistory: {}, showSettings: {}, showSetup: {})
            .buildMenu(phase: .idle)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Ready"))
        XCTAssertTrue(titles.contains("Start Dictation"))
        XCTAssertTrue(titles.contains("Open Captur…"))
        XCTAssertTrue(titles.contains("Captures…"))
        XCTAssertTrue(titles.contains("Settings…"))
        XCTAssertTrue(titles.contains("Diagnostics…"))
        XCTAssertTrue(titles.contains("Quit Captur"))
    }

    func testOpenCapturItemInvokesTheInjectedOverviewAction() throws {
        var openCount = 0
        let controller = makeController(showOverview: { openCount += 1 })
        let menu = controller.buildMenu(phase: .idle)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Captur…" })

        XCTAssertTrue(item.isEnabled)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(controller.responds(to: action))
        _ = controller.perform(action)
        XCTAssertEqual(openCount, 1)
    }

    func testOpenCapturRemainsVisibleButDisabledWithoutADestination() throws {
        let menu = makeController().buildMenu(phase: .idle)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Captur…" })
        XCTAssertFalse(item.isEnabled)
    }

    // MARK: - The icon

    /// The icon is reapplied on its own input, so it must also not vary with elapsed.
    func testTheIconIsStableAcrossTheElapsedSecond() {
        let controller = makeController()
        XCTAssertEqual(controller.iconSpec(for: .recording(elapsed: 1, modeName: "Verbatim")),
                       controller.iconSpec(for: .recording(elapsed: 30, modeName: "Verbatim")))
    }

    func testOnlyARecordingPulses() {
        let controller = makeController()
        XCTAssertTrue(controller.iconSpec(for: .recording(elapsed: 0, modeName: "Verbatim")).pulses)
        for phase: PipelinePhase in [.idle, .arming, .transcribing, .refining(modeName: "Verbatim"),
                                     .success(words: 1, wpm: 1), .error(message: "x", retryable: true)] {
            XCTAssertFalse(controller.iconSpec(for: phase).pulses, "\(phase) must not pulse")
        }
    }

    func testIdleIsATemplateIconWithNoTint() {
        let spec = makeController().iconSpec(for: .idle)
        XCTAssertEqual(spec.symbol, "waveform")
        XCTAssertTrue(spec.isTemplate)
        XCTAssertNil(spec.tint)
    }

    /// Spec §9 reserves red for recording; the glyph is what follows the mode.
    func testARecordingUsesTheModeGlyphAndAFixedRedTint() {
        let controller = MenuBarController(
            actions: .init(startDictation: {}, stopDictation: {}, cancelDictation: {},
                           showHistory: nil, showSettings: nil, showDiagnostics: {},
                           showSetup: nil, quit: {}),
            modeSymbol: { mode in "symbol.for.\(mode)" })
        let spec = controller.iconSpec(for: .recording(elapsed: 0, modeName: "Email"))
        XCTAssertEqual(spec.symbol, "symbol.for.Email")
        XCTAssertEqual(spec.tint, .systemRed)
    }

    // MARK: - The setup item earns its place

    @MainActor
    func testTheSetupItemIsOfferedOnlyWhileSomethingIsMissing() {
        // Spec §10.6: the checklist "disappears from launch once every row is satisfied"
        // and is reachable again from Settings. A permanent menu entry for a finished
        // setup is clutter — and the app shipped with one until it was looked at.
        let controller = MenuBarController(actions: .init(
            startDictation: {}, stopDictation: {}, cancelDictation: {},
            showHistory: {}, showSettings: {}, showDiagnostics: {},
            showSetup: {}, needsSetup: { false }))

        XCTAssertFalse(controller.menuShape(for: .idle).hasSetup)
    }

    @MainActor
    func testTheSetupItemAppearsWhileAPrerequisiteIsMissing() {
        let controller = MenuBarController(actions: .init(
            startDictation: {}, stopDictation: {}, cancelDictation: {},
            showHistory: {}, showSettings: {}, showDiagnostics: {},
            showSetup: {}, needsSetup: { true }))

        XCTAssertTrue(controller.menuShape(for: .idle).hasSetup)
    }

    @MainActor
    func testTheMenuShapeDetectsWhenSetupBecomesSatisfied() {
        // The prerequisite publisher asks `refreshMenu()` to rebuild explicitly; the
        // shape still has to represent the live closure value for ordinary phase-driven
        // rebuilds and for callers deciding whether a refresh has meaningful work.
        var needed = true
        let controller = MenuBarController(actions: .init(
            startDictation: {}, stopDictation: {}, cancelDictation: {},
            showHistory: {}, showSettings: {}, showDiagnostics: {},
            showSetup: {}, needsSetup: { needed }))

        let before = controller.menuShape(for: .idle)
        needed = false
        XCTAssertNotEqual(before, controller.menuShape(for: .idle))
    }
}
