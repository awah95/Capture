import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Captur

private actor SettingsCorruptCleanup: ManagedLocalCleanup {
    private var corrupt = false
    func availability() -> LocalModelAvailability { .init(isDownloaded: true, updateAvailable: corrupt) }
    func prepare() throws { corrupt = true; throw LocalCleanupError.invalidDownload("Test") }
    func unload() {}
    func download(progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void) { corrupt = false }
    func removeModel() {}
    func clean(_ transcript: String) -> String { transcript }
    func clean(_ transcript: String, request: LocalCleanupRequest) -> String { transcript }
}

private actor SettingsDelayedAvailabilityCleanup: ManagedLocalCleanup {
    private var needsRepair = false
    private var reads = 0
    private var pending: CheckedContinuation<Void, Never>?
    let firstReadStarted: @Sendable () -> Void
    init(firstReadStarted: @escaping @Sendable () -> Void) { self.firstReadStarted = firstReadStarted }
    func availability() async -> LocalModelAvailability {
        let snapshot = LocalModelAvailability(isDownloaded: true, updateAvailable: needsRepair)
        reads += 1
        if reads == 1 {
            await withCheckedContinuation { pending = $0; firstReadStarted() }
        }
        return snapshot
    }
    func releaseFirstRead() { pending?.resume(); pending = nil }
    func prepare() throws { needsRepair = true; throw LocalCleanupError.invalidDownload("Test") }
    func unload() {}
    func download(progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void) { needsRepair = false }
    func removeModel() {}
    func clean(_ transcript: String) -> String { transcript }
    func clean(_ transcript: String, request: LocalCleanupRequest) -> String { transcript }
}

// MARK: - Test doubles
//
// The permission stubs and the recording key store live in `FirstRunControllerTests`
// and `GroqKeyFieldTests` and are reused here rather than cloned — Settings injects
// the *same* `FirstRunController` and `GroqKeyFieldModel` the checklist uses, and
// testing it against different doubles would be testing a different app.
//
// Only the hotkey manager is missing a double, because nothing before Settings ever
// needed to drive `suspend()`/`resume()`.

/// Controllable `HotkeyManaging`.
///
/// It records the suspend/resume balance *and* whether it was suspended at the moment
/// `apply` was called, because that is the trap: the real `HotkeyManager.apply` returns
/// early while suspended, so a recorder that applies before resuming can never learn
/// that Carbon refused the combo.
@MainActor
final class SettingsFakeHotkeyManager: HotkeyManaging {
    var onAction: ((HotkeyAction) -> Void)?

    private(set) var applied: [HotkeyBindings] = []
    private(set) var appliedWhileSuspended: [Bool] = []
    private(set) var suspendCount = 0
    private(set) var resumeCount = 0
    private(set) var captureActiveCalls: [Bool] = []

    /// A combo this fake refuses, exactly as Carbon refuses one another app owns.
    var refusedCombo: KeyCombo?
    /// A push-to-talk key this fake refuses.
    var refusedPushToTalk: PushToTalkBinding?
    /// `noErr` is 0; a real conflict reports a negative OSStatus.
    var refusalStatus: OSStatus = -9868

    /// The real manager's own definition: suspended until resumed, and both are
    /// idempotent.
    var isSuspended: Bool { suspendCount > resumeCount }

    func apply(_ bindings: HotkeyBindings) throws {
        appliedWhileSuspended.append(isSuspended)
        let combos = [bindings.toggleDictation, bindings.toggleThought, bindings.showHistoryPalette]
        if let refusedCombo, combos.contains(where: { $0 == refusedCombo }) {
            throw HotkeyError.registrationFailed(refusalStatus)
        }
        if let refusedPushToTalk, bindings.pushToTalk == refusedPushToTalk {
            throw HotkeyError.registrationFailed(refusalStatus)
        }
        applied.append(bindings)
    }

    func setCaptureActive(_ active: Bool) { captureActiveCalls.append(active) }
    func suspend() { suspendCount += 1 }
    func resume() { resumeCount += 1 }
    func registerTransient(_ combo: KeyCombo, action: HotkeyAction) throws {}
    func unregisterTransient(_ action: HotkeyAction) {}
}

private actor SettingsPreparationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

// MARK: - Tests

@MainActor
final class SettingsViewModelTests: XCTestCase {

    /// A key with an unmistakable shape, so a mirror of it anywhere in `UserDefaults`
    /// can be found by substring. It is never sent anywhere real.
    private let fakeKey = "gsk_TESTONLY_settings_0123456789"

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: AppSettings!
    private var hotkeys: SettingsFakeHotkeyManager!
    private var keyStore: RecordingGroqKeyStore!
    private var keyModel: GroqKeyFieldModel!
    private var permissionKeyStore: StubGroqKeyStore!
    private var microphone: StubMicrophonePermission!
    private var accessibility: StubAccessibility!
    private var inputMonitoring: StubInputMonitoringPermission!
    private var firstRun: FirstRunController!
    private var devices: [AudioInputDevice] = []
    private var records: [DictationRecord] = []
    private var recordsError: Error?
    private var hudResets = 0
    private var appliedAppearances: [AppAppearance] = []
    private var diagnosticsOpens = 0
    private var localPreparationCalls = 0
    private var localPreparationError: Error?
    private var localPreparationHook: (() async throws -> Void)?
    private var localAvailabilityByProvider: [TranscriptionProvider: LocalModelAvailability] = [:]
    private var removedLocalModels: [TranscriptionProvider] = []
    private var localModelEvents: [String] = []
    private var localRemovalError: Error?
    private var livePreparationCalls = 0
    private var livePreparationError: Error?

    // MARK: Task 27 — General and Privacy
    //
    // The login item goes through `FakeLoginItemService` (see `LoginItemTests`) and the
    // real `SystemLoginItemService` is constructed nowhere: a registration here would
    // write a login item into the owner's system and launch an unsigned debug build at
    // every login. The three Privacy closures are spies for the same reason — the real
    // ones delete the owner's audio.

    private var loginService: FakeLoginItemService!
    /// nil means "the orchestrator has not wired this yet", which the screen has to say
    /// out loud rather than pretend.
    private var sweeps = 0
    private var sweepError: Error?
    private var sweepIsWired = true
    private var deleteAllCalls = 0
    private var deleteAllError: Error?
    private var deleteAllIsWired = true
    private var diskUsageBytes = 0
    private var diskUsageError: Error?
    private var diskUsageIsWired = true
    private var diskUsageReads = 0

    /// Fixed so the month-boundary maths is not decided by the day the suite runs.
    private let now = Date(timeIntervalSince1970: 1_784_000_000)   // 2026-07-13 UTC

    override func setUp() {
        super.setUp()
        suiteName = "captur.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettings(defaults: defaults)
        hotkeys = SettingsFakeHotkeyManager()
        keyStore = RecordingGroqKeyStore()
        keyModel = GroqKeyFieldModel(store: keyStore, endpoint: nil)
        permissionKeyStore = StubGroqKeyStore(stored: "gsk_stored")
        microphone = StubMicrophonePermission(.granted)
        accessibility = StubAccessibility(trusted: true)
        inputMonitoring = StubInputMonitoringPermission(.granted)
        firstRun = FirstRunController(keyStore: permissionKeyStore,
                                      microphone: microphone,
                                      accessibility: accessibility,
                                      inputMonitoring: inputMonitoring,
                                      openSystemSettings: { _ in })
        devices = [builtIn, usb, iPhone]
        records = []
        recordsError = nil
        hudResets = 0
        appliedAppearances = []
        diagnosticsOpens = 0
        localPreparationCalls = 0
        localPreparationError = nil
        localPreparationHook = nil
        localAvailabilityByProvider = [:]
        removedLocalModels = []
        livePreparationCalls = 0
        livePreparationError = nil
        loginService = FakeLoginItemService()
        sweeps = 0
        sweepError = nil
        sweepIsWired = true
        deleteAllCalls = 0
        deleteAllError = nil
        deleteAllIsWired = true
        diskUsageBytes = 0
        diskUsageError = nil
        diskUsageIsWired = true
        diskUsageReads = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testChecksumFailureRefreshesRepairActionWhileSettingsIsOpen() async throws {
        let runtime = SettingsCorruptCleanup()
        let coordinator = LocalCleanupCoordinator(runtimes: [.localS1Mini: runtime, .localGemma: runtime])
        let model = makeModel(cleanupCoordinator: coordinator)
        await model.refreshCleanupModel(.localGemma)
        XCTAssertEqual(model.cleanupState(.localGemma), .ready(updateAvailable: false))
        let repairAvailable = expectation(description: "Settings offers Gemma repair")
        let subscription = model.$cleanupModelStates.sink {
            if $0[.localGemma] == .ready(updateAvailable: true) { repairAvailable.fulfill() }
        }
        let observation = Task { await model.observeCleanupMemory() }
        defer { observation.cancel(); subscription.cancel() }
        do { try await coordinator.prepare(.localGemma); XCTFail("Expected corrupt model") }
        catch LocalCleanupError.invalidDownload {}
        await fulfillment(of: [repairAvailable], timeout: 1)
        await coordinator.shutdown()
    }

    func testOlderAvailabilityReadCannotHideNewerRepairState() async throws {
        for choice in [ModeCleanupChoice.localS1Mini, .localGemma] {
            let started = expectation(description: "Initial availability read held")
            let runtime = SettingsDelayedAvailabilityCleanup(firstReadStarted: { started.fulfill() })
            let coordinator = LocalCleanupCoordinator(runtimes: [choice: runtime])
            let model = makeModel(cleanupCoordinator: coordinator)
            let staleRead = Task { await model.refreshCleanupModel(choice) }
            await fulfillment(of: [started], timeout: 1)
            do { try await coordinator.prepare(choice); XCTFail("Expected verification failure") }
            catch LocalCleanupError.invalidDownload {}
            await model.refreshCleanupModel(choice)
            XCTAssertEqual(model.cleanupState(choice), .ready(updateAvailable: true))
            await runtime.releaseFirstRead()
            await staleRead.value
            XCTAssertEqual(model.cleanupState(choice), .ready(updateAvailable: true),
                           "A stale read must not hide the repair/update action")
            await coordinator.shutdown()
        }
    }

    func testThirdModelUsesGenericSettingsDownloadRemoveLoadAndLateProgressGuard() async throws {
        let third = CleanupTestModels.third
        let runtime = RegistryTestRuntime()
        let coordinator = LocalCleanupCoordinator(registry: CleanupTestModels.registry, runtimes: [third.id: runtime])
        let model = makeModel(cleanupCoordinator: coordinator)
        XCTAssertEqual(model.cleanupModels.last?.id, third.id)
        await model.refreshCleanupModel(third.id)
        XCTAssertEqual(model.cleanupState(third.id), .notDownloaded)
        let downloaded = expectation(description: "Third model downloaded")
        let subscription = model.$cleanupModelStates.sink { state in
            if state[third.id] == .ready(updateAvailable: false) { downloaded.fulfill() }
        }
        model.downloadCleanupModel(third.id)
        await fulfillment(of: [downloaded], timeout: 1)
        subscription.cancel()
        // Progress queued by an old download must not replace the final state.
        await runtime.sendLateProgress()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.cleanupState(third.id), .ready(updateAvailable: false))
        model.loadCleanupModel(third.id)
        let deadline = Date().addingTimeInterval(1)
        while await coordinator.memoryState(third.id) != .ready, Date() < deadline { await Task.yield() }
        let memory = await coordinator.memoryState(third.id)
        XCTAssertEqual(memory, .ready)
        let removed = expectation(description: "Third model removed")
        let removal = model.$cleanupModelStates.sink { state in
            if state[third.id] == .notDownloaded { removed.fulfill() }
        }
        model.removeCleanupModel(third.id)
        await fulfillment(of: [removed], timeout: 1)
        removal.cancel()
        let count = await runtime.removed
        XCTAssertEqual(count, 1)
        await coordinator.shutdown()
    }

    func testThirdModelDownloadCancellationRecoversAndDoesNotChangeAnotherRow() async throws {
        let third = CleanupTestModels.third
        let runtime = RegistryTestRuntime()
        await runtime.holdNextDownload()
        let coordinator = LocalCleanupCoordinator(registry: CleanupTestModels.registry, runtimes: [third.id: runtime])
        let model = makeModel(cleanupCoordinator: coordinator)
        await model.refreshCleanupModel(third.id)
        model.downloadCleanupModel(third.id)
        let deadline = Date().addingTimeInterval(1)
        while !(await runtime.downloading), Date() < deadline { await Task.yield() }
        let downloading = await runtime.downloading
        XCTAssertTrue(downloading)
        let cancelled = expectation(description: "Cancellation restores download action")
        let subscription = model.$cleanupModelStates.sink { state in
            if state[third.id] == .notDownloaded { cancelled.fulfill() }
        }
        model.cancelCleanupDownload(third.id)
        await fulfillment(of: [cancelled], timeout: 1)
        subscription.cancel()
        await runtime.sendLateProgress()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.cleanupState(third.id), .notDownloaded)
        XCTAssertEqual(model.cleanupState(.localS1Mini), .checking)
        await coordinator.shutdown()
    }

    func testThirdModelFailedDownloadCanRetryThroughSameSettingsAction() async throws {
        let id = CleanupTestModels.third.id
        let runtime = RegistryTestRuntime()
        await runtime.failNextDownload()
        let coordinator = LocalCleanupCoordinator(registry: CleanupTestModels.registry, runtimes: [id: runtime])
        let model = makeModel(cleanupCoordinator: coordinator)
        let failed = expectation(description: "Download failure visible")
        let failure = model.$cleanupModelStates.sink { state in
            if case .failed = state[id] { failed.fulfill() }
        }
        model.downloadCleanupModel(id)
        await fulfillment(of: [failed], timeout: 1)
        failure.cancel()
        let downloaded = expectation(description: "Retry succeeds")
        let success = model.$cleanupModelStates.sink { state in
            if state[id] == .ready(updateAvailable: false) { downloaded.fulfill() }
        }
        model.downloadCleanupModel(id)
        await fulfillment(of: [downloaded], timeout: 1)
        success.cancel()
        await coordinator.shutdown()
    }

    // MARK: Fixtures

    private var builtIn: AudioInputDevice {
        AudioInputDevice(id: "uid-builtin", name: "MacBook Pro Microphone",
                         transport: .builtIn, isContinuityDevice: false)
    }

    private var usb: AudioInputDevice {
        AudioInputDevice(id: "uid-usb", name: "Shure MV7", transport: .usb, isContinuityDevice: false)
    }

    private var iPhone: AudioInputDevice {
        AudioInputDevice(id: "uid-iphone", name: "Avery's iPhone",
                         transport: .continuity, isContinuityDevice: true)
    }

    private func makeModel(cleanupCoordinator: LocalCleanupCoordinator? = nil) -> SettingsViewModel {
        SettingsViewModel(
            settings: settings,
            hotkeys: hotkeys,
            firstRun: firstRun,
            keyModel: keyModel,
            availableDevices: { [weak self] in self?.devices ?? [] },
            loadRecords: { [weak self] in
                if let error = self?.recordsError { throw error }
                return self?.records ?? []
            },
            resetHUDPosition: { [weak self] in self?.hudResets += 1 },
            applyAppearance: { [weak self] appearance in self?.appliedAppearances.append(appearance) },
            openDiagnostics: { [weak self] in self?.diagnosticsOpens += 1 },
            now: { [weak self] in self?.now ?? Date() },
            version: "0.9.0",
            build: "42",
            loginItem: LoginItem(service: loginService),
            cleanupCoordinator: cleanupCoordinator,
            prepareLocalModel: { [weak self] provider, _ in
                self?.localModelEvents.append("prepare:\(provider.rawValue)")
                self?.localPreparationCalls += 1
                if let error = self?.localPreparationError { throw error }
                if let hook = self?.localPreparationHook { try await hook() }
                self?.localAvailabilityByProvider[provider] = LocalModelAvailability(
                    isDownloaded: true, updateAvailable: false,
                    installedBytes: self?.localAvailabilityByProvider[provider]?.installedBytes)
            },
            localModelAvailability: { [weak self] provider in
                self?.localAvailabilityByProvider[provider]
                    ?? LocalModelAvailability(isDownloaded: false, updateAvailable: false)
            },
            removeLocalModel: { [weak self] provider in
                self?.localModelEvents.append("remove:\(provider.rawValue)")
                if let error = self?.localRemovalError { throw error }
                self?.removedLocalModels.append(provider)
                self?.localAvailabilityByProvider[provider] = LocalModelAvailability(
                    isDownloaded: false, updateAvailable: false)
            },
            prepareLiveTranscriptionModel: { [weak self] _, _ in
                self?.livePreparationCalls += 1
                if let error = self?.livePreparationError { throw error }
            },
            liveTranscriptionModelAvailability: { _ in
                LocalModelAvailability(isDownloaded: false, updateAvailable: false)
            },
            retentionSweep: sweepIsWired ? { [weak self] in
                self?.sweeps += 1
                if let error = self?.sweepError { throw error }
            } : nil,
            audioDiskUsage: diskUsageIsWired ? { [weak self] in
                self?.diskUsageReads += 1
                if let error = self?.diskUsageError { throw error }
                return self?.diskUsageBytes ?? 0
            } : nil,
            deleteAllAudio: deleteAllIsWired ? { [weak self] in
                self?.deleteAllCalls += 1
                if let error = self?.deleteAllError { throw error }
                self?.diskUsageBytes = 0
            } : nil)
    }

    /// Drains the view model's serialized Privacy work. The chain is one tail, the same
    /// idiom `AppComposition` uses for capture edges, so awaiting the last task awaits
    /// everything queued before it.
    private func drainPrivacyWork(_ model: SettingsViewModel) async {
        await model.privacyWork?.value
    }

    private func record(costUSD: Double, startedAt: Date) -> DictationRecord {
        DictationRecord(
            id: UUID(),
            startedAt: startedAt,
            speakingDuration: 10,
            rawText: "raw",
            finalText: "final",
            modeID: "verbatim",
            targetBundleID: nil,
            targetAppName: nil,
            wordCount: 1,
            rawWordCount: 1,
            segmentCount: 1,
            timings: Timings(captureMs: 1, convertMs: 1, uploadMs: 1,
                             whisperMs: 1, llmMs: 0, insertMs: 1, totalMs: 5),
            insertionOutcome: "insertedDirect",
            retryCount: 0,
            editDistanceRawToFinal: 0,
            audioFileName: nil,
            audioBytes: 0,
            estimatedCostUSD: costUSD,
            vocabularyTermsSent: 0,
            voiceProcessingActive: true,
            outcome: .inserted)
    }

    /// Every stored value in the suite, flattened to strings. Anything key-shaped that
    /// reached `UserDefaults` by any route shows up here.
    private func allStoredStrings() -> String {
        defaults.dictionaryRepresentation()
            .map { "\($0.key)=\(String(describing: $0.value))" }
            .joined(separator: "\n")
    }

    // MARK: - Groq key: Keychain only

    /// Spec §16: the key lives in the Keychain and nowhere else. Settings routes it
    /// through the existing `GroqKeyFieldModel` rather than owning a copy.
    func testGroqKeyGoesToTheStoreAndNeverToUserDefaults() {
        let model = makeModel()
        model.keyModel.draft = fakeKey
        model.saveGroqKey()

        XCTAssertEqual(keyStore.stored, fakeKey)
        XCTAssertEqual(keyStore.writes, [fakeKey])
        XCTAssertTrue(model.keyModel.hasStoredKey)
        // The field never reads a stored key back into view.
        XCTAssertEqual(model.keyModel.draft, "")

        let stored = allStoredStrings()
        XCTAssertFalse(stored.contains(fakeKey), "the key reached UserDefaults:\n\(stored)")
        XCTAssertFalse(stored.contains("gsk_"), "something key-shaped reached UserDefaults:\n\(stored)")
    }

    /// The same guarantee after every other setting has been written, so a mirror
    /// hidden behind an unrelated `didSet` is caught too.
    func testTouchingEverySettingStillLeavesNoKeyInUserDefaults() {
        let model = makeModel()
        model.keyModel.draft = fakeKey
        model.saveGroqKey()

        settings.appearance = .dark
        settings.voiceProcessing = false
        settings.transcriptionProvider = .localUnified
        settings.transcriptionModel = WhisperModel.large.rawValue
        settings.transcriptionLanguage = "en"
        settings.lowLatencySegmentation = false
        settings.micPolicy.preferredDeviceUIDs = ["uid-usb"]
        settings.hotkeyBindings = .default

        let stored = allStoredStrings()
        XCTAssertFalse(stored.contains(fakeKey), stored)
        XCTAssertFalse(stored.contains("gsk_"), stored)
    }

    // MARK: - Microphone priority

    func testPreferredRowsResolveNamesAndFlagAbsentDevices() {
        settings.micPolicy.preferredDeviceUIDs = ["uid-usb", "uid-gone"]
        let model = makeModel()
        model.refreshDevices()

        XCTAssertEqual(model.preferredMicrophones.map(\.uid), ["uid-usb", "uid-gone"])
        XCTAssertEqual(model.preferredMicrophones[0].name, "Shure MV7")
        XCTAssertTrue(model.preferredMicrophones[0].isConnected)
        XCTAssertFalse(model.preferredMicrophones[1].isConnected)
        XCTAssertFalse(model.preferredMicrophones[1].name.isEmpty)
    }

    /// Spec §4.2: the priority list is user-ordered and the first available device
    /// wins, so the order *is* the setting. It has to survive a relaunch.
    func testReorderingPreferredDevicesPersists() {
        settings.micPolicy.preferredDeviceUIDs = ["uid-builtin", "uid-usb", "uid-iphone"]
        let model = makeModel()

        model.movePreferredMicrophones(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(settings.micPolicy.preferredDeviceUIDs,
                       ["uid-iphone", "uid-builtin", "uid-usb"])

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.micPolicy.preferredDeviceUIDs,
                       ["uid-iphone", "uid-builtin", "uid-usb"])
    }

    func testMoveUpAndDownPersistAndClampAtTheEnds() {
        settings.micPolicy.preferredDeviceUIDs = ["a", "b", "c"]
        let model = makeModel()

        model.movePreferredMicrophone(uid: "c", by: -1)
        XCTAssertEqual(settings.micPolicy.preferredDeviceUIDs, ["a", "c", "b"])

        model.movePreferredMicrophone(uid: "a", by: -1)          // already first
        XCTAssertEqual(settings.micPolicy.preferredDeviceUIDs, ["a", "c", "b"])

        model.movePreferredMicrophone(uid: "b", by: 1)           // already last
        XCTAssertEqual(settings.micPolicy.preferredDeviceUIDs, ["a", "c", "b"])

        XCTAssertEqual(AppSettings(defaults: defaults).micPolicy.preferredDeviceUIDs,
                       ["a", "c", "b"])
    }

    func testAddingAndRemovingPreferredDevicesPersists() {
        let model = makeModel()
        model.refreshDevices()

        XCTAssertEqual(model.addableMicrophones.map(\.id), ["uid-builtin", "uid-usb", "uid-iphone"])

        model.addPreferredMicrophone("uid-usb")
        XCTAssertEqual(settings.micPolicy.preferredDeviceUIDs, ["uid-usb"])
        XCTAssertEqual(model.addableMicrophones.map(\.id), ["uid-builtin", "uid-iphone"])

        // Adding the same device twice must not duplicate a priority slot.
        model.addPreferredMicrophone("uid-usb")
        XCTAssertEqual(settings.micPolicy.preferredDeviceUIDs, ["uid-usb"])

        model.removePreferredMicrophone("uid-usb")
        XCTAssertEqual(settings.micPolicy.preferredDeviceUIDs, [])
        XCTAssertEqual(AppSettings(defaults: defaults).micPolicy.preferredDeviceUIDs, [])
    }

    func testContinuityAndVoiceProcessingTogglesPersist() {
        let model = makeModel()
        XCTAssertTrue(settings.micPolicy.excludeContinuityInputs)   // spec §4.2 default
        XCTAssertTrue(settings.voiceProcessing)                    // spec §4.3 default

        model.setExcludeContinuityInputs(false)
        model.setVoiceProcessing(false)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.micPolicy.excludeContinuityInputs)
        XCTAssertFalse(reloaded.voiceProcessing)
    }

    // MARK: - Permissions

    func testPermissionRowsReflectTheInjectedController() {
        microphone.current = .denied
        accessibility.trusted = false
        firstRun.refresh()

        let model = makeModel()
        XCTAssertEqual(model.permissions.map(\.id), firstRun.prerequisites.map(\.id))
        XCTAssertEqual(model.permissions.first { $0.id == .microphone }?.isSatisfied, false)
        XCTAssertEqual(model.permissions.first { $0.id == .accessibility }?.isSatisfied, false)
        XCTAssertEqual(model.permissions.first { $0.id == .inputMonitoring }?.isSatisfied, true)
    }

    /// No timer: a status that changes while nothing asks stays stale, and the only
    /// thing that moves it is an external `refreshPermissions()` — which the composition
    /// root already calls on `didBecomeActive`.
    func testPermissionRefreshIsExternallyDrivenNotPolled() async {
        let model = makeModel()
        XCTAssertEqual(model.permissions.first { $0.id == .microphone }?.isSatisfied, true)

        microphone.current = .denied
        // Give any hypothetical timer a generous window to fire.
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(model.permissions.first { $0.id == .microphone }?.isSatisfied, true,
                       "something is polling permission status behind the app's back")

        model.refreshPermissions()
        XCTAssertEqual(model.permissions.first { $0.id == .microphone }?.isSatisfied, false)
    }

    func testRequestingAPermissionGoesThroughTheInjectedController() async {
        microphone.current = .notDetermined
        firstRun.refresh()
        let model = makeModel()

        model.requestPermission(.microphone)
        await firstRun.inFlightRequest?.value

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertEqual(model.permissions.first { $0.id == .microphone }?.isSatisfied, true)
    }

    // MARK: - Shortcuts: the suspend/resume contract

    func testRecordingSuspendsTheHotkeyManager() {
        let model = makeModel()
        model.beginRecording(.toggleDictation)

        XCTAssertEqual(model.recordingSlot, .toggleDictation)
        XCTAssertTrue(hotkeys.isSuspended,
                      "⌥Space would start a dictation instead of being recorded")
    }

    func testCancellingRecordingResumes() {
        let model = makeModel()
        model.beginRecording(.toggleDictation)
        model.cancelRecording()

        XCTAssertNil(model.recordingSlot)
        XCTAssertFalse(hotkeys.isSuspended)
        XCTAssertEqual(settings.hotkeyBindings, .default, "cancel must not change a binding")
    }

    /// The window closing mid-recording is the route that turns a suspended manager
    /// into a dead app, because nothing else is left to press.
    func testWindowClosingMidRecordingResumes() {
        let model = makeModel()
        model.beginRecording(.toggleDictation)
        model.viewDidDisappear()

        XCTAssertNil(model.recordingSlot)
        XCTAssertFalse(hotkeys.isSuspended)
    }

    func testStartingASecondRecordingLeavesTheManagerBalanced() {
        let model = makeModel()
        model.beginRecording(.toggleDictation)
        model.beginRecording(.showHistoryPalette)
        model.cancelRecording()

        XCTAssertFalse(hotkeys.isSuspended)
        XCTAssertEqual(hotkeys.suspendCount, hotkeys.resumeCount,
                       "suspend/resume must balance however the rows are clicked")
    }

    func testCommittingACombinationPersistsResumesAndRegisters() {
        let model = makeModel()
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_D),
                             carbonModifiers: CarbonModifiers.command | CarbonModifiers.option)

        model.beginRecording(.toggleDictation)
        model.capture(combo, for: .toggleDictation)

        XCTAssertNil(model.recordingSlot)
        XCTAssertFalse(hotkeys.isSuspended)
        XCTAssertEqual(settings.hotkeyBindings.toggleDictation, combo)
        XCTAssertEqual(hotkeys.applied.last?.toggleDictation, combo)
        XCTAssertNil(model.shortcutError(for: .toggleDictation))
        XCTAssertEqual(AppSettings(defaults: defaults).hotkeyBindings.toggleDictation, combo)
    }

    /// The trap this test exists for: the real `HotkeyManager.apply` returns early
    /// while suspended, so applying before resuming can never surface a Carbon refusal.
    func testApplyHappensWhileTheManagerIsResumed() {
        let model = makeModel()
        model.beginRecording(.toggleDictation)
        model.capture(KeyCombo(keyCode: UInt32(kVK_ANSI_D),
                               carbonModifiers: CarbonModifiers.command),
                      for: .toggleDictation)

        XCTAssertFalse(hotkeys.appliedWhileSuspended.isEmpty)
        XCTAssertFalse(hotkeys.appliedWhileSuspended.contains(true),
                       "apply() was called while suspended — a refusal can never be seen")
    }

    /// Persist only what registered. A combo Carbon refuses is reported inline and the
    /// previous binding is put back, rather than saving something that will be dead
    /// after the next relaunch.
    func testARefusedComboRevertsPersistsNothingAndStillResumes() {
        let spotlight = KeyCombo(keyCode: UInt32(kVK_Space),
                                 carbonModifiers: CarbonModifiers.command)
        hotkeys.refusedCombo = spotlight
        let model = makeModel()
        let previous = settings.hotkeyBindings.toggleDictation

        model.beginRecording(.toggleDictation)
        model.capture(spotlight, for: .toggleDictation)

        XCTAssertEqual(settings.hotkeyBindings.toggleDictation, previous, "a refused combo was persisted")
        XCTAssertEqual(AppSettings(defaults: defaults).hotkeyBindings.toggleDictation, previous)
        XCTAssertFalse(hotkeys.isSuspended)
        XCTAssertNil(model.recordingSlot)

        let message = model.shortcutError(for: .toggleDictation)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("⌘Space") == true,
                      "the message should name the combo: \(message ?? "nil")")

        // And the manager was handed the previous bindings back, so what is registered
        // matches what is stored.
        XCTAssertEqual(hotkeys.applied.last?.toggleDictation, previous)
    }

    func testARejectedKeystrokeReportsTheReasonAndKeepsRecording() {
        let model = makeModel()
        model.beginRecording(.toggleDictation)
        model.rejectCapture("Use at least one modifier.", for: .toggleDictation)

        XCTAssertEqual(model.recordingSlot, .toggleDictation, "a bad keystroke should not end recording")
        XCTAssertTrue(hotkeys.isSuspended)
        XCTAssertEqual(model.shortcutError(for: .toggleDictation), "Use at least one modifier.")
        XCTAssertEqual(settings.hotkeyBindings, .default)

        model.cancelRecording()
        XCTAssertFalse(hotkeys.isSuspended)
    }

    func testRestoreDefaultsAppliesAndPersistsTheShippedBindings() {
        settings.hotkeyBindings = HotkeyBindings(
            pushToTalk: .disabled, toggleDictation: nil,
            toggleThought: nil, showHistoryPalette: nil)
        let model = makeModel()

        model.restoreShortcutDefaults()

        XCTAssertEqual(settings.hotkeyBindings, .default)
        XCTAssertEqual(AppSettings(defaults: defaults).hotkeyBindings, .default)
        XCTAssertEqual(hotkeys.applied.last?.toggleDictation, HotkeyBindings.default.toggleDictation)
        XCTAssertNil(model.shortcutError(for: .toggleDictation))
    }

    func testPushToTalkChangePersists() {
        let model = makeModel()
        model.setPushToTalk(.fnGlobe)

        XCTAssertEqual(settings.hotkeyBindings.pushToTalk, .modifier(.fnGlobe))
        XCTAssertEqual(AppSettings(defaults: defaults).hotkeyBindings.pushToTalk,
                       .modifier(.fnGlobe))
        XCTAssertEqual(hotkeys.applied.last?.pushToTalk, .modifier(.fnGlobe))
    }

    func testARefusedPushToTalkKeyRevertsAndReports() {
        hotkeys.refusedPushToTalk = .modifier(.rightCommand)
        let model = makeModel()

        model.setPushToTalk(.rightCommand)

        XCTAssertEqual(settings.hotkeyBindings.pushToTalk, .modifier(.rightOption))
        XCTAssertNotNil(model.pushToTalkError)
        XCTAssertEqual(hotkeys.applied.last?.pushToTalk, .modifier(.rightOption))
    }

    func testClearingABindingPersistsNil() {
        let model = makeModel()
        model.clearBinding(.toggleDictation)

        XCTAssertNil(settings.hotkeyBindings.toggleDictation)
        XCTAssertNil(AppSettings(defaults: defaults).hotkeyBindings.toggleDictation)
    }

    /// Thought capture stays parked, while History now opens the real main-window pane.
    func testOnlyParkedShortcutRowsAreDisabledWithAVisibleReason() {
        let model = makeModel()

        XCTAssertTrue(model.isEditable(.toggleDictation))
        XCTAssertNil(model.disabledReason(for: .toggleDictation))

        XCTAssertFalse(FeatureFlags.thoughtCapture, "this test encodes the parked state")
        XCTAssertFalse(model.isEditable(.toggleThought))
        XCTAssertFalse(model.disabledReason(for: .toggleThought)?.isEmpty ?? true)

        XCTAssertTrue(model.isEditable(.showHistoryPalette))
        XCTAssertNil(model.disabledReason(for: .showHistoryPalette))
    }

    /// A disabled row must not be recordable by any route, or the reason on screen is
    /// decoration.
    func testADisabledSlotCannotBeRecorded() {
        let model = makeModel()
        model.beginRecording(.toggleThought)

        XCTAssertNil(model.recordingSlot)
        XCTAssertFalse(hotkeys.isSuspended)
        XCTAssertEqual(hotkeys.suspendCount, 0)
    }

    /// Settings must apply the same feature gating `AppComposition` does, or opening
    /// Settings would silently register a parked binding the launch path deliberately
    /// dropped.
    func testAppliedBindingsDropTheParkedThoughtBinding() {
        let model = makeModel()
        model.setPushToTalk(.rightCommand)

        XCTAssertNil(hotkeys.applied.last?.toggleThought)
        XCTAssertNotNil(settings.hotkeyBindings.toggleThought,
                        "the stored binding is kept; only what is registered is gated")
    }

    // MARK: - Transcription

    func testTranscriptionSettingsPersist() {
        let model = makeModel()
        XCTAssertEqual(settings.transcriptionModel, GroqClient.defaultModel)
        XCTAssertTrue(settings.lowLatencySegmentation)
        XCTAssertTrue(settings.retranscribeFinalWithBatch)

        model.setTranscriptionModel(.large)
        model.setTranscriptionLanguage("de")
        model.setLowLatencySegmentation(false)
        model.setRetranscribeFinalWithBatch(false)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.transcriptionModel, "whisper-large-v3")
        XCTAssertEqual(reloaded.transcriptionLanguage, "de")
        XCTAssertFalse(reloaded.lowLatencySegmentation)
        XCTAssertFalse(reloaded.retranscribeFinalWithBatch)
    }

    func testLiveTranscriptionPreferencesArePerModelAndPersist() {
        XCTAssertTrue(settings.liveTranscriptionEnabled(for: .localMoonshine),
                      "Moonshine preserves its streaming-first default")
        XCTAssertFalse(settings.liveTranscriptionEnabled(for: .localUnified),
                       "Unified remains batch until its extra model is requested")
        XCTAssertFalse(settings.liveTranscriptionEnabled(for: .groq))

        settings.setLiveTranscriptionEnabled(false, for: .localMoonshine)
        settings.setLiveTranscriptionEnabled(true, for: .localUnified)
        settings.setLiveTranscriptionEnabled(true, for: .groq)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.liveTranscriptionEnabled(for: .localMoonshine))
        XCTAssertTrue(reloaded.liveTranscriptionEnabled(for: .localUnified))
        XCTAssertFalse(reloaded.liveTranscriptionEnabled(for: .groq))
    }

    func testEnablingUnifiedLiveTranscriptionPreparesItsAdditionalArtifact() async {
        let model = makeModel()
        model.setUseLocalTranscription(true)
        await model.localTranscriptionPreparation?.value

        model.setLiveTranscriptionEnabled(true)
        await model.liveTranscriptionPreparation?.value

        XCTAssertEqual(livePreparationCalls, 1)
        XCTAssertTrue(settings.liveTranscriptionEnabled(for: .localUnified))
        XCTAssertEqual(
            model.liveTranscriptionModelState(.localUnified),
            .ready(updateAvailable: false))
    }

    func testDownloadedUnifiedLiveArtifactCanBeUpdated() async {
        let model = makeModel()
        model.setUseLocalTranscription(true)
        await model.localTranscriptionPreparation?.value
        model.setLiveTranscriptionEnabled(true)
        await model.liveTranscriptionPreparation?.value

        model.updateLiveTranscriptionModel(.localUnified)
        await model.localTranscriptionPreparation?.value
        XCTAssertEqual(removedLocalModels, [.localUnified])

        XCTAssertEqual(livePreparationCalls, 2)
        XCTAssertEqual(
            model.liveTranscriptionModelState(.localUnified),
            .ready(updateAvailable: false))
    }

    func testExplicitLiveUpgradeInstallsStreamingWithoutEnablingIt() async {
        settings.transcriptionProvider = .localUnified
        settings.setLiveTranscriptionEnabled(false, for: .localUnified)
        let model = makeModel()

        model.updateLiveTranscriptionModel(.localUnified)
        await model.localTranscriptionPreparation?.value

        XCTAssertEqual(localModelEvents, ["remove:localUnified", "prepare:localUnified"])
        XCTAssertEqual(livePreparationCalls, 1)
        XCTAssertEqual(model.liveTranscriptionModelState(.localUnified), .ready(updateAvailable: false))
        XCTAssertEqual(settings.transcriptionProvider, .localUnified)
        XCTAssertFalse(settings.liveTranscriptionEnabled(for: .localUnified))
        XCTAssertFalse(AppSettings(defaults: defaults).liveTranscriptionEnabled(for: .localUnified))
    }

    func testRetryRetainsExplicitLiveUpgradeIntentWithToggleOff() async {
        settings.transcriptionProvider = .localUnified
        settings.setLiveTranscriptionEnabled(false, for: .localUnified)
        livePreparationError = FakeFailure.boom("streaming download failed")
        let model = makeModel()
        model.updateLiveTranscriptionModel(.localUnified)
        await model.localTranscriptionPreparation?.value
        guard case .failed = model.localModelState(.localUnified) else {
            return XCTFail("Expected a retryable live download failure")
        }

        livePreparationError = nil
        model.downloadLocalModel(.localUnified)
        await model.localTranscriptionPreparation?.value

        XCTAssertEqual(livePreparationCalls, 2)
        XCTAssertEqual(model.liveTranscriptionModelState(.localUnified), .ready(updateAvailable: false))
        XCTAssertFalse(settings.liveTranscriptionEnabled(for: .localUnified))
    }

    func testFailedUnifiedLiveDownloadTurnsThePreferenceBackOff() async {
        livePreparationError = FakeFailure.boom("streaming download failed")
        let model = makeModel()
        model.setUseLocalTranscription(true)
        await model.localTranscriptionPreparation?.value

        model.setLiveTranscriptionEnabled(true)
        await model.liveTranscriptionPreparation?.value

        XCTAssertFalse(settings.liveTranscriptionEnabled(for: .localUnified))
        guard case .failed(let message) =
            model.liveTranscriptionModelState(.localUnified) else {
            return XCTFail("expected the streaming preparation error")
        }
        XCTAssertTrue(message.contains("streaming download failed"))
    }

    func testLocalTranscriptionIsOptInAndPersistsAfterPreparation() async {
        let model = makeModel()
        XCTAssertEqual(settings.transcriptionProvider, .groq)

        model.setUseLocalTranscription(true)
        await model.localTranscriptionPreparation?.value

        XCTAssertEqual(localPreparationCalls, 1)
        XCTAssertEqual(settings.transcriptionProvider, .localUnified)
        XCTAssertEqual(AppSettings(defaults: defaults).transcriptionProvider, .localUnified)
        XCTAssertEqual(model.localTranscriptionState, .ready)
    }

    func testDownloadedLocalModelCanBeUpdated() async {
        let model = makeModel()
        model.setUseLocalTranscription(true)
        await model.localTranscriptionPreparation?.value

        model.downloadLocalModel(.localUnified)
        await model.localTranscriptionPreparation?.value

        XCTAssertEqual(localPreparationCalls, 2)
        XCTAssertEqual(model.localModelState(.localUnified), .ready(updateAvailable: false))
    }

    func testUpgradeReplacesBatchThenRestoresLiveWithoutChangingSelection() async {
        settings.transcriptionProvider = .localUnified
        settings.setLiveTranscriptionEnabled(true, for: .localUnified)
        let model = makeModel()
        model.upgradeLocalModel(.localUnified)
        await model.localTranscriptionPreparation?.value
        XCTAssertEqual(localModelEvents, ["remove:localUnified", "prepare:localUnified"])
        XCTAssertEqual(livePreparationCalls, 1)
        XCTAssertEqual(settings.transcriptionProvider, .localUnified)
        XCTAssertTrue(settings.liveTranscriptionEnabled(for: .localUnified))
        XCTAssertEqual(model.liveTranscriptionModelState(.localUnified), .ready(updateAvailable: false))
    }

    func testUpgradeStopsIfRemovingOldModelFails() async {
        settings.transcriptionProvider = .localUnified
        localRemovalError = LocalModelBusyError()
        let model = makeModel()
        model.upgradeLocalModel(.localUnified)
        await model.localTranscriptionPreparation?.value
        XCTAssertEqual(localPreparationCalls, 0)
        XCTAssertEqual(settings.transcriptionProvider, .localUnified)
        XCTAssertTrue(removedLocalModels.isEmpty)
    }

    func testFailedUpgradeCanRetryReplacement() async {
        settings.transcriptionProvider = .localUnified
        localPreparationError = NSError(domain: "download", code: 1)
        let model = makeModel()
        model.upgradeLocalModel(.localUnified)
        await model.localTranscriptionPreparation?.value
        guard case .failed = model.localModelState(.localUnified) else {
            return XCTFail("Download failure must remain retryable")
        }
        localPreparationError = nil
        model.downloadLocalModel(.localUnified)
        await model.localTranscriptionPreparation?.value
        XCTAssertEqual(localModelEvents, ["remove:localUnified", "prepare:localUnified",
                                         "remove:localUnified", "prepare:localUnified"])
        XCTAssertEqual(model.localModelState(.localUnified), .ready(updateAvailable: false))
    }

    func testUltraSelectionPersistsAndDoesNotPrepareALiveModel() async {
        let model = makeModel()
        model.selectLocalModel(.localUltra)
        await model.localTranscriptionPreparation?.value
        XCTAssertEqual(settings.transcriptionProvider, .localUltra)
        XCTAssertEqual(AppSettings(defaults: defaults).transcriptionProvider, .localUltra)
        XCTAssertEqual(localModelEvents, ["prepare:localUltra"])
        model.setLiveTranscriptionEnabled(true)
        XCTAssertFalse(settings.liveTranscriptionEnabled(for: .localUltra))
        XCTAssertEqual(livePreparationCalls, 0)
    }

    func testRemovingLocalModelClearsItsMeasuredInstalledSize() async throws {
        localAvailabilityByProvider[.localUnified] = LocalModelAvailability(
            isDownloaded: true,
            updateAvailable: false,
            installedBytes: 1_500_000)
        let model = makeModel()
        model.viewDidAppear()
        for _ in 0..<100 where model.localModelInstalledBytes[.localUnified] == nil {
            await Task.yield()
        }
        XCTAssertEqual(model.localModelInstalledBytes[.localUnified], 1_500_000)

        model.removeLocalModel(.localUnified)
        for _ in 0..<100 where model.localModelState(.localUnified) != .notDownloaded {
            await Task.yield()
        }

        let descriptor = try XCTUnwrap(
            LocalModelDescriptor.all.first { $0.provider == .localUnified })
        XCTAssertEqual(removedLocalModels, [.localUnified])
        XCTAssertNil(model.localModelInstalledBytes[.localUnified])
        XCTAssertEqual(model.localModelSize(descriptor), descriptor.size)
    }

    func testFailedLocalPreparationFallsBackToGroqAndExplainsIt() async {
        localPreparationError = FakeFailure.boom("download failed")
        let model = makeModel()

        model.setUseLocalTranscription(true)
        await model.localTranscriptionPreparation?.value

        XCTAssertEqual(settings.transcriptionProvider, .groq)
        guard case .failed(let message) = model.localTranscriptionState else {
            return XCTFail("expected failed state, got \(model.localTranscriptionState)")
        }
        XCTAssertTrue(message.contains("download failed"))
        XCTAssertTrue(message.contains("Groq"))
    }

    func testDisablingLocalTranscriptionSelectsGroqWithoutDiscardingReadiness() async {
        let model = makeModel()
        model.setUseLocalTranscription(true)
        await model.localTranscriptionPreparation?.value

        model.setUseLocalTranscription(false)

        XCTAssertEqual(settings.transcriptionProvider, .groq)
        XCTAssertEqual(model.localTranscriptionState, .ready)
    }

    func testDisablingLocalTranscriptionLetsAnInFlightDownloadFinish() async {
        let gate = SettingsPreparationGate()
        let started = expectation(description: "local preparation started")
        localPreparationHook = {
            started.fulfill()
            await gate.wait()
        }
        let model = makeModel()

        model.setUseLocalTranscription(true)
        await fulfillment(of: [started], timeout: 1)
        model.setUseLocalTranscription(false)
        model.setUseLocalTranscription(true)

        XCTAssertEqual(localPreparationCalls, 1, "re-enabling must reattach to the same download")
        await gate.open()
        await model.localTranscriptionPreparation?.value

        XCTAssertEqual(model.localModelState(.localUnified), .ready(updateAvailable: false))
        XCTAssertEqual(model.localTranscriptionState, .ready)
    }

    func testMoonshineCanBeSelectedAndPersistsAsTheLocalProvider() async {
        let model = makeModel()

        model.setUseLocalTranscription(true)
        await model.localTranscriptionPreparation?.value
        model.selectLocalModel(.localMoonshine)
        await model.localTranscriptionPreparation?.value

        XCTAssertEqual(settings.transcriptionProvider, .localMoonshine)
        XCTAssertEqual(AppSettings(defaults: defaults).transcriptionProvider, .localMoonshine)
        XCTAssertEqual(model.localModelState(.localMoonshine), .ready(updateAvailable: false))
    }

    func testTheDefaultModelIsTheOneTheClientActuallyUses() {
        XCTAssertEqual(WhisperModel.turbo.rawValue, GroqClient.defaultModel)
        XCTAssertEqual(AppSettings(defaults: defaults).transcriptionModel, GroqClient.defaultModel)
    }

    /// These four settings persist but the pipeline does not read them yet. While that
    /// is true the section says so; the flag is what the wiring commit flips.
    func testTheUnwiredNoticeTracksTheWiringFlag() {
        let model = makeModel()
        if SettingsViewModel.pipelineReadsCaptureSettings {
            XCTAssertNil(model.unwiredNotice)
        } else {
            XCTAssertFalse(model.unwiredNotice?.isEmpty ?? true,
                           "an unwired control must say so on screen")
        }
    }

    // MARK: - About: real spend or none

    func testSpendCountsOnlyThisMonthsRecords() async {
        records = [
            record(costUSD: 0.10, startedAt: now),
            record(costUSD: 0.05, startedAt: now.addingTimeInterval(-86_400)),
            record(costUSD: 9.99, startedAt: now.addingTimeInterval(-45 * 86_400))
        ]
        let model = makeModel()
        await model.loadSpend()

        guard case .amount(let usd, let dictations) = model.spend else {
            return XCTFail("expected an amount, got \(model.spend)")
        }
        XCTAssertEqual(usd, 0.15, accuracy: 0.000_001)
        XCTAssertEqual(dictations, 2)
    }

    func testSpendReportsRequestsWhoseCostIsUnknown() async {
        var current = record(costUSD: 0, startedAt: now)
        current.usageEntries = [
            DictationUsageEntry(
                stage: .refinement,
                providerID: RefinementProviderID.groq.rawValue,
                requestedModelID: "openai/gpt-oss-20b",
                actualModelID: "openai/gpt-oss-20b",
                promptTokens: 12,
                completionTokens: 4,
                reasoningTokens: nil,
                cachedTokens: nil,
                costUSD: nil,
                costKind: .unknown,
                generationID: nil)
        ]
        records = [current]
        let model = makeModel()

        await model.loadSpend()

        XCTAssertEqual(model.spend, .amount(usd: 0, dictations: 1))
        XCTAssertEqual(model.spendUnknownCostCount, 1)
    }

    func testLocalModelUsageSeparatesUniqueAndProcessedAudio() async {
        var current = record(costUSD: 0, startedAt: now)
        current.speakingDuration = 10
        current.usageEntries = [
            DictationUsageEntry(
                stage: .transcription,
                providerID: TranscriptionProvider.localUnified.rawValue,
                requestedModelID: "parakeet-live",
                actualModelID: "parakeet-live",
                promptTokens: nil, completionTokens: nil, reasoningTokens: nil,
                cachedTokens: nil, costUSD: .zero, costKind: .noCharge,
                generationID: nil, audioSeconds: 10,
                transcriptionPath: .liveStream, isRetry: false,
                outcome: .succeeded),
            DictationUsageEntry(
                stage: .transcription,
                providerID: TranscriptionProvider.localUnified.rawValue,
                requestedModelID: "parakeet-batch",
                actualModelID: "parakeet-batch",
                promptTokens: nil, completionTokens: nil, reasoningTokens: nil,
                cachedTokens: nil, costUSD: .zero, costKind: .noCharge,
                generationID: nil, audioSeconds: 10, outputWordCount: 4,
                latencyMs: 110, transcriptionPath: .finalBatchRecheck,
                isRetry: false, outcome: .succeeded),
        ]
        records = [current]
        let model = makeModel()

        await model.loadUsageStats()

        let usage = model.localModelUsage(for: .localUnified)
        XCTAssertTrue(model.localModelUsageAvailable)
        XCTAssertEqual(usage.dictationCount, 1)
        XCTAssertEqual(usage.uniqueAudioSeconds, 10, accuracy: 0.0001)
        XCTAssertEqual(usage.processedAudioSeconds, 20, accuracy: 0.0001)
        XCTAssertEqual(usage.outputWordCount, 4)
        XCTAssertEqual(usage.latencyP50Ms, 110)
    }

    func testLegacyRefinementReceiptWithoutTranscriptionRemainsUnattributed() async {
        var current = record(costUSD: 0.001, startedAt: now)
        current.usageEntries = [
            DictationUsageEntry(
                stage: .refinement,
                providerID: RefinementProviderID.openRouter.rawValue,
                requestedModelID: "test-model",
                actualModelID: "test-model",
                promptTokens: 8, completionTokens: 2, reasoningTokens: nil,
                cachedTokens: nil, costUSD: Decimal(string: "0.001"),
                costKind: .billed, generationID: "generation")
        ]
        records = [current]
        let model = makeModel()

        await model.loadUsageStats()

        XCTAssertEqual(model.unattributedLegacyDictationCount, 1)
        XCTAssertEqual(model.unattributedLegacyWords, 1)
        XCTAssertEqual(model.unattributedLegacyAudioSeconds, 10)
    }

    func testSpendIsZeroWhenNothingWasSaidThisMonth() async {
        records = [record(costUSD: 9.99, startedAt: now.addingTimeInterval(-45 * 86_400))]
        let model = makeModel()
        await model.loadSpend()

        XCTAssertEqual(model.spend, .amount(usd: 0, dictations: 0))
    }

    /// Never invent a number: if the log cannot be read, the row says so.
    func testSpendIsUnavailableWhenTheLogCannotBeRead() async {
        recordsError = FakeFailure.boom("no log")
        let model = makeModel()
        await model.loadSpend()

        guard case .unavailable(let reason) = model.spend else {
            return XCTFail("expected .unavailable, got \(model.spend)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testVersionAndBuildComeFromTheInjectedBundleValues() {
        let model = makeModel()
        XCTAssertEqual(model.version, "0.9.0")
        XCTAssertEqual(model.build, "42")
    }

    // MARK: - General

    func testResettingTheHUDPositionGoesThroughTheInjectedClosure() {
        let model = makeModel()
        model.resetHUDPosition()
        XCTAssertEqual(hudResets, 1)
    }

    func testAppearanceChangePersistsAndIsApplied() {
        let model = makeModel()
        XCTAssertEqual(settings.appearance, .system)

        model.setAppearance(.dark)

        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(AppSettings(defaults: defaults).appearance, .dark)
        XCTAssertEqual(appliedAppearances, [.dark])
    }

    func testDiagnosticsButtonCallsTheInjectedClosure() {
        let model = makeModel()
        model.openDiagnostics()
        XCTAssertEqual(diagnosticsOpens, 1)
    }

    // MARK: - General: launch at login (Task 27)

    func testLaunchAtLoginReflectsTheServiceAndTogglesThroughIt() {
        loginService.reported = .notRegistered
        let model = makeModel()
        XCTAssertFalse(model.launchAtLogin.isOn)

        model.setLaunchAtLogin(true)

        XCTAssertEqual(loginService.registerCount, 1)
        XCTAssertTrue(model.launchAtLogin.isOn)
        XCTAssertNil(model.launchAtLogin.advice)
    }

    /// `.requiresApproval` is the case a plain toggle gets wrong: it flips on, then flips
    /// back on the next visit with nothing said. The screen shows the reason and a way
    /// to fix it instead.
    func testLaunchAtLoginSurfacesTheApprovalStateRatherThanFlippingBack() {
        loginService.statusAfterRegister = .requiresApproval
        let model = makeModel()

        model.setLaunchAtLogin(true)

        XCTAssertFalse(model.launchAtLogin.isOn)
        XCTAssertTrue(model.launchAtLogin.needsApproval)
        XCTAssertFalse(model.launchAtLogin.advice?.isEmpty ?? true)

        model.openLoginItemsSettings()
        XCTAssertEqual(loginService.openSystemSettingsCount, 1)
    }

    func testLaunchAtLoginReportsAFailedRegistration() {
        loginService.registerError = FakeFailure.boom("no bundle")
        let model = makeModel()

        model.setLaunchAtLogin(true)

        XCTAssertFalse(model.launchAtLogin.isOn)
        XCTAssertFalse(model.launchAtLogin.advice?.isEmpty ?? true)
    }

    /// The status can change while Captur is in the background — the user visiting
    /// System Settings → Login Items is the normal case — so the window re-reads it on
    /// open. Nothing polls.
    func testOpeningTheWindowReReadsTheLoginItemStatus() {
        let model = makeModel()
        XCTAssertFalse(model.launchAtLogin.isOn)

        loginService.reported = .enabled
        model.viewDidAppear()

        XCTAssertTrue(model.launchAtLogin.isOn)
    }

    // MARK: - General: media pause and sounds (Task 27)

    /// The AEC decision, pinned. Echo cancellation is the product's differentiator —
    /// dictating cleanly *while* music plays (spec §4.3, LV2) — so pausing the music is
    /// opt-in. On by default it would quietly make the headline feature untestable.
    func testMediaPauseAndSoundsAreOffByDefault() {
        XCTAssertFalse(settings.pauseMediaDuringRecording)
        XCTAssertFalse(settings.soundFeedback)
        XCTAssertTrue(settings.voiceProcessing, "AEC stays on by default; the pause does not")
    }

    func testMediaPauseAndSoundSettingsPersist() {
        let model = makeModel()

        model.setPauseMediaDuringRecording(true)
        model.setSoundFeedback(true)
        model.setSoundFeedbackVolume(0.8)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.pauseMediaDuringRecording)
        XCTAssertTrue(reloaded.soundFeedback)
        XCTAssertEqual(reloaded.soundFeedbackVolume, 0.8, accuracy: 0.000_001)
    }

    /// A stored volume outside 0…1 must never reach `NSSound`, and the persisted value
    /// is the one clamped — otherwise the slider and the sound disagree.
    func testSoundVolumeIsClampedOnTheWayIn() {
        let model = makeModel()

        model.setSoundFeedbackVolume(9)
        XCTAssertEqual(settings.soundFeedbackVolume, 1.0, accuracy: 0.000_001)

        model.setSoundFeedbackVolume(-3)
        XCTAssertEqual(settings.soundFeedbackVolume, 0.0, accuracy: 0.000_001)
    }

    /// Both settings persist here but nothing consumes them until `AppComposition`
    /// connects the capture edges, so the section says so — the same honesty rule the
    /// capture settings already follow.
    func testTheGeneralUnwiredNoticeTracksTheWiringFlag() {
        let model = makeModel()
        if SettingsViewModel.captureEdgesDriveMediaAndSounds {
            XCTAssertNil(model.mediaAndSoundNotice)
        } else {
            XCTAssertFalse(model.mediaAndSoundNotice?.isEmpty ?? true,
                           "an unwired control must say so on screen")
        }
    }

    // MARK: - Privacy: retention (spec §16)

    func testTheRetentionPickerOffersEveryPolicyWithAName() {
        XCTAssertEqual(RetentionPolicy.allCases.count, 5)
        for policy in RetentionPolicy.allCases {
            XCTAssertFalse(policy.displayName.isEmpty, "\(policy) has no name for the picker")
        }
        XCTAssertEqual(settings.retentionPolicy, .thirtyDays, "spec §16 default")
    }

    /// The plan's own Task 25 assertion, finally writable: a retention change is not a
    /// preference that waits for tomorrow, it is an instruction to purge now.
    func testChangingTheRetentionPolicyPersistsAndSweepsExactlyOnce() async {
        let model = makeModel()

        model.setRetentionPolicy(.sevenDays)
        await drainPrivacyWork(model)

        XCTAssertEqual(settings.retentionPolicy, .sevenDays)
        XCTAssertEqual(AppSettings(defaults: defaults).retentionPolicy, .sevenDays)
        XCTAssertEqual(sweeps, 1)
        XCTAssertNil(model.privacyError)
    }

    func testSelectingTheSamePolicyDoesNotSweep() async {
        let model = makeModel()

        model.setRetentionPolicy(.thirtyDays)      // already the default
        await drainPrivacyWork(model)

        XCTAssertEqual(sweeps, 0, "SwiftUI re-sets a binding to its current value freely")
    }

    /// A sweep that fails is the user's data not being deleted when they asked. It
    /// surfaces; the choice itself still stands, because the daily sweep re-reads it.
    func testAFailedSweepSurfacesAndStillKeepsTheChosenPolicy() async {
        sweepError = FakeFailure.boom("log is locked")
        let model = makeModel()

        model.setRetentionPolicy(.never)
        await drainPrivacyWork(model)

        XCTAssertEqual(settings.retentionPolicy, .never)
        XCTAssertFalse(model.privacyError?.isEmpty ?? true, "a failed purge was swallowed")
    }

    func testAnUnwiredSweepIsAdmittedRatherThanFakedAndTheChoiceStillPersists() async {
        sweepIsWired = false
        let model = makeModel()

        model.setRetentionPolicy(.ninetyDays)
        await drainPrivacyWork(model)

        XCTAssertEqual(settings.retentionPolicy, .ninetyDays)
        XCTAssertFalse(model.retentionNotice?.isEmpty ?? true,
                       "if the change cannot purge now, the screen must say when it will")
    }

    // MARK: - Privacy: disk usage

    func testDiskUsageIsReadOnceWhenTheWindowOpens() async {
        diskUsageBytes = 4_200_000
        let model = makeModel()
        XCTAssertEqual(model.audioDiskUsage, .loading)

        model.viewDidAppear()
        await drainPrivacyWork(model)

        XCTAssertEqual(model.audioDiskUsage, .bytes(4_200_000))
        XCTAssertEqual(diskUsageReads, 1, "the readout must not poll")
    }

    /// The rule this whole readout exists for: an unreadable log is *unknown*, and
    /// "0 bytes" next to a Delete-all button is a claim, and the wrong one.
    func testAnUnreadableLogReportsUnknownAndNeverZero() async {
        diskUsageError = FakeFailure.boom("no log")
        let model = makeModel()

        model.loadAudioDiskUsage()
        await drainPrivacyWork(model)

        guard case .unavailable(let reason) = model.audioDiskUsage else {
            return XCTFail("expected .unavailable, got \(model.audioDiskUsage)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNotEqual(model.audioDiskUsage, .bytes(0))
        XCTAssertFalse(model.audioDiskUsageText.contains("0 bytes"),
                       "unknown was rendered as zero: \(model.audioDiskUsageText)")
    }

    func testAnUnwiredDiskUsageReadoutSaysSoInsteadOfShowingZero() async {
        diskUsageIsWired = false
        let model = makeModel()

        model.loadAudioDiskUsage()
        await drainPrivacyWork(model)

        guard case .unavailable = model.audioDiskUsage else {
            return XCTFail("expected .unavailable, got \(model.audioDiskUsage)")
        }
    }

    /// Bytes are what the sweeper counts; MB is what a human reads. Decimal units, the
    /// way Finder has reported sizes since 10.6.
    func testByteFormattingAtTheBoundariesThatMatter() {
        XCTAssertEqual(SettingsViewModel.formattedBytes(0), "No audio on disk")
        XCTAssertEqual(SettingsViewModel.formattedBytes(1), "1 byte")
        XCTAssertEqual(SettingsViewModel.formattedBytes(999), "999 bytes")
        XCTAssertEqual(SettingsViewModel.formattedBytes(1_000), "1.0 KB")
        XCTAssertEqual(SettingsViewModel.formattedBytes(1_500), "1.5 KB")
        XCTAssertEqual(SettingsViewModel.formattedBytes(1_000_000), "1.0 MB")
        XCTAssertEqual(SettingsViewModel.formattedBytes(3_200_000_000), "3.2 GB")
        // Negative is impossible from the sweeper, but a nonsense number must not render
        // as a confident size.
        XCTAssertEqual(SettingsViewModel.formattedBytes(-1), "Unknown")
    }

    // MARK: - Privacy: delete all audio

    /// Irreversible, so the button asks first. A single tap that deletes is the bug this
    /// test exists to prevent.
    func testDeleteAllAsksBeforeDeletingAnything() async {
        diskUsageBytes = 2_500_000
        let model = makeModel()
        model.loadAudioDiskUsage()
        await drainPrivacyWork(model)

        model.requestDeleteAllAudio()

        XCTAssertEqual(deleteAllCalls, 0, "audio was deleted without a confirmation")
        XCTAssertNotNil(model.pendingDeleteAll)
        // The confirm copy has to say how much is about to go.
        XCTAssertTrue(model.pendingDeleteAll?.message.contains("2.5 MB") ?? false,
                      "the confirmation must name the amount: \(model.pendingDeleteAll?.message ?? "nil")")
    }

    func testConfirmingDeleteAllDeletesAndRefreshesTheReadout() async {
        diskUsageBytes = 2_500_000
        let model = makeModel()
        model.loadAudioDiskUsage()
        await drainPrivacyWork(model)

        model.requestDeleteAllAudio()
        model.confirmDeleteAllAudio()
        await drainPrivacyWork(model)

        XCTAssertEqual(deleteAllCalls, 1)
        XCTAssertNil(model.pendingDeleteAll)
        XCTAssertEqual(model.audioDiskUsage, .bytes(0), "the readout must re-read after a delete")
        XCTAssertNil(model.privacyError)
    }

    /// The confirmation is the consent, so it is also the *authority*: a confirm that
    /// nobody asked for — a stray call, a duplicated alert action, a re-entrant view
    /// update — must not delete anything.
    func testConfirmingWithNothingPendingDeletesNothing() async {
        let model = makeModel()
        model.confirmDeleteAllAudio()
        await drainPrivacyWork(model)

        XCTAssertEqual(deleteAllCalls, 0, "audio was deleted with no confirmation behind it")
        XCTAssertFalse(model.isDeletingAllAudio)
    }

    /// And a second confirm cannot re-run the deletion: the pending request is consumed
    /// by the first one.
    func testConfirmingTwiceDeletesOnce() async {
        let model = makeModel()
        model.requestDeleteAllAudio()
        model.confirmDeleteAllAudio()
        model.confirmDeleteAllAudio()
        await drainPrivacyWork(model)

        XCTAssertEqual(deleteAllCalls, 1)
    }

    func testCancellingTheConfirmationDeletesNothing() async {
        let model = makeModel()
        model.requestDeleteAllAudio()
        model.cancelDeleteAllAudio()
        await drainPrivacyWork(model)

        XCTAssertEqual(deleteAllCalls, 0)
        XCTAssertNil(model.pendingDeleteAll)
    }

    /// When the amount is unknown the confirmation still has to be honest about it
    /// rather than inventing "0 bytes will be deleted", which reads as "nothing to do".
    func testTheConfirmationAdmitsWhenTheAmountIsUnknown() async {
        diskUsageError = FakeFailure.boom("no log")
        let model = makeModel()
        model.loadAudioDiskUsage()
        await drainPrivacyWork(model)

        model.requestDeleteAllAudio()

        let message = model.pendingDeleteAll?.message ?? ""
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("0 bytes"), message)
        XCTAssertTrue(message.lowercased().contains("unknown"), message)
    }

    func testAFailedDeleteAllSurfaces() async {
        deleteAllError = FakeFailure.boom("permission denied")
        let model = makeModel()

        model.requestDeleteAllAudio()
        model.confirmDeleteAllAudio()
        await drainPrivacyWork(model)

        XCTAssertFalse(model.privacyError?.isEmpty ?? true)
        XCTAssertFalse(model.isDeletingAllAudio)
    }

    func testDeleteAllIsUnavailableWhileUnwiredRatherThanSilentlyDoingNothing() {
        deleteAllIsWired = false
        let model = makeModel()

        XCTAssertFalse(model.canDeleteAllAudio)
        XCTAssertFalse(model.deleteAllDisabledReason?.isEmpty ?? true)
    }

    // MARK: - Privacy: never store audio

    func testNeverStoreAudioPersistsAndIsOffByDefault() {
        let model = makeModel()
        XCTAssertFalse(settings.neverStoreAudio)

        model.setNeverStoreAudio(true)

        XCTAssertTrue(AppSettings(defaults: defaults).neverStoreAudio)
    }

    /// The behaviour belongs to `DictationPipeline` and is not implemented there yet, so
    /// the toggle says what it currently does — nothing — instead of implying that audio
    /// has stopped being written.
    func testNeverStoreAudioAdmitsThatThePipelineDoesNotHonourItYet() {
        let model = makeModel()
        if SettingsViewModel.pipelineHonoursNeverStoreAudio {
            XCTAssertNil(model.neverStoreAudioNotice)
        } else {
            XCTAssertFalse(model.neverStoreAudioNotice?.isEmpty ?? true)
        }
    }

    // MARK: - Privacy: no polling

    /// Spec §15: ~0% idle CPU, no polling timers. The disk figure and the login-item
    /// status both go stale until something asks, and the only things that ask are
    /// window-open and an explicit refresh.
    func testNothingInPrivacyOrGeneralPolls() async {
        diskUsageBytes = 1_000
        let model = makeModel()
        model.viewDidAppear()
        await drainPrivacyWork(model)
        XCTAssertEqual(diskUsageReads, 1)

        diskUsageBytes = 9_000_000
        loginService.reported = .enabled
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(diskUsageReads, 1, "something is polling the audio directory")
        XCTAssertEqual(model.audioDiskUsage, .bytes(1_000))
        XCTAssertFalse(model.launchAtLogin.isOn, "something is polling SMAppService")
    }
}
