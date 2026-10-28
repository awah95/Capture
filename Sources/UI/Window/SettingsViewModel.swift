import AppKit
import Combine
import Foundation

// MARK: - Supporting types

/// The Groq Whisper models this build offers.
///
/// Two, not a free-text field: a typo in a model id fails every dictation with an
/// opaque HTTP 400. `large` is listed in the plan's deferred set, so the picker marks
/// it honestly rather than presenting it as an equal choice.
enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case turbo = "whisper-large-v3-turbo"
    case large = "whisper-large-v3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .turbo: return "Whisper Large v3 Turbo"
        case .large: return "Whisper Large v3"
        }
    }

    var detail: String {
        switch self {
        case .turbo: return "The default. Fastest, and what every latency figure in this app was measured against."
        case .large: return "Slower and dearer. Untested in this build — the plan defers it."
        }
    }
}

/// One row of the microphone priority list.
struct PreferredMicrophone: Identifiable, Equatable, Sendable {
    let uid: String
    /// The device's name when it is plugged in; an honest stand-in when it is not.
    let name: String
    let isConnected: Bool
    var id: String { uid }
}

/// What the About section can honestly say about this month's provider spend.
enum GroqSpend: Equatable, Sendable {
    case loading
    case amount(usd: Double, dictations: Int)
    /// The record log could not be read. Spec: never invent a number.
    case unavailable(String)
}

/// What Settings can honestly say about the optional local ASR model.
enum LocalTranscriptionPreparationState: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case failed(String)
}

/// What the General section can say about launching at login.
///
/// A flattened snapshot of `LoginItem` rather than the object itself: `SettingsView` is
/// built with a fixed set of observed objects (`SettingsWindowController` constructs it),
/// so the state a row redraws on has to arrive through this view model's `@Published`
/// wall.
struct LoginItemState: Equatable {
    var isOn = false
    /// macOS registered the item but the switch is off in System Settings. Neither on
    /// nor an error — the row explains it instead of flipping back on its own.
    var needsApproval = false
    var advice: String?
}

/// What the Privacy section can honestly say about audio on disk.
///
/// `unavailable` exists because `RetentionSweepRunner.diskUsageBytes()` **throws rather
/// than reporting 0** for a log it cannot read. "0 bytes" next to a *Delete all audio*
/// button is a claim, and the wrong one.
enum AudioDiskUsage: Equatable {
    case loading
    case bytes(Int)
    case unavailable(String)
}

/// A pending *Delete all audio*, holding the copy the confirmation shows.
///
/// The amount is baked in at the moment of asking, because that is the number the user
/// is agreeing to lose.
struct PendingDeleteAll: Equatable {
    let message: String
}

extension RetentionPolicy {
    /// Picker labels for spec §16's five choices.
    ///
    /// Defined here rather than on the enum in `RetentionSweeper.swift`: that file is the
    /// sweep's arithmetic and has no business knowing about a UI. The raw values are the
    /// persisted form and must not be shown to anyone.
    var displayName: String {
        switch self {
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .forever: return "Keep forever"
        case .never: return "Never keep audio"
        }
    }

    /// One line under the picker, because "never" and "forever" are the two choices a
    /// user can pick without realising what they cost.
    var detail: String {
        switch self {
        case .sevenDays, .thirtyDays, .ninetyDays:
            return "Session audio older than this is deleted at the next daily sweep. "
                + "History keeps the text either way."
        case .forever:
            return "Nothing is ever purged. Disk usage grows with every dictation."
        case .never:
            return "Audio is deleted at the next sweep, so playback and retry are lost. "
                + "History keeps the text."
        }
    }
}

// MARK: - View model

/// Everything behind `SettingsView`, spec §10.5.
///
/// Every dependency is injected, so the whole screen is constructible in a test with
/// zero system access: no Keychain, no CoreAudio, no TCC, no filesystem. Nothing here
/// polls — permission status is refreshed by an external call (the composition root
/// already does it on `didBecomeActive`), and the device list is refreshed when the
/// window appears.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var contextProbeResult: String?
    @Published private(set) var contextProbeRunning = false

    func probeEditorContext() {
        guard !contextProbeRunning else { return }
        contextProbeRunning = true
        contextProbeResult = "Switch to the editor to check within 3 seconds…"
        Task {
            try? await Task.sleep(for: .seconds(3))
            let snapshot = await ContextProbe.snapshot()
            contextProbeResult = snapshot.summary
            contextProbeRunning = false
        }
    }

    @Published private(set) var vocabularyModelState: LocalTranscriptionPreparationState = .idle

    func prepareVocabularyModel() {
        guard vocabularyModelState != .preparing else { return }
        vocabularyModelState = .preparing
        Task {
            do {
                try await ParakeetVocabularyBooster.shared.prepare(allowDownload: true)
                vocabularyModelState = .ready
            } catch {
                vocabularyModelState = .failed(error.localizedDescription)
            }
        }
    }


    /// Whether `AppComposition` yet reads the four capture settings this screen writes
    /// (echo cancellation, model, language, segmentation).
    ///
    /// While this is `false` the Microphone and Transcription sections say so on
    /// screen, because a control that silently does nothing is worse than no control.
    /// **Flip it to `true` in the same commit that wires them** — see
    /// `docs/wiring/task25-wiring.md`.
    static let pipelineReadsCaptureSettings = true

    /// Whether `AppComposition` yet drives `MediaController` and `SoundFeedback` from
    /// the capture edges.
    ///
    /// Same contract as the flag above: while it is `false` the General section says the
    /// two toggles are stored but inert. **Flip it in the same commit that wires them**
    /// — `docs/wiring/task27-wiring.md`.
    static let captureEdgesDriveMediaAndSounds = true

    /// Whether `DictationPipeline` yet honours `AppSettings.neverStoreAudio` — deleting
    /// the session file the moment transcription succeeds and clearing the record's
    /// `audioFileName`.
    ///
    /// A privacy switch that silently does nothing is the worst kind of inert control,
    /// so while this is `false` the row says so in as many words.
    static let pipelineHonoursNeverStoreAudio = true

    /// The three rebindable combos. Push-to-talk is not here: it is a modifier, not a
    /// combo, so it gets a picker rather than a recorder.
    enum ShortcutSlot: String, CaseIterable, Identifiable, Sendable {
        /// The chord form of push-to-talk (⌘⇧D and the like). A slot rather than a
        /// bespoke control, so it inherits the recorder's suspend/resume, its refusal
        /// reporting, and its revert-on-failure — the three things that are easy to get
        /// wrong twice if there are two code paths.
        case pushToTalkChord
        case toggleDictation, toggleThought, showHistoryPalette

        /// The rows rendered unconditionally. `pushToTalkChord` is excluded because it is
        /// shown only when the push-to-talk picker is set to a custom shortcut.
        static let toggles: [ShortcutSlot] = [.toggleDictation, .toggleThought, .showHistoryPalette]

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pushToTalkChord: return "Push-to-talk shortcut"
            case .toggleDictation: return "Start / stop dictation"
            case .toggleThought: return "Capture a thought"
            case .showHistoryPalette: return "Show history"
            }
        }
    }

    /// What the push-to-talk picker offers. A separate type from `PushToTalkKey` because
    /// one of the choices — `custom` — is not a key at all but a mode that reveals a
    /// recorder, and because `PushToTalkBinding` carries an associated value and so cannot
    /// be a `Picker` tag.
    enum PushToTalkOption: String, CaseIterable, Identifiable, Hashable, Sendable {
        case rightOption, rightCommand, fnGlobe, custom, off

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rightOption: return "Right ⌥"
            case .rightCommand: return "Right ⌘"
            case .fnGlobe: return "Fn / 🌐"
            case .custom: return "Custom shortcut…"
            case .off: return "Off"
            }
        }

        /// Which option a stored binding is showing. A chord reads as `custom` whatever the
        /// combo is; the combo itself is the recorder's business, not the picker's.
        static func of(_ binding: PushToTalkBinding) -> PushToTalkOption {
            switch binding.normalized {
            case .chord: return .custom
            case .disabled: return .off
            case .modifier(let key):
                switch key {
                case .rightOption: return .rightOption
                case .rightCommand: return .rightCommand
                case .fnGlobe: return .fnGlobe
                case .disabled: return .off
                }
            }
        }
    }

    // MARK: Injected

    let settings: AppSettings
    let firstRun: FirstRunController
    /// Task 11's field, reused verbatim. Settings owns no second copy of the key path:
    /// the key goes to the Keychain through this and nowhere else.
    let keyModel: GroqKeyFieldModel
    let openRouterKeyModel: ProviderKeyFieldModel?
    let version: String
    let build: String

    private let hotkeys: any HotkeyManaging
    private let availableDevices: () -> [AudioInputDevice]
    private let loadRecords: () async throws -> [DictationRecord]
    private let resetHUDPositionAction: () -> Void
    private let applyAppearance: (AppAppearance) -> Void
    private let openDiagnosticsAction: () -> Void
    private let now: () -> Date
    private let calendar: Calendar

    // Task 27. The login item wraps `SMAppService`; the three Privacy closures are
    // pointed at `RetentionSweepRunner`. They are optional because `AppComposition` has
    // not connected them yet — and a control whose closure is missing says so rather
    // than doing nothing quietly (see `deleteAllDisabledReason`, `retentionNotice`).
    private let loginItem: LoginItem
    private let retentionSweep: (() async throws -> Void)?
    private let audioDiskUsageReader: (() async throws -> Int)?
    private let deleteAllAudioAction: (() async throws -> Void)?
    private let prepareLocalModelAction: ((
        TranscriptionProvider,
        @escaping @Sendable (LocalModelDownloadProgress) -> Void
    ) async throws -> Void)?
    private let localModelAvailabilityAction: ((TranscriptionProvider) async -> LocalModelAvailability)?
    private let removeLocalModelAction: ((TranscriptionProvider) async throws -> Void)?
    private let prepareLiveTranscriptionModelAction: ((
        TranscriptionProvider,
        @escaping @Sendable (LocalModelDownloadProgress) -> Void
    ) async throws -> Void)?
    private let liveTranscriptionModelAvailabilityAction:
        ((TranscriptionProvider) async -> LocalModelAvailability)?

    private let cleanupCoordinator: LocalCleanupCoordinator?
    var cleanupModels: [CleanupModelDescriptor] { cleanupCoordinator?.registry.models ?? LocalCleanupRegistry.builtIn.models }
    @Published private(set) var cleanupModelStates: [ModeCleanupChoice: LocalModelState] = [:]
    @Published private(set) var cleanupMemory: [ModeCleanupChoice: CleanupMemoryState] = [:]
    private var cleanupWork: [ModeCleanupChoice: Task<Void, Never>] = [:]
    private var cleanupGenerations: [ModeCleanupChoice: Int] = [:]

    func cleanupState(_ choice: ModeCleanupChoice) -> LocalModelState { cleanupModelStates[choice] ?? .checking }

    func observeCleanupMemory() async {
        guard let cleanupCoordinator else { return }
        for await state in await cleanupCoordinator.memoryUpdates() {
            guard !Task.isCancelled else { return }
            let previous = cleanupMemory
            cleanupMemory = state
            for model in cleanupModels where state[model.id] != previous[model.id] {
                if case .failed = state[model.id] { await refreshCleanupModel(model.id) }
            }
        }
    }

    func refreshCleanupModels() async {
        for model in cleanupModels {
            guard !Task.isCancelled else { return }
            await refreshCleanupModel(model.id)
        }
    }

    func refreshCleanupModel(_ choice: ModeCleanupChoice) async {
        guard cleanupWork[choice] == nil else { return }
        // A refresh can overlap another refresh (for example, initial checking
        // and load-time corruption repair). Only the newest read may publish.
        cleanupGenerations[choice, default: 0] += 1
        let generation = cleanupGenerations[choice, default: 0]
        let availability = await cleanupCoordinator?.availability(choice)
        guard generation == cleanupGenerations[choice, default: 0], cleanupWork[choice] == nil else { return }
        cleanupModelStates[choice] = availability?.isDownloaded == true
            ? .ready(updateAvailable: availability?.updateAvailable == true) : .notDownloaded
    }

    func downloadCleanupModel(_ choice: ModeCleanupChoice) {
        guard let cleanupCoordinator, cleanupWork[choice] == nil else { return }
        cleanupGenerations[choice, default: 0] += 1
        let generation = cleanupGenerations[choice, default: 0]
        cleanupModelStates[choice] = .downloading(.fraction(0, detail: "Preparing download…"))
        cleanupWork[choice] = Task { [self] in
            defer { if generation == cleanupGenerations[choice] { cleanupWork[choice] = nil } }
            do {
                try await cleanupCoordinator.download(choice) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, generation == self.cleanupGenerations[choice],
                              case .downloading = self.cleanupModelStates[choice] else { return }
                        self.cleanupModelStates[choice] = .downloading(progress)
                    }
                }
                try Task.checkCancellation()
                guard generation == cleanupGenerations[choice] else { return }
                cleanupModelStates[choice] = .ready(updateAvailable: false)
            } catch {
                guard generation == cleanupGenerations[choice] else { return }
                if Task.isCancelled {
                    let availability = await cleanupCoordinator.availability(choice)
                    guard generation == cleanupGenerations[choice] else { return }
                    cleanupModelStates[choice] = availability.isDownloaded
                        ? .ready(updateAvailable: availability.updateAvailable) : .notDownloaded
                } else { cleanupModelStates[choice] = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelCleanupDownload(_ choice: ModeCleanupChoice) { cleanupWork[choice]?.cancel() }

    func loadCleanupModel(_ choice: ModeCleanupChoice) {
        guard let cleanupCoordinator else { return }
        Task { try? await cleanupCoordinator.prepare(choice) }
    }

    func removeCleanupModel(_ choice: ModeCleanupChoice) {
        guard let cleanupCoordinator, cleanupWork[choice] == nil else { return }
        cleanupGenerations[choice, default: 0] += 1
        let generation = cleanupGenerations[choice, default: 0]
        cleanupModelStates[choice] = .checking
        cleanupWork[choice] = Task { [self] in
            defer { if generation == cleanupGenerations[choice] { cleanupWork[choice] = nil } }
            do {
                try await cleanupCoordinator.remove(choice)
                guard generation == cleanupGenerations[choice] else { return }
                cleanupModelStates[choice] = .notDownloaded
            } catch {
                guard generation == cleanupGenerations[choice] else { return }
                cleanupModelStates[choice] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Published state

    @Published private(set) var devices: [AudioInputDevice] = []
    /// Which row is recording, or nil. Exactly one row can record at a time, because
    /// the hotkey manager is suspended for the duration.
    @Published private(set) var recordingSlot: ShortcutSlot?
    @Published private(set) var spend: GroqSpend = .loading
    @Published private(set) var spendUnknownCostCount = 0
    @Published private(set) var pushToTalkError: String?
    @Published private(set) var localTranscriptionState: LocalTranscriptionPreparationState = .idle
    @Published private(set) var localModelStates: [TranscriptionProvider: LocalModelState] = [
        .localUnified: .checking,
        .localMoonshine: .checking,
        .localUltra: .checking,
        .localPhonon: .checking,
    ]
    @Published private(set) var liveTranscriptionModelStates: [TranscriptionProvider: LocalModelState] = [
        .localUnified: .checking,
        .localMoonshine: .ready(updateAvailable: false),
    ]
    @Published private(set) var localModelUsageByProvider:
        [TranscriptionProvider: LocalModelUsageSummary] = [:]
    @Published private(set) var localModelUsageAvailable = false
    @Published private(set) var localModelErrors: [TranscriptionProvider: String] = [:]
    @Published private(set) var localModelInstalledVersions: [TranscriptionProvider: String] = [:]
    @Published private(set) var localModelInstalledBytes: [TranscriptionProvider: Int] = [:]
    @Published private(set) var unattributedLegacyDictationCount = 0
    @Published private(set) var unattributedLegacyWords = 0
    @Published private(set) var unattributedLegacyAudioSeconds: TimeInterval = 0
    @Published private var pendingLiveTranscriptionProviders: Set<TranscriptionProvider> = []
    // Download intent is independent of the live toggle and survives a failed upgrade.
    private var requestedLiveModelUpgrades: Set<TranscriptionProvider> = []

    /// Which push-to-talk option the picker is showing.
    ///
    /// It cannot be derived from the stored binding, and the reason is the one state the
    /// binding cannot represent: "Custom shortcut… is selected but nothing is recorded
    /// yet" stores as `.disabled`, which would read back as *Off* and hide the recorder
    /// the user just asked for. So the mode is remembered here and the binding stays the
    /// single source of truth for what is actually registered.
    @Published private(set) var pushToTalkOption: PushToTalkOption

    /// The last chord recorded for push-to-talk, so switching to Right ⌥ and back does not
    /// discard it. Not persisted: it is a convenience within one Settings visit, and
    /// anything the user committed is already in `settings.hotkeyBindings`.
    private var lastChord: KeyCombo?

    /// Per-row inline messages: what Carbon refused, or why a keystroke was not usable.
    @Published private var shortcutErrors: [ShortcutSlot: String] = [:]

    // MARK: Published state — Task 27

    @Published private(set) var launchAtLogin = LoginItemState()
    /// Starts as `.loading`, not `.bytes(0)`: before anything has been read, the honest
    /// answer is "not yet", and zero is a number the user would believe.
    @Published private(set) var audioDiskUsage: AudioDiskUsage = .loading
    /// A purge or a delete that failed. Spec §17: always say what happened.
    @Published private(set) var privacyError: String?
    @Published private(set) var pendingDeleteAll: PendingDeleteAll?
    @Published private(set) var isDeletingAllAudio = false

    /// Privacy work is **chained**, the same idiom `AppComposition` uses for capture
    /// edges and `RetentionSweepRunner` uses for sweeps. A delete and a disk read that
    /// interleaved would report the size from the middle of the deletion. Tests await
    /// this to drain the queue.
    private(set) var privacyWork: Task<Void, Never>?
    private(set) var localTranscriptionPreparation: Task<Void, Never>?
    private(set) var liveTranscriptionPreparation: Task<Void, Never>?
    private var lastLocalProvider: TranscriptionProvider

    /// Whether *this* object has the hotkey manager suspended. Tracked rather than
    /// asked, so suspend/resume can never fall out of balance however the rows are
    /// clicked — a suspended manager that is never resumed is a dead app.
    private var didSuspendHotkeys = false

    init(settings: AppSettings,
         hotkeys: any HotkeyManaging,
         firstRun: FirstRunController,
         keyModel: GroqKeyFieldModel,
         openRouterKeyModel: ProviderKeyFieldModel? = nil,
         availableDevices: @escaping () -> [AudioInputDevice],
         loadRecords: @escaping () async throws -> [DictationRecord],
         resetHUDPosition: @escaping () -> Void,
         applyAppearance: @escaping (AppAppearance) -> Void,
         openDiagnostics: @escaping () -> Void,
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         version: String = SettingsViewModel.bundleVersion,
         build: String = SettingsViewModel.bundleBuild,
         loginItem: LoginItem? = nil,
         cleanupCoordinator: LocalCleanupCoordinator? = nil,
         prepareLocalModel: ((
            TranscriptionProvider,
            @escaping @Sendable (LocalModelDownloadProgress) -> Void
         ) async throws -> Void)? = nil,
         localModelAvailability: ((TranscriptionProvider) async -> LocalModelAvailability)? = nil,
         removeLocalModel: ((TranscriptionProvider) async throws -> Void)? = nil,
         prepareLiveTranscriptionModel: ((
            TranscriptionProvider,
            @escaping @Sendable (LocalModelDownloadProgress) -> Void
         ) async throws -> Void)? = nil,
         liveTranscriptionModelAvailability:
            ((TranscriptionProvider) async -> LocalModelAvailability)? = nil,
         retentionSweep: (() async throws -> Void)? = nil,
         audioDiskUsage: (() async throws -> Int)? = nil,
         deleteAllAudio: (() async throws -> Void)? = nil) {
        self.pushToTalkOption = PushToTalkOption.of(settings.hotkeyBindings.pushToTalk)
        self.lastLocalProvider = settings.transcriptionProvider.isLocal
            ? settings.transcriptionProvider : .localUnified
        self.lastChord = settings.hotkeyBindings.pushToTalk.chordCombo
        self.settings = settings
        self.hotkeys = hotkeys
        self.firstRun = firstRun
        self.keyModel = keyModel
        self.openRouterKeyModel = openRouterKeyModel
        self.availableDevices = availableDevices
        self.loadRecords = loadRecords
        self.resetHUDPositionAction = resetHUDPosition
        self.applyAppearance = applyAppearance
        self.openDiagnosticsAction = openDiagnostics
        self.now = now
        self.calendar = calendar
        self.version = version
        self.build = build
        // `nil` rather than `LoginItem()` as the default argument: default arguments are
        // evaluated outside the actor and `LoginItem` is `@MainActor`. Production gets
        // the real `SMAppService` wrapper; every test passes a fake.
        self.loginItem = loginItem ?? LoginItem()
        self.cleanupCoordinator = cleanupCoordinator
        self.prepareLocalModelAction = prepareLocalModel
        self.localModelAvailabilityAction = localModelAvailability
        self.removeLocalModelAction = removeLocalModel
        self.prepareLiveTranscriptionModelAction = prepareLiveTranscriptionModel
        self.liveTranscriptionModelAvailabilityAction = liveTranscriptionModelAvailability
        self.retentionSweep = retentionSweep
        self.audioDiskUsageReader = audioDiskUsage
        self.deleteAllAudioAction = deleteAllAudio
        syncLoginItem()
    }

    // MARK: - Lifecycle

    /// Called when the window appears. Reads the two things that can have changed while
    /// Settings was closed, once, rather than on a timer.
    func viewDidAppear() {
        refreshDevices()
        refreshPermissions()
        // The login item can have been changed in System Settings while Captur was in
        // the background, and audio can have been purged by the daily sweep. Both are
        // read here, once — never on a timer (spec §15).
        refreshLoginItem()
        loadAudioDiskUsage()
        refreshLocalModels()
        refreshLiveTranscriptionModels()
        if settings.transcriptionProvider.isLocal { prepareLocalModel(settings.transcriptionProvider) }
        if settings.liveTranscriptionEnabled(for: settings.transcriptionProvider) {
            prepareLiveTranscriptionModel(settings.transcriptionProvider)
        }
        Task {
            await loadSpend()
            await loadUsageStats()
        }
    }

    /// The window closed. The only thing that *must* happen here is the resume — a
    /// window dismissed mid-recording would otherwise leave every global hotkey dead
    /// with nothing left on screen to fix it.
    func viewDidDisappear() {
        endRecording()
    }

    // MARK: - General

    func resetHUDPosition() {
        resetHUDPositionAction()
    }

    func setAppearance(_ appearance: AppAppearance) {
        settings.appearance = appearance
        applyAppearance(appearance)
    }

    func openDiagnostics() {
        openDiagnosticsAction()
    }

    // MARK: - General: launch at login

    func refreshLoginItem() {
        loginItem.refresh()
        syncLoginItem()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItem.setEnabled(enabled)
        syncLoginItem()
    }

    /// The `requiresApproval` escape hatch: the switch lives in System Settings and the
    /// app is not allowed to flip it, so the only useful thing the row can do is take
    /// the user there.
    func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }

    private func syncLoginItem() {
        launchAtLogin = LoginItemState(isOn: loginItem.isOn,
                                       needsApproval: loginItem.needsApproval,
                                       advice: loginItem.advice)
    }

    // MARK: - General: media pause and sounds

    func setPauseMediaDuringRecording(_ enabled: Bool) {
        settings.pauseMediaDuringRecording = enabled
    }

    func setLowerOutputVolumeDuringRecording(_ enabled: Bool) {
        settings.lowerOutputVolumeDuringRecording = enabled
    }

    func setRecordingOutputVolume(_ level: Double) {
        guard level.isFinite else { return }
        settings.recordingOutputVolume = min(max(level, 0), 1)
    }

    func setSoundFeedback(_ enabled: Bool) {
        settings.soundFeedback = enabled
    }

    /// Clamped on the way **in**, so the stored value and the slider agree. Clamping only
    /// at playback would leave a plist holding 9.0 and a slider pinned at its maximum
    /// disagreeing about what the user chose.
    func setSoundFeedbackVolume(_ volume: Double) {
        settings.soundFeedbackVolume = min(max(volume, 0), 1)
    }

    /// Shown under the two rows whose settings are stored but not yet acted on.
    var mediaAndSoundNotice: String? {
        Self.captureEdgesDriveMediaAndSounds
            ? nil
            : "Saved, but nothing acts on them yet — media pause and the start/stop sounds "
                + "take effect once AppComposition connects them to the capture edges "
                + "(docs/wiring/task27-wiring.md)."
    }

    // MARK: - Privacy (spec §16)

    /// A retention change is an instruction, not a preference: the user has just told the
    /// app that some of their audio should not exist, so it sweeps now rather than
    /// waiting for tomorrow's tick.
    ///
    /// The stored policy stands even if the sweep fails — `RetentionSweepRunner` re-reads
    /// it on every sweep, so the choice still takes effect at the next one.
    func setRetentionPolicy(_ policy: RetentionPolicy) {
        // SwiftUI re-sets a picker binding to the value it already holds; sweeping for
        // that would delete audio nobody asked about.
        guard policy != settings.retentionPolicy else { return }
        settings.retentionPolicy = policy
        privacyError = nil

        guard let retentionSweep else { return }
        enqueuePrivacyWork { [weak self] in
            do {
                try await retentionSweep()
            } catch {
                self?.privacyError = "The new retention setting was saved, but the purge could "
                    + "not run: \(error.localizedDescription)"
                return
            }
            // The sweep may have deleted a great deal; the readout above it would
            // otherwise keep showing the old figure until the window is reopened.
            await self?.readAudioDiskUsage()
        }
    }

    var retentionNotice: String? {
        retentionSweep == nil
            ? "Saved. Captur cannot purge right now — the change takes effect at the next "
                + "launch sweep or daily sweep (docs/wiring/task27-wiring.md)."
            : nil
    }

    // MARK: Privacy: disk usage

    func loadAudioDiskUsage() {
        enqueuePrivacyWork { [weak self] in await self?.readAudioDiskUsage() }
    }

    /// What the row renders. Never "0 bytes" for an answer nobody knows — the two are
    /// different facts and only one of them is next to a Delete-all button.
    var audioDiskUsageText: String {
        switch audioDiskUsage {
        case .loading: return "Reading…"
        case .bytes(let bytes): return Self.formattedBytes(bytes)
        case .unavailable: return "Unknown"
        }
    }

    private func readAudioDiskUsage() async {
        guard let audioDiskUsageReader else {
            audioDiskUsage = .unavailable(
                "Not connected yet — AppComposition has to pass RetentionSweepRunner in "
                    + "(docs/wiring/task27-wiring.md).")
            return
        }
        do {
            audioDiskUsage = .bytes(try await audioDiskUsageReader())
        } catch {
            // `diskUsageBytes()` throws rather than returning 0 for an unreadable log,
            // precisely so this branch exists.
            audioDiskUsage = .unavailable(
                "The dictation log could not be read, so the amount of audio on disk is unknown.")
        }
    }

    // MARK: Privacy: delete all audio

    var canDeleteAllAudio: Bool { deleteAllAudioAction != nil }

    var deleteAllDisabledReason: String? {
        canDeleteAllAudio
            ? nil
            : "Not connected yet — AppComposition has to pass RetentionSweepRunner.deleteAllAudio "
                + "in (docs/wiring/task27-wiring.md)."
    }

    /// Asks first. There is no undo for a deleted recording, so the button opens a
    /// confirmation and nothing else — the deletion happens in `confirmDeleteAllAudio`.
    func requestDeleteAllAudio() {
        guard canDeleteAllAudio else { return }
        pendingDeleteAll = PendingDeleteAll(message: Self.deleteAllMessage(for: audioDiskUsage))
    }

    func cancelDeleteAllAudio() {
        pendingDeleteAll = nil
    }

    func confirmDeleteAllAudio() {
        // Only a pending confirmation can delete. Without this guard the destructive
        // path would be reachable from a stray call with no user consent behind it.
        guard pendingDeleteAll != nil, let deleteAllAudioAction else { return }
        pendingDeleteAll = nil
        privacyError = nil
        isDeletingAllAudio = true

        enqueuePrivacyWork { [weak self] in
            do {
                try await deleteAllAudioAction()
            } catch {
                self?.privacyError = "Some audio could not be deleted: \(error.localizedDescription)"
            }
            self?.isDeletingAllAudio = false
            // Re-read even after a failure: a partial delete moved the number, and the
            // sweeper's own policy is that a file it could not delete is still there.
            await self?.readAudioDiskUsage()
        }
    }

    /// The confirmation copy. It has to name what is about to go, and admit when it
    /// cannot — "0 bytes will be deleted" reads as "this button does nothing".
    static func deleteAllMessage(for usage: AudioDiskUsage) -> String {
        let consequence = "History keeps the text of every dictation; playback and retry are lost. "
            + "This cannot be undone."
        switch usage {
        case .bytes(0):
            return "There is no session audio on disk, so nothing will be deleted."
        case .bytes(let bytes):
            return "\(formattedBytes(bytes)) of session audio will be deleted. \(consequence)"
        case .loading, .unavailable:
            return "The amount of audio on disk is unknown, so this deletes every session file "
                + "Captur can find. \(consequence)"
        }
    }

    // MARK: Privacy: never store audio

    func setNeverStoreAudio(_ enabled: Bool) {
        settings.neverStoreAudio = enabled
    }

    var neverStoreAudioNotice: String? {
        Self.pipelineHonoursNeverStoreAudio
            ? nil
            : "Saved, but audio is still being written — the pipeline does not delete session "
                + "files yet (docs/wiring/task27-wiring.md). Use the retention setting above "
                + "until it does."
    }

    // MARK: Privacy: plumbing

    /// Chains Privacy work behind whatever is already queued, so a disk read can never
    /// land in the middle of a delete and report a number from halfway through it.
    private func enqueuePrivacyWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = privacyWork
        privacyWork = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Bytes are what the sweeper counts; a size is what a human reads.
    ///
    /// **Decimal units**, matching how macOS has reported file sizes since 10.6 — a
    /// figure here that disagreed with the one in Finder would look like a bug in the
    /// deletion. `String(format:)` with no locale keeps the decimal point stable, which
    /// is what the boundary tests pin.
    static func formattedBytes(_ bytes: Int) -> String {
        // The sweeper cannot produce a negative total, so this is a corrupt number
        // rather than a small one. It must not render as a confident size.
        guard bytes >= 0 else { return "Unknown" }
        guard bytes > 0 else { return "No audio on disk" }
        if bytes == 1 { return "1 byte" }
        if bytes < 1_000 { return "\(bytes) bytes" }

        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1_000
        var index = 0
        while value >= 1_000, index < units.count - 1 {
            value /= 1_000
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }

    // MARK: - Microphone

    func refreshDevices() {
        devices = availableDevices()
    }

    /// The priority list, in order. Spec §4.2: the first *available* device wins, so a
    /// UID that is not currently plugged in still holds its place.
    var preferredMicrophones: [PreferredMicrophone] {
        settings.micPolicy.preferredDeviceUIDs.map { uid in
            if let device = devices.first(where: { $0.id == uid }) {
                return PreferredMicrophone(uid: uid, name: device.name, isConnected: true)
            }
            return PreferredMicrophone(uid: uid, name: "Not connected", isConnected: false)
        }
    }

    /// Devices that exist but are not yet in the priority list.
    var addableMicrophones: [AudioInputDevice] {
        let chosen = Set(settings.micPolicy.preferredDeviceUIDs)
        return devices.filter { !chosen.contains($0.id) }
    }

    func addPreferredMicrophone(_ uid: String) {
        guard !settings.micPolicy.preferredDeviceUIDs.contains(uid) else { return }
        settings.micPolicy.preferredDeviceUIDs.append(uid)
    }

    func removePreferredMicrophone(_ uid: String) {
        settings.micPolicy.preferredDeviceUIDs.removeAll { $0 == uid }
    }

    /// Drag-reorder, from `List`'s `onMove`.
    func movePreferredMicrophones(fromOffsets source: IndexSet, toOffset destination: Int) {
        var uids = settings.micPolicy.preferredDeviceUIDs
        uids.move(fromOffsets: source, toOffset: destination)
        settings.micPolicy.preferredDeviceUIDs = uids
    }

    /// Keyboard- and click-reachable reordering. Drag is not an accessible-only path,
    /// and on macOS a `List` inside a `Form` makes it fiddly even with a mouse.
    func movePreferredMicrophone(uid: String, by delta: Int) {
        var uids = settings.micPolicy.preferredDeviceUIDs
        guard let index = uids.firstIndex(of: uid) else { return }
        let target = index + delta
        guard uids.indices.contains(target) else { return }   // clamp at the ends
        uids.swapAt(index, target)
        settings.micPolicy.preferredDeviceUIDs = uids
    }

    func setExcludeContinuityInputs(_ exclude: Bool) {
        settings.micPolicy.excludeContinuityInputs = exclude
    }

    func setVoiceProcessing(_ enabled: Bool) {
        settings.voiceProcessing = enabled
    }

    // MARK: - Shortcuts

    func combo(for slot: ShortcutSlot) -> KeyCombo? {
        switch slot {
        case .pushToTalkChord: return settings.hotkeyBindings.pushToTalk.chordCombo
        case .toggleDictation: return settings.hotkeyBindings.toggleDictation
        case .toggleThought: return settings.hotkeyBindings.toggleThought
        case .showHistoryPalette: return settings.hotkeyBindings.showHistoryPalette
        }
    }

    func shortcutError(for slot: ShortcutSlot) -> String? {
        shortcutErrors[slot]
    }

    /// Thought capture is not reachable in this build.
    ///
    /// They are shown **disabled with the reason** rather than omitted, deliberately:
    /// It is shown disabled with the reason rather than omitted, so re-enabling the
    /// feature later does not silently reset the user's stored shortcut.
    func isEditable(_ slot: ShortcutSlot) -> Bool {
        disabledReason(for: slot) == nil
    }

    func disabledReason(for slot: ShortcutSlot) -> String? {
        switch slot {
        case .pushToTalkChord, .toggleDictation, .showHistoryPalette:
            return nil
        case .toggleThought:
            return FeatureFlags.thoughtCapture
                ? nil
                : "Thought capture is parked in this build, so this shortcut does nothing yet."
        }
    }

    func beginRecording(_ slot: ShortcutSlot) {
        guard isEditable(slot) else { return }
        shortcutErrors[slot] = nil
        recordingSlot = slot
        // Without this, pressing ⌥Space to record it starts a dictation instead.
        suspendHotkeys()
    }

    func cancelRecording() {
        endRecording()
    }

    /// A keystroke that cannot be a shortcut. Recording continues — the user has not
    /// finished choosing — so the manager stays suspended.
    func rejectCapture(_ reason: String, for slot: ShortcutSlot) {
        shortcutErrors[slot] = reason
    }

    /// Commit a recorded combo.
    ///
    /// Resume happens **before** `apply`, and that ordering is load-bearing:
    /// `HotkeyManager.apply` returns early while suspended, so applying first would
    /// register nothing, throw nothing, and persist a combo that turns out to be dead
    /// after the next relaunch. Persist only what registered.
    func capture(_ combo: KeyCombo, for slot: ShortcutSlot) {
        let previous = settings.hotkeyBindings

        // Caught here rather than at registration, because Carbon will happily register
        // the SAME combo twice for two different hotkey ids. Nothing would be refused; the
        // press would simply fire both actions, and a push-to-talk that is also the
        // dictation toggle starts a recording and immediately toggles it off again.
        if let owner = previous.conflict(with: combo, excluding: slot.title) {
            shortcutErrors[slot] = "\(ShortcutNotation.display(combo)) is already used for "
                + "\(owner). Choose a different shortcut, or clear that one first."
            // Recording continues: the user has not finished choosing.
            return
        }

        var next = previous
        next[slot] = combo

        endRecording()

        do {
            try hotkeys.apply(effective(next))
            settings.hotkeyBindings = next
            shortcutErrors[slot] = nil
            if slot == .pushToTalkChord { lastChord = combo }
        } catch {
            shortcutErrors[slot] = Self.refusalMessage(for: error, combo: combo)
            // Put back what was registered before, so what Carbon holds and what is
            // stored never disagree.
            try? hotkeys.apply(effective(previous))
        }
    }

    func clearBinding(_ slot: ShortcutSlot) {
        guard isEditable(slot) else { return }
        let previous = settings.hotkeyBindings
        var next = previous
        next[slot] = nil
        do {
            try hotkeys.apply(effective(next))
            settings.hotkeyBindings = next
            shortcutErrors[slot] = nil
            // Forgotten too, or switching to Right ⌥ and back would resurrect the very
            // shortcut the user just removed. The picker deliberately stays on "Custom
            // shortcut…" showing "Not set": push-to-talk is off, and it says so.
            if slot == .pushToTalkChord { lastChord = nil }
        } catch {
            try? hotkeys.apply(effective(previous))
        }
    }

    /// Applies a picker choice.
    ///
    /// Choosing `custom` keeps any chord already stored, so switching to Right ⌥ and back
    /// does not throw away the shortcut the user recorded. When there is no chord yet the
    /// binding lands on `.disabled` and the recorder row appears reading "Not set" — off
    /// until a shortcut is actually recorded, which is honest: there is nothing to hold.
    func setPushToTalk(_ option: PushToTalkOption) {
        let previous = settings.hotkeyBindings
        var next = previous

        switch option {
        case .rightOption: next.pushToTalk = .modifier(.rightOption)
        case .rightCommand: next.pushToTalk = .modifier(.rightCommand)
        case .fnGlobe: next.pushToTalk = .modifier(.fnGlobe)
        case .off: next.pushToTalk = .disabled
        case .custom:
            next.pushToTalk = lastChord.map { PushToTalkBinding.chord($0) } ?? .disabled
        }

        do {
            try hotkeys.apply(effective(next))
            settings.hotkeyBindings = next
            pushToTalkOption = option
            pushToTalkError = nil
        } catch {
            pushToTalkError = Self.pushToTalkRefusalMessage(for: option)
            try? hotkeys.apply(effective(previous))
        }
    }

    func restoreShortcutDefaults() {
        let previous = settings.hotkeyBindings
        do {
            try hotkeys.apply(effective(.default))
            settings.hotkeyBindings = .default
            shortcutErrors = [:]
            pushToTalkError = nil
            pushToTalkOption = PushToTalkOption.of(HotkeyBindings.default.pushToTalk)
            lastChord = nil
        } catch {
            try? hotkeys.apply(effective(previous))
        }
    }

    /// The bindings actually handed to Carbon.
    ///
    /// Mirrors `AppComposition.wireHotkeys`: a parked feature's binding is stored but
    /// never registered. Without this, opening Settings would register a hotkey the
    /// launch path deliberately dropped.
    private func effective(_ bindings: HotkeyBindings) -> HotkeyBindings {
        var effective = bindings
        if !FeatureFlags.thoughtCapture { effective.toggleThought = nil }
        return effective
    }

    private func suspendHotkeys() {
        guard !didSuspendHotkeys else { return }
        didSuspendHotkeys = true
        hotkeys.suspend()
    }

    private func resumeHotkeys() {
        guard didSuspendHotkeys else { return }
        didSuspendHotkeys = false
        hotkeys.resume()
    }

    /// The single exit from a recording, by any route: committed, cancelled, Escape, or
    /// the window closing.
    private func endRecording() {
        recordingSlot = nil
        resumeHotkeys()
    }

    static func refusalMessage(for error: Error, combo: KeyCombo) -> String {
        let name = ShortcutNotation.display(combo)
        guard case HotkeyError.registrationFailed(let status) = error else {
            return "\(name) could not be registered. The previous shortcut is still in place."
        }
        return "\(name) is already taken by macOS or another app (error \(status)). "
            + "The previous shortcut is still in place."
    }

    static func pushToTalkRefusalMessage(for option: PushToTalkOption) -> String {
        "\(option.title) could not be used for push-to-talk. The previous key is still in place."
    }

    static func pushToTalkTitle(_ key: PushToTalkKey) -> String {
        switch key {
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .fnGlobe: return "Fn / 🌐"
        case .disabled: return "Off"
        }
    }

    // MARK: - Transcription

    var selectedModel: WhisperModel {
        WhisperModel(rawValue: settings.transcriptionModel) ?? .turbo
    }

    var usesLocalTranscription: Bool {
        settings.transcriptionProvider.isLocal
    }

    var selectedLocalProvider: TranscriptionProvider {
        settings.transcriptionProvider.isLocal ? settings.transcriptionProvider : lastLocalProvider
    }

    var selectedTranscriptionProvider: TranscriptionProvider {
        settings.transcriptionProvider
    }

    var liveTranscriptionEnabled: Bool {
        settings.liveTranscriptionEnabled(for: settings.transcriptionProvider)
            || pendingLiveTranscriptionProviders.contains(settings.transcriptionProvider)
    }

    var liveTranscriptionSupported: Bool {
        settings.transcriptionProvider.supportsLiveTranscription
    }

    var showsBatchFinalTranscriptionOption: Bool {
        settings.transcriptionProvider == .localUnified && liveTranscriptionEnabled
    }

    var retranscribeFinalWithBatch: Bool {
        settings.retranscribeFinalWithBatch
    }

    func setUseLocalTranscription(_ enabled: Bool) {
        settings.transcriptionProvider = enabled ? lastLocalProvider : .groq
        if enabled {
            prepareLocalModel(lastLocalProvider)
            if settings.liveTranscriptionEnabled(for: lastLocalProvider) {
                prepareLiveTranscriptionModel(lastLocalProvider)
            }
        }
    }

    func selectLocalModel(_ provider: TranscriptionProvider) {
        guard provider.isLocal else { return }
        lastLocalProvider = provider
        settings.transcriptionProvider = provider
        prepareLocalModel(provider)
        if settings.liveTranscriptionEnabled(for: provider) {
            prepareLiveTranscriptionModel(provider)
        }
    }

    func downloadLocalModel(_ provider: TranscriptionProvider) {
        guard provider.isLocal else { return }
        switch localModelState(provider) {
        case .ready(updateAvailable: true), .failed:
            upgradeLocalModel(provider)
        default:
            prepareLocalModel(provider, force: true)
        }
    }

    func upgradeLocalModel(_ provider: TranscriptionProvider) {
        guard provider.isLocal else { return }
        prepareLocalModel(provider, force: true, replacing: true)
    }

    func updateLiveTranscriptionModel(_ provider: TranscriptionProvider) {
        guard case .additionalDownload = provider.liveTranscriptionCapability else { return }
        if case .downloading = localModelStates[provider] { return }
        if case .downloading = liveTranscriptionModelStates[provider] { return }
        // Unified shares its decoder and vocabulary with batch. Replace both together,
        // including the requested live artifact even when its toggle is off.
        requestedLiveModelUpgrades.insert(provider)
        upgradeLocalModel(provider)
    }

    func removeLocalModel(_ provider: TranscriptionProvider) {
        guard provider.isLocal, let action = removeLocalModelAction else { return }
        if case .downloading = localModelStates[provider] { return }
        if case .downloading = liveTranscriptionModelStates[provider] { return }
        localModelErrors.removeValue(forKey: provider)
        localModelStates[provider] = .checking
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await action(provider)
                self.localModelStates[provider] = .notDownloaded
                self.localModelInstalledBytes.removeValue(forKey: provider)
                self.localModelInstalledVersions.removeValue(forKey: provider)
                self.liveTranscriptionModelStates[provider] = provider == .localMoonshine
                    ? .ready(updateAvailable: false) : .notDownloaded
                self.pendingLiveTranscriptionProviders.remove(provider)
                self.requestedLiveModelUpgrades.remove(provider)
                self.settings.setLiveTranscriptionEnabled(false, for: provider)
                if self.settings.transcriptionProvider == provider {
                    self.settings.transcriptionProvider = .groq
                    self.localTranscriptionState = .idle
                }
            } catch {
                self.localModelErrors[provider] = error.localizedDescription
                self.localModelStates[provider] = .failed(error.localizedDescription)
            }
        }
    }

    func localModelState(_ provider: TranscriptionProvider) -> LocalModelState {
        localModelStates[provider] ?? .notDownloaded
    }

    func localModelUsage(for provider: TranscriptionProvider) -> LocalModelUsageSummary {
        localModelUsageByProvider[provider] ?? LocalModelUsageSummary()
    }

    func localModelSize(_ descriptor: LocalModelDescriptor) -> String {
        localModelInstalledBytes[descriptor.provider].map(Self.formattedBytes) ?? descriptor.size
    }

    func liveTranscriptionModelState(_ provider: TranscriptionProvider) -> LocalModelState {
        liveTranscriptionModelStates[provider] ?? .notDownloaded
    }

    func setLiveTranscriptionEnabled(_ enabled: Bool) {
        let provider = settings.transcriptionProvider
        guard provider.supportsLiveTranscription else { return }
        if !enabled {
            pendingLiveTranscriptionProviders.remove(provider)
            settings.setLiveTranscriptionEnabled(false, for: provider)
            return
        }

        switch provider.liveTranscriptionCapability {
        case .included:
            settings.setLiveTranscriptionEnabled(true, for: provider)
        case .additionalDownload:
            if case .ready = liveTranscriptionModelStates[provider] {
                settings.setLiveTranscriptionEnabled(true, for: provider)
            } else {
                // Reflect the user's intent in the toggle while downloading, but do
                // not let the capture pipeline enter streaming mode until the
                // artifact is actually ready.
                pendingLiveTranscriptionProviders.insert(provider)
                prepareLiveTranscriptionModel(provider)
            }
        case .unsupported:
            break
        }
    }

    func setRetranscribeFinalWithBatch(_ enabled: Bool) {
        settings.retranscribeFinalWithBatch = enabled
    }

    private func refreshLocalModels() {
        guard let action = localModelAvailabilityAction else {
            for descriptor in LocalModelDescriptor.all {
                localModelStates[descriptor.provider] = .notDownloaded
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for descriptor in LocalModelDescriptor.all {
                let availability = await action(descriptor.provider)
                if case .downloading = self.localModelStates[descriptor.provider] { continue }
                self.localModelInstalledVersions[descriptor.provider] = availability.installedVersion
                if let bytes = availability.installedBytes {
                    self.localModelInstalledBytes[descriptor.provider] = bytes
                } else if !availability.isDownloaded {
                    self.localModelInstalledBytes.removeValue(forKey: descriptor.provider)
                }
                self.localModelStates[descriptor.provider] = availability.isDownloaded
                    ? .ready(updateAvailable: availability.updateAvailable)
                    : .notDownloaded
            }
        }
    }

    private func refreshInstalledBytes(for provider: TranscriptionProvider) {
        guard let action = localModelAvailabilityAction else { return }
        Task { @MainActor [weak self] in
            let availability = await action(provider)
            guard let self else { return }
            self.localModelInstalledVersions[provider] = availability.installedVersion
            if case .ready = self.localModelStates[provider] {
                self.localModelStates[provider] = availability.isDownloaded
                    ? .ready(updateAvailable: availability.updateAvailable) : .notDownloaded
            }
            if let bytes = availability.installedBytes {
                self.localModelInstalledBytes[provider] = bytes
            } else if !availability.isDownloaded {
                self.localModelInstalledBytes.removeValue(forKey: provider)
            }
        }
    }

    private func refreshLiveTranscriptionModels() {
        liveTranscriptionModelStates[.localMoonshine] = .ready(updateAvailable: false)
        guard let action = liveTranscriptionModelAvailabilityAction else {
            liveTranscriptionModelStates[.localUnified] = .notDownloaded
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let availability = await action(.localUnified)
            self.liveTranscriptionModelStates[.localUnified] = availability.isDownloaded
                ? .ready(updateAvailable: availability.updateAvailable)
                : .notDownloaded
        }
    }

    private func prepareLiveTranscriptionModel(
        _ provider: TranscriptionProvider,
        force: Bool = false
    ) {
        guard provider.supportsLiveTranscription else { return }
        guard case .additionalDownload = provider.liveTranscriptionCapability else { return }
        if !force, case .ready = liveTranscriptionModelStates[provider] { return }
        if case .downloading = liveTranscriptionModelStates[provider] { return }

        guard let action = prepareLiveTranscriptionModelAction else {
            settings.setLiveTranscriptionEnabled(false, for: provider)
            liveTranscriptionModelStates[provider] = .failed(
                "Live transcription is unavailable in this build.")
            return
        }

        liveTranscriptionModelStates[provider] = .downloading(
            .fraction(0, detail: "Preparing live model download…"))
        liveTranscriptionPreparation = Task { @MainActor [weak self] in
            guard let self else { return }
            let model = self
            do {
                try await action(provider) { progress in
                    Task { @MainActor in
                        model.liveTranscriptionModelStates[provider] = .downloading(progress)
                    }
                }
                guard !Task.isCancelled else { return }
                let availability = await self.liveTranscriptionModelAvailabilityAction?(provider)
                self.liveTranscriptionModelStates[provider] = .ready(
                    updateAvailable: availability?.updateAvailable ?? false)
                self.refreshInstalledBytes(for: provider)
                if self.pendingLiveTranscriptionProviders.remove(provider) != nil {
                    self.settings.setLiveTranscriptionEnabled(true, for: provider)
                }
                self.liveTranscriptionPreparation = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.pendingLiveTranscriptionProviders.remove(provider)
                self.settings.setLiveTranscriptionEnabled(false, for: provider)
                self.liveTranscriptionModelStates[provider] = .failed(
                    "The live model could not be prepared: \(error.localizedDescription)")
                self.liveTranscriptionPreparation = nil
            }
        }
    }

    private func prepareLocalModel(_ provider: TranscriptionProvider, force: Bool = false, replacing: Bool = false) {
        guard provider.isLocal else { return }
        if !force, case .ready = localModelStates[provider] { return }
        if case .downloading = localModelStates[provider] { return }
        if case .downloading = liveTranscriptionModelStates[provider] { return }
        if replacing, removeLocalModelAction == nil { return }

        guard let action = prepareLocalModelAction else {
            settings.transcriptionProvider = .groq
            let message =
                "On-device transcription is unavailable in this build. Groq is still selected."
            localTranscriptionState = .failed(message)
            localModelStates[provider] = .failed(message)
            return
        }

        localModelErrors.removeValue(forKey: provider)
        let previousState = localModelState(provider)
        let previousLiveState = liveTranscriptionModelState(provider)
        localTranscriptionState = .preparing
        localModelStates[provider] = .downloading(.fraction(0, detail: "Preparing download…"))
        localTranscriptionPreparation = Task { @MainActor [weak self] in
            guard let self else { return }
            let model = self
            do {
                let restoreLive = self.settings.liveTranscriptionEnabled(for: provider)
                    || self.requestedLiveModelUpgrades.contains(provider)
                if replacing {
                    try await self.removeLocalModelAction?(provider)
                    self.localModelInstalledBytes.removeValue(forKey: provider)
                    self.localModelInstalledVersions.removeValue(forKey: provider)
                    self.liveTranscriptionModelStates[provider] = .notDownloaded
                }
                try await action(provider) { progress in
                    Task { @MainActor in
                        model.localModelStates[provider] = .downloading(progress)
                    }
                }
                guard !Task.isCancelled else { return }
                if replacing, restoreLive, let prepareLive = self.prepareLiveTranscriptionModelAction,
                   case .additionalDownload = provider.liveTranscriptionCapability {
                    try await prepareLive(provider) { progress in
                        Task { @MainActor in
                            model.localModelStates[provider] = .downloading(progress)
                        }
                    }
                    self.liveTranscriptionModelStates[provider] = .ready(updateAvailable: false)
                }
                self.requestedLiveModelUpgrades.remove(provider)
                self.localTranscriptionState = .ready
                self.localModelStates[provider] = .ready(updateAvailable: false)
                self.refreshInstalledBytes(for: provider)
                self.localTranscriptionPreparation = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.localModelErrors[provider] = error.localizedDescription
                if error is LocalModelBusyError {
                    self.localModelStates[provider] = previousState
                    self.liveTranscriptionModelStates[provider] = previousLiveState
                    self.localTranscriptionState = .failed(error.localizedDescription)
                    self.localTranscriptionPreparation = nil
                    return
                }
                if self.settings.transcriptionProvider == provider {
                    self.settings.transcriptionProvider = .groq
                }
                let message = "The local model could not be prepared: \(error.localizedDescription) "
                    + "Groq is still selected."
                self.localTranscriptionState = .failed(message)
                self.localModelStates[provider] = .failed(message)
                self.localTranscriptionPreparation = nil
            }
        }
    }

    func setTranscriptionModel(_ model: WhisperModel) {
        settings.transcriptionModel = model.rawValue
    }

    func setTranscriptionLanguage(_ code: String) {
        settings.transcriptionLanguage = code
    }

    func setLowLatencySegmentation(_ enabled: Bool) {
        settings.lowLatencySegmentation = enabled
    }

    /// Shown under the sections whose settings are stored but not yet consumed.
    var unwiredNotice: String? {
        Self.pipelineReadsCaptureSettings
            ? nil
            : "Saved, but the dictation pipeline does not read these yet — they take effect once "
                + "AppComposition passes them through (docs/wiring/task25-wiring.md)."
    }

    // MARK: - Transcription key

    /// The one door the Groq key goes through. It writes to the Keychain via the
    /// injected store inside `GroqKeyFieldModel` and to nothing else — in particular,
    /// never to `UserDefaults`, which `SettingsViewModelTests` asserts by scanning the
    /// whole defaults domain for anything key-shaped.
    func saveGroqKey() {
        keyModel.save()
    }

    func saveOpenRouterKey() {
        openRouterKeyModel?.save()
    }

    // MARK: - Permissions

    var permissions: [Prerequisite] {
        firstRun.prerequisites
    }

    /// Re-reads live status. Externally driven — from `viewDidAppear` and from the
    /// composition root's `didBecomeActive` sink. There is deliberately no timer.
    func refreshPermissions() {
        firstRun.refresh()
    }

    func requestPermission(_ kind: Prerequisite.Kind) {
        firstRun.request(kind)
    }

    // MARK: - About

    /// This calendar month's provider spend, from the append-only record log.
    ///
    /// Real data or nothing: if the log cannot be read the row says so rather than
    /// showing a zero that looks like a fact.
    func loadSpend() async {
        do {
            let records = try await loadRecords()
            let reference = now()
            let thisMonth = records.filter {
                calendar.isDate($0.startedAt, equalTo: reference, toGranularity: .month)
            }
            spendUnknownCostCount = thisMonth.reduce(0) {
                $0 + $1.unknownTrackedCostCount
            }
            spend = .amount(usd: thisMonth.reduce(0) { $0 + $1.totalTrackedCostUSD },
                            dictations: thisMonth.count)
        } catch {
            spendUnknownCostCount = 0
            spend = .unavailable("The dictation log could not be read, so spend is unknown.")
        }
    }

    /// Rebuilds the model-picker's rolling 30-day telemetry from the same durable
    /// records as Stats. Legacy rows remain unattributed rather than being guessed
    /// from a zero-dollar cost.
    func loadUsageStats() async {
        do {
            let records = try await loadRecords()
            let reference = now()
            let today = calendar.startOfDay(for: reference)
            guard let start = calendar.date(byAdding: .day, value: -29, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: today)
            else {
                localModelUsageByProvider = [:]
                localModelUsageAvailable = false
                return
            }
            let recent = records.filter { $0.startedAt >= start && $0.startedAt < end }
            localModelUsageByProvider = Dictionary(uniqueKeysWithValues:
                TranscriptionProvider.allCases.filter(\.isLocal).map { provider in
                    (provider, LocalModelUsageAggregator.summarize(recent, provider: provider))
                })
            let legacy = recent.filter { record in
                let entries = record.usageEntries ?? []
                return !entries.contains(where: { $0.stage == .transcription })
                    && (record.speakingDuration > 0 || record.rawWordCount > 0)
            }
            unattributedLegacyDictationCount = legacy.count
            unattributedLegacyWords = legacy.reduce(0) { $0 + $1.rawWordCount }
            unattributedLegacyAudioSeconds = legacy.reduce(0) { $0 + $1.speakingDuration }
            localModelUsageAvailable = true
        } catch {
            localModelUsageByProvider = [:]
            localModelUsageAvailable = false
            unattributedLegacyDictationCount = 0
            unattributedLegacyWords = 0
            unattributedLegacyAudioSeconds = 0
        }
    }

    /// `nonisolated` because these are default arguments to `init`, which is evaluated
    /// outside the actor — the same constraint `GroqKeyFieldModel` documents. Both are
    /// plain `String`, so this is free. An em dash rather than a fabricated "1.0": the
    /// About row shows what the bundle says or admits it does not know.
    nonisolated static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    nonisolated static var bundleBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

// MARK: - Slot addressing

private extension HotkeyBindings {
    subscript(slot: SettingsViewModel.ShortcutSlot) -> KeyCombo? {
        get {
            switch slot {
            case .pushToTalkChord: return pushToTalk.chordCombo
            case .toggleDictation: return toggleDictation
            case .toggleThought: return toggleThought
            case .showHistoryPalette: return showHistoryPalette
            }
        }
        set {
            switch slot {
            // Clearing the chord turns push-to-talk OFF rather than silently falling back
            // to Right ⌥: the picker is the control that chooses a modifier key, and a
            // clear that quietly rebound the feature to a different key would be a
            // shortcut the user did not ask for.
            case .pushToTalkChord:
                pushToTalk = newValue.map { PushToTalkBinding.chord($0) } ?? .disabled
            case .toggleDictation: toggleDictation = newValue
            case .toggleThought: toggleThought = newValue
            case .showHistoryPalette: showHistoryPalette = newValue
            }
        }
    }
}
