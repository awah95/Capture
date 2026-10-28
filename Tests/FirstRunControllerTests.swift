import XCTest
@testable import Captur

// MARK: - Test doubles
//
// Deliberately local to this file. The shared `Tests/Support/Fakes.swift` is owned by
// another branch, and nothing here should make a real Keychain, AVFoundation or IOKit
// call — a test that wrote to the login keychain would destroy the owner's real key.

@MainActor
final class StubGroqKeyStore: GroqKeyStoring {
    var stored: String?
    private(set) var readCount = 0
    private(set) var writes: [String?] = []

    init(stored: String? = nil) { self.stored = stored }

    func groqKey() -> String? {
        readCount += 1
        return stored
    }

    func setGroqKey(_ key: String?) {
        writes.append(key)
        stored = key
    }
}

@MainActor
final class StubOpenRouterKeyStore: OpenRouterKeyStoring {
    var stored: String?
    private(set) var readCount = 0

    init(stored: String? = nil) { self.stored = stored }

    func openRouterKey() -> String? {
        readCount += 1
        return stored
    }

    func setOpenRouterKey(_ key: String?) { stored = key }
}

@MainActor
final class StubMicrophonePermission: MicrophonePermitting {
    var current: PermissionStatus
    /// What the system prompt would resolve to.
    var grantsOnRequest = true
    private(set) var statusReads = 0
    private(set) var requestCount = 0

    init(_ current: PermissionStatus) { self.current = current }

    func status() -> PermissionStatus {
        statusReads += 1
        return current
    }

    func request() async -> Bool {
        requestCount += 1
        current = grantsOnRequest ? .granted : .denied
        return grantsOnRequest
    }
}

@MainActor
final class StubInputMonitoringPermission: InputMonitoringPermitting {
    var current: PermissionStatus
    var grantsOnRequest = true
    private(set) var statusReads = 0
    private(set) var requestCount = 0

    init(_ current: PermissionStatus) { self.current = current }

    func status() -> PermissionStatus {
        statusReads += 1
        return current
    }

    func request() -> Bool {
        requestCount += 1
        // macOS does not re-prompt for a permission the user has already refused: the
        // call returns false straight away and the status does not move. The stub used
        // to grant it anyway, which is why the denied path looked fine in tests and
        // dead-ended on real hardware.
        guard current != .denied else { return false }
        current = grantsOnRequest ? .granted : .denied
        return grantsOnRequest
    }
}

@MainActor
final class StubAccessibility: TextInserting {
    var trusted: Bool
    private(set) var trustReads = 0
    private(set) var promptCount = 0

    init(trusted: Bool) { self.trusted = trusted }

    func hasAccessibilityPermission() -> Bool {
        trustReads += 1
        return trusted
    }

    func requestAccessibilityPermission() { promptCount += 1 }
    func frontmostAppBundleID() -> String? { nil }
    func frontmostAppName() -> String? { nil }
    func insert(_ text: String) async -> InsertionOutcome { .insertedDirect }
}

// MARK: - Tests

@MainActor
final class FirstRunControllerTests: XCTestCase {

    private var keyStore: StubGroqKeyStore!
    private var openRouterKeyStore: StubOpenRouterKeyStore!
    private var microphone: StubMicrophonePermission!
    private var accessibility: StubAccessibility!
    private var inputMonitoring: StubInputMonitoringPermission!
    private var openedURLs: [URL] = []

    override func setUp() {
        super.setUp()
        keyStore = StubGroqKeyStore(stored: "gsk_stored")
        openRouterKeyStore = StubOpenRouterKeyStore(stored: "sk-or-stored")
        microphone = StubMicrophonePermission(.granted)
        accessibility = StubAccessibility(trusted: true)
        inputMonitoring = StubInputMonitoringPermission(.granted)
        openedURLs = []
    }

    private func makeController() -> FirstRunController {
        FirstRunController(
            keyStore: keyStore,
            microphone: microphone,
            accessibility: accessibility,
            inputMonitoring: inputMonitoring,
            openSystemSettings: { [weak self] url in self?.openedURLs.append(url) })
    }

    // MARK: needsSetup

    func testNeedsSetupIsFalseWhenEveryPrerequisiteIsMet() {
        let controller = makeController()
        XCTAssertFalse(controller.needsSetup)
        XCTAssertTrue(controller.prerequisites.allSatisfy(\.isSatisfied))
    }

    func testNeedsSetupIsTrueWhenTheGroqKeyIsMissing() {
        keyStore.stored = nil
        let controller = makeController()
        XCTAssertTrue(controller.needsSetup)
        XCTAssertEqual(controller.prerequisites.first(where: { $0.id == .groqKey })?.isSatisfied, false)
    }

    func testUnusedGroqKeyIsNotAFirstRunPrerequisite() {
        keyStore.stored = nil
        let controller = FirstRunController(
            keyStore: keyStore,
            microphone: microphone,
            accessibility: accessibility,
            inputMonitoring: inputMonitoring,
            requiresGroqKey: { false },
            openSystemSettings: { _ in })

        XCTAssertFalse(controller.needsSetup)
        XCTAssertFalse(controller.prerequisites.contains { $0.id == .groqKey })
    }

    func testRequiredOpenRouterKeyIsAFirstRunPrerequisite() {
        openRouterKeyStore.stored = nil
        let controller = FirstRunController(
            keyStore: keyStore,
            openRouterKeyStore: openRouterKeyStore,
            microphone: microphone,
            accessibility: accessibility,
            inputMonitoring: inputMonitoring,
            requiresGroqKey: { false },
            requiresOpenRouterKey: { true },
            openSystemSettings: { _ in })

        XCTAssertTrue(controller.needsSetup)
        XCTAssertEqual(
            controller.prerequisites.first(where: { $0.id == .openRouterKey })?.isSatisfied,
            false)

        openRouterKeyStore.stored = "sk-or-new"
        controller.refresh()
        XCTAssertFalse(controller.needsSetup)
    }

    func testNeedsSetupIsTrueWhenTheMicrophoneIsUndecided() {
        microphone.current = .notDetermined
        let controller = makeController()
        XCTAssertTrue(controller.needsSetup)
        XCTAssertEqual(controller.prerequisites.first(where: { $0.id == .microphone })?.isSatisfied, false)
    }

    func testNeedsSetupIsTrueWhenAccessibilityIsMissing() {
        accessibility.trusted = false
        let controller = makeController()
        XCTAssertTrue(controller.needsSetup)
        XCTAssertEqual(controller.prerequisites.first(where: { $0.id == .accessibility })?.isSatisfied, false)
    }

    func testNeedsSetupIsTrueWhenInputMonitoringIsMissing() {
        inputMonitoring.current = .denied
        let controller = makeController()
        XCTAssertTrue(controller.needsSetup)
        XCTAssertEqual(controller.prerequisites.first(where: { $0.id == .inputMonitoring })?.isSatisfied, false)
    }

    /// A key that is only whitespace is not a key. The Keychain would store nothing for
    /// it either, so treating it as satisfied would hand the user a checklist that says
    /// they are ready and a pipeline that 401s.
    func testAWhitespaceOnlyStoredKeyDoesNotSatisfyTheGroqKeyRow() {
        keyStore.stored = "   \n"
        let controller = makeController()
        XCTAssertTrue(controller.needsSetup)
        XCTAssertEqual(controller.prerequisites.first(where: { $0.id == .groqKey })?.isSatisfied, false)
    }

    func testAnEmptyStoredKeyDoesNotSatisfyTheGroqKeyRow() {
        keyStore.stored = ""
        let controller = makeController()
        XCTAssertEqual(controller.prerequisites.first(where: { $0.id == .groqKey })?.isSatisfied, false)
    }

    // MARK: ordering

    func testPrerequisitesAreOrderedGroqKeyMicrophoneAccessibilityInputMonitoring() {
        let controller = makeController()
        XCTAssertEqual(controller.prerequisites.map(\.id),
                       [.groqKey, .microphone, .accessibility, .inputMonitoring])
    }

    func testOrderingSurvivesARefresh() {
        let controller = makeController()
        keyStore.stored = nil
        inputMonitoring.current = .denied
        controller.refresh()
        XCTAssertEqual(controller.prerequisites.map(\.id),
                       [.groqKey, .microphone, .accessibility, .inputMonitoring])
    }

    func testBothProviderKeysAppearBeforeSystemPermissions() {
        let controller = FirstRunController(
            keyStore: keyStore,
            openRouterKeyStore: openRouterKeyStore,
            microphone: microphone,
            accessibility: accessibility,
            inputMonitoring: inputMonitoring,
            requiresOpenRouterKey: { true },
            openSystemSettings: { _ in })

        XCTAssertEqual(
            controller.prerequisites.map(\.id),
            [.groqKey, .openRouterKey, .microphone, .accessibility, .inputMonitoring])
    }

    // MARK: refresh

    func testRefreshRereadsLiveStatus() {
        keyStore.stored = nil
        microphone.current = .notDetermined
        accessibility.trusted = false
        inputMonitoring.current = .denied
        let controller = makeController()
        XCTAssertTrue(controller.needsSetup)

        keyStore.stored = "gsk_new"
        microphone.current = .granted
        accessibility.trusted = true
        inputMonitoring.current = .granted

        controller.refresh()

        XCTAssertFalse(controller.needsSetup)
        XCTAssertTrue(controller.prerequisites.allSatisfy(\.isSatisfied))
    }

    func testStatusIsStaleUntilRefreshIsCalled() {
        let controller = makeController()
        XCTAssertFalse(controller.needsSetup)

        keyStore.stored = nil
        accessibility.trusted = false

        // No refresh: the published value must still describe the last read.
        XCTAssertFalse(controller.needsSetup)
        XCTAssertTrue(controller.prerequisites.allSatisfy(\.isSatisfied))

        controller.refresh()
        XCTAssertTrue(controller.needsSetup)
    }

    /// The no-timer guarantee. If anything polls, the probe counters climb while the
    /// run loop is pumped and the stale value silently corrects itself.
    func testNothingPollsThePermissionProbes() {
        let controller = makeController()
        let readsAfterInit = (keyStore.readCount,
                              microphone.statusReads,
                              accessibility.trustReads,
                              inputMonitoring.statusReads)

        keyStore.stored = nil
        microphone.current = .denied
        accessibility.trusted = false
        inputMonitoring.current = .denied

        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        XCTAssertEqual(keyStore.readCount, readsAfterInit.0)
        XCTAssertEqual(microphone.statusReads, readsAfterInit.1)
        XCTAssertEqual(accessibility.trustReads, readsAfterInit.2)
        XCTAssertEqual(inputMonitoring.statusReads, readsAfterInit.3)
        XCTAssertFalse(controller.needsSetup, "Something re-read status without refresh() being called.")
    }

    func testEachRefreshReadsEveryProbeExactlyOnce() {
        let controller = makeController()
        let baseline = keyStore.readCount
        controller.refresh()
        XCTAssertEqual(keyStore.readCount, baseline + 1)
        XCTAssertEqual(microphone.statusReads, baseline + 1)
        XCTAssertEqual(accessibility.trustReads, baseline + 1)
        XCTAssertEqual(inputMonitoring.statusReads, baseline + 1)
    }

    // MARK: request

    func testRequestingTheMicrophoneWhenUndecidedShowsTheSystemPromptAndRefreshes() async {
        microphone.current = .notDetermined
        microphone.grantsOnRequest = true
        let controller = makeController()
        XCTAssertTrue(controller.needsSetup)

        controller.request(.microphone)
        await controller.inFlightRequest?.value

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertTrue(openedURLs.isEmpty, "An undecided permission must be prompted, not deep-linked.")
        XCTAssertEqual(controller.prerequisites.first(where: { $0.id == .microphone })?.isSatisfied, true)
    }

    func testRequestingADeniedMicrophoneOpensSystemSettingsInsteadOfPrompting() async {
        microphone.current = .denied
        let controller = makeController()

        controller.request(.microphone)
        await controller.inFlightRequest?.value

        XCTAssertEqual(microphone.requestCount, 0, "A denied permission cannot be re-prompted; macOS ignores it.")
        XCTAssertEqual(openedURLs.count, 1)
        XCTAssertEqual(openedURLs.first?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func testRequestingAccessibilityTriggersTheAccessibilityPrompt() async {
        accessibility.trusted = false
        let controller = makeController()

        controller.request(.accessibility)
        await controller.inFlightRequest?.value

        XCTAssertEqual(accessibility.promptCount, 1)
    }

    func testRequestingAccessibilityWhenAlreadyTrustedOpensSystemSettings() async {
        accessibility.trusted = true
        let controller = makeController()

        controller.request(.accessibility)
        await controller.inFlightRequest?.value

        XCTAssertEqual(accessibility.promptCount, 0)
        XCTAssertEqual(openedURLs.first?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func testRequestingInputMonitoringWhenUndecidedAsksForAccess() async {
        inputMonitoring.current = .notDetermined
        inputMonitoring.grantsOnRequest = true
        let controller = makeController()

        controller.request(.inputMonitoring)
        await controller.inFlightRequest?.value

        XCTAssertEqual(inputMonitoring.requestCount, 1)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(controller.prerequisites.first(where: { $0.id == .inputMonitoring })?.isSatisfied, true)
    }

    /// Denied Input Monitoring asks *anyway*, then falls back to System Settings.
    ///
    /// The regression this pins was found on real hardware: `IOHIDRequestAccess` is
    /// what puts an app into the Input Monitoring list at all, so skipping it when the
    /// status is already `denied` sent the user to a Privacy pane the app was not
    /// listed in — nothing to switch on, and no way to add it. The redundant-looking
    /// request is the part that makes the deep link useful.
    func testRequestingDeniedInputMonitoringAsksAnywayThenOpensSystemSettings() async {
        inputMonitoring.current = .denied
        let controller = makeController()

        controller.request(.inputMonitoring)
        await controller.inFlightRequest?.value

        XCTAssertEqual(inputMonitoring.requestCount, 1)
        XCTAssertEqual(openedURLs.first?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        XCTAssertEqual(controller.prerequisites.first(where: { $0.id == .inputMonitoring })?.isSatisfied,
                       false)
    }

    /// The opposite case: a request that actually succeeds must not then throw the
    /// user into System Settings for a permission they just granted.
    func testRequestingInputMonitoringThatSucceedsDoesNotOpenSystemSettings() async {
        inputMonitoring.current = .notDetermined
        inputMonitoring.grantsOnRequest = true
        let controller = makeController()

        controller.request(.inputMonitoring)
        await controller.inFlightRequest?.value

        XCTAssertEqual(inputMonitoring.requestCount, 1)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    /// The key row is answered inside the app, not by a system prompt and not by a
    /// deep link — that is the whole point of the Task 11 scope amendment.
    func testRequestingTheGroqKeyRevealsTheInAppFieldAndPromptsNothing() async {
        keyStore.stored = nil
        let controller = makeController()
        var revealed = 0
        controller.onRevealKeyField = { revealed += 1 }

        controller.request(.groqKey)
        await controller.inFlightRequest?.value

        XCTAssertEqual(revealed, 1)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(microphone.requestCount, 0)
        XCTAssertEqual(accessibility.promptCount, 0)
        XCTAssertEqual(inputMonitoring.requestCount, 0)
    }

    func testRequestingTheOpenRouterKeyRevealsTheInAppFieldAndPromptsNothing() async {
        openRouterKeyStore.stored = nil
        let controller = FirstRunController(
            keyStore: keyStore,
            openRouterKeyStore: openRouterKeyStore,
            microphone: microphone,
            accessibility: accessibility,
            inputMonitoring: inputMonitoring,
            requiresOpenRouterKey: { true },
            openSystemSettings: { [weak self] url in self?.openedURLs.append(url) })
        var revealed = 0
        controller.onRevealOpenRouterKeyField = { revealed += 1 }

        controller.request(.openRouterKey)
        await controller.inFlightRequest?.value

        XCTAssertEqual(revealed, 1)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(microphone.requestCount, 0)
        XCTAssertEqual(accessibility.promptCount, 0)
        XCTAssertEqual(inputMonitoring.requestCount, 0)
    }

    // MARK: dismissal

    func testTheChecklistIsDismissible() {
        keyStore.stored = nil
        let controller = makeController()
        XCTAssertFalse(controller.isDismissed)

        controller.dismiss()

        XCTAssertTrue(controller.isDismissed)
        // Dismissing hides the checklist; it does not pretend the prerequisite is met.
        XCTAssertTrue(controller.needsSetup)
    }

    func testReopeningClearsTheDismissal() {
        keyStore.stored = nil
        let controller = makeController()
        controller.dismiss()
        controller.reopen()
        XCTAssertFalse(controller.isDismissed)
    }

    /// Launch presentation is decided by `needsSetup` alone, per spec §10.6: the
    /// checklist stops appearing at launch once every row is satisfied.
    func testShouldPresentAtLaunchTracksNeedsSetup() {
        keyStore.stored = nil
        let controller = makeController()
        XCTAssertTrue(controller.shouldPresentAtLaunch)

        keyStore.stored = "gsk_ok"
        controller.refresh()
        XCTAssertFalse(controller.shouldPresentAtLaunch)
    }
}
