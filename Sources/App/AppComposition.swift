import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Delivers Home's one-shot "run the typing test" route after the Stats pane exists.
/// The request is an increasing id rather than a Bool, so later requests cannot be
/// mistaken for an already-handled presentation when SwiftUI rebuilds the pane.
private struct RoutedStatsView: View {
    let model: StatsViewModel
    @ObservedObject var navigation: MainWindowNavigation

    var body: some View {
        StatsView(model: model)
            .task(id: navigation.typingTestRequestID) {
                guard navigation.consumeTypingTestRequest() else { return }
                model.startTypingTest()
            }
    }
}

/// Owns every object in the app and the wiring between them. Built once at launch.
///
/// Everything the user can see hangs off one published phase: the capsule HUD reads it
/// for what to say, the menu bar for its icon and menu, and `HotkeyManager` for whether
/// Esc and ⏎ are registered. There is no second source of truth about what the app is
/// doing, and nothing here polls.
@MainActor
final class AppComposition {
    let settings = AppSettings()
    let hotkeys = HotkeyManager()
    let inserter = Inserter()
    private lazy var recentClipboard = RecentClipboard(enabled: { [weak self] in
        guard let self else { return false }
        return self.settings.contextEnabled && self.modeStore.modes.contains {
            $0.usesModePrompt && $0.includeClipboardContext
        }
    })

    private let engine = AudioEngine()
    private let audioDirectory: URL
    private let recordLog: DictationRecordLog

    private(set) var pipeline: DictationPipeline!
    private lazy var diagnosticsRunner = DiagnosticsRunner(engine: engine)
    private var diagnosticsWindow: DiagnosticsWindowController?

    private var cancellables: Set<AnyCancellable> = []
    private var captureEdgeTail: Task<Void, Never>?
    private var resourceSampleTail: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    private lazy var capsule = CapsuleController(hotkeys: hotkeys)

    /// Both read their own toggles, so neither needs re-wiring when Settings changes.
    /// Media pause ships off by default on purpose — see `docs/wiring/task27-wiring.md`:
    /// pausing the music is the opposite of what echo cancellation exists to prove.
    /// The mode/vocabulary/replacement surface the pipeline transforms through.
    private lazy var codexIntegration = CodexIntegration(settings: settings)
    private lazy var refinementClient = RoutingRefinementClient(configuration: { [settings] in
        await MainActor.run {
            CodexConfiguration(enabled: settings.codexCLIEnabled, executablePath: settings.codexExecutablePath)
        }
    })
    private let localTranscriptionRuntime = FluidAudioTranscriptionRuntime.shared
    private let moonshineTranscriptionRuntime = MoonshineTranscriptionRuntime.shared
    private let ultraTranscriptionRuntime = UltraTranscriptionRuntime.shared
    private let phononTranscriptionRuntime = PhononTranscriptionRuntime.shared

    private lazy var media = MediaController(
        isEnabled: { [settings] in settings.pauseMediaDuringRecording })
    let recordingVolume = RecordingVolumeController()

    private lazy var sounds = SoundFeedback(
        isEnabled: { [settings] in settings.soundFeedback },
        volume: { [settings] in settings.soundFeedbackVolume })

    /// `holdsMicrophone` is true for BOTH `arming` and `recording`, so a start sound
    /// driven off the raw value would fire twice per capture. `MediaController` keeps
    /// its own transition memory; the sounds need this one flag.
    private var wasHoldingMicrophone = false

    // MARK: First run and the menu bar

    private let groqKeyStore = KeychainGroqKeyStore()
    private let openRouterKeyStore = KeychainOpenRouterKeyStore()
    private lazy var firstRun = FirstRunController(
        keyStore: groqKeyStore,
        openRouterKeyStore: openRouterKeyStore,
        microphone: SystemMicrophonePermission(),
        accessibility: inserter,
        inputMonitoring: SystemInputMonitoringPermission(),
        requiresGroqKey: { [weak self] in
            guard let self else { return true }
            if self.settings.transcriptionProvider == .groq { return true }
            return self.automaticModesUse(.groq)
        },
        requiresOpenRouterKey: { [weak self] in
            self?.automaticModesUse(.openRouter) ?? true
        })
    private lazy var groqKeyModel = GroqKeyFieldModel(store: groqKeyStore)
    private lazy var openRouterKeyModel = ProviderKeyFieldModel(
        provider: .openRouter,
        read: { [openRouterKeyStore] in openRouterKeyStore.openRouterKey() },
        write: { [openRouterKeyStore] in openRouterKeyStore.setOpenRouterKey($0) })
    private lazy var firstRunWindow = FirstRunWindowController(
        controller: firstRun,
        keyModel: groqKeyModel,
        openRouterKeyModel: openRouterKeyModel)
    private var menuBar: MenuBarController?

    /// Only modes that can be selected automatically are setup prerequisites.
    /// A manually chosen mode may ask for its provider later, but a default or
    /// per-app mode must not silently skip on the user's first dictation.
    private func automaticModesUse(_ provider: RefinementProviderID) -> Bool {
        modeStore.automaticModesUse(provider)
    }

    // MARK: Stores the interface reads (Tasks 22-25)

    /// One instance each, shared by every screen. Two `VocabularyStore`s over the same
    /// file would disagree the moment one of them saved — the same trap the Groq key
    /// model has, for the same reason.
    /// When this process actually began, from the kernel.
    ///
    /// Asked of `sysctl` rather than stamped in code, because every in-app stamp happens
    /// after `main` has already run — dyld, framework load and Swift static init all
    /// land before the first line this app controls, and those are precisely what the
    /// §15 "cold launch to menu-bar ready < 400 ms" budget is about. A stamp taken in
    /// `applicationDidFinishLaunching` would measure the last few milliseconds of launch
    /// and report them as the whole of it.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970:
                        Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }()

    /// Local-only telemetry: resource samples, how each run ended, and why. Nothing in
    /// here leaves the machine (spec §16).
    let health = SessionHealthLog(directory: AppPaths.supportDirectory())

    private lazy var modeStore = ModeStore(directory: AppPaths.supportDirectory(),
        legacyCleanCleanupChoice: settings.legacyCleanCleanupChoice)
    private lazy var typingBaselines = TypingBaselineStore()
    private lazy var vocabularyStore = VocabularyStore(
        directory: AppPaths.supportDirectory(),
        seedIfEmpty: VocabularyStore.starterTerms)
    private lazy var replacementStore = ReplacementStore(
        directory: AppPaths.supportDirectory())

    // MARK: Settings (Task 25)

    /// Deliberately shares `groqKeyModel` with the first-run checklist. Two
    /// `GroqKeyFieldModel`s over the same Keychain item disagree about `hasStoredKey`
    /// the moment one of them saves, so the checklist would still read "not done"
    /// after Settings had accepted a key.
    private lazy var settingsModel = SettingsViewModel(
        settings: settings,
        hotkeys: hotkeys,
        firstRun: firstRun,
        keyModel: groqKeyModel,
        openRouterKeyModel: openRouterKeyModel,
        // Never a second AudioEngine: it would fight the capture path for the device.
        availableDevices: { [engine] in engine.availableInputDevices() },
        loadRecords: { [recordLog] in try await recordLog.all() },
        resetHUDPosition: { CapsulePositionStore().clear() },
        applyAppearance: { NSApp.appearance = Self.appearance(for: $0) },
        openDiagnostics: { [weak self] in self?.showDiagnostics() },
        cleanupCoordinator: LocalCleanupCoordinator.shared,
        prepareLocalModel: { [localTranscriptionRuntime, moonshineTranscriptionRuntime, ultraTranscriptionRuntime, phononTranscriptionRuntime]
            provider, progress in
            switch provider {
            case .groq: return
            case .localUnified:
                try await localTranscriptionRuntime.prepare(progress: progress)
            case .localUltra:
                try await ultraTranscriptionRuntime.prepare(progress: progress)
            case .localPhonon:
                try await phononTranscriptionRuntime.prepare(progress: progress)
            case .localMoonshine:
                try await moonshineTranscriptionRuntime.prepare(progress: progress)
            }
        },
        localModelAvailability: { [localTranscriptionRuntime, moonshineTranscriptionRuntime, ultraTranscriptionRuntime, phononTranscriptionRuntime]
            provider in
            switch provider {
            case .groq:
                return LocalModelAvailability(isDownloaded: false, updateAvailable: false)
            case .localUnified:
                return await localTranscriptionRuntime.availability()
            case .localUltra:
                return await ultraTranscriptionRuntime.availability()
            case .localPhonon:
                return await phononTranscriptionRuntime.availability()
            case .localMoonshine:
                return await moonshineTranscriptionRuntime.availability()
            }
        },
        removeLocalModel: { [localTranscriptionRuntime, moonshineTranscriptionRuntime, ultraTranscriptionRuntime, phononTranscriptionRuntime]
            provider in
            switch provider {
            case .groq: return
            case .localUnified:
                try await localTranscriptionRuntime.removeModel()
            case .localUltra:
                try await ultraTranscriptionRuntime.removeModel()
            case .localPhonon:
                try await phononTranscriptionRuntime.removeModel()
            case .localMoonshine:
                try await moonshineTranscriptionRuntime.removeModel()
            }
        },
        prepareLiveTranscriptionModel: { [localTranscriptionRuntime] provider, progress in
            guard provider == .localUnified else { return }
            try await localTranscriptionRuntime.prepareStreaming(progress: progress)
        },
        liveTranscriptionModelAvailability: { [localTranscriptionRuntime] provider in
            guard provider == .localUnified else {
                return LocalModelAvailability(isDownloaded: true, updateAvailable: false)
            }
            return await localTranscriptionRuntime.streamingAvailability()
        },
        // Deliberately not caught: a sweep or a delete that failed must reach the user,
        // and "0 bytes" beside a Delete-all button is a claim, not a placeholder.
        retentionSweep: { [retention] in try await retention.sweepNow() },
        audioDiskUsage: { [retention] in try await retention.diskUsageBytes() },
        deleteAllAudio: { [retention] in try await retention.deleteAllAudio() })
    // MARK: The main window (Task 21)

    private lazy var mainNavigation = MainWindowNavigation()

    /// Built lazily and released on close (spec §15 idle-memory budget). The view models
    /// are constructed INSIDE the pane closures deliberately: one captured from here
    /// would outlive the window and quietly defeat the release, while every test still
    /// passed.
    private lazy var mainWindow = MainWindowPresenter { [weak self] onClose in
        MainWindowController(panes: self?.panes() ?? SidebarView.Panes(home: { AnyView(EmptyView()) }),
                             navigation: self?.mainNavigation ?? MainWindowNavigation(),
                             onClose: onClose)
    }

    func openMainWindow(_ tab: SidebarView.Tab) {
        mainNavigation.show(tab)
        mainWindow.open()
    }

    private func openTypingTest() {
        mainNavigation.startTypingTest()
        mainWindow.open()
    }

    private func panes() -> SidebarView.Panes {
        SidebarView.Panes(
            home: { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                let model = HomeViewModel(
                    loadRecords: { [recordLog] in try await recordLog.all() },
                    baselineWPM: { [typingBaselines] in typingBaselines.baselineWPM },
                    resolveMode: { [modeStore] id in
                        modeStore.mode(id: id).map { ModeBadge(name: $0.name, symbol: $0.symbol) }
                    },
                    actions: HomeActions(
                        // Both routes land in the same place: Stats owns the test, and
                        // two entry points running two sessions would let a user score
                        // twice against one minute.
                        startTypingTest: { [weak self] in self?.openTypingTest() },
                        showFullStats: { [weak self] in self?.openMainWindow(.stats) }))
                self.home = model
                Task { await model.refresh() }
                return AnyView(HomeView(model: model))
            },
            stats: { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                let model = StatsViewModel(
                    loadRecords: { [recordLog] in try await recordLog.all() },
                    readBaseline: { [typingBaselines] in typingBaselines.baseline },
                    resolveMode: { [modeStore] id in
                        modeStore.mode(id: id).map { ModeBadge(name: $0.name, symbol: $0.symbol) }
                    },
                    makeTypingTestSession: { [typingBaselines] in
                        TypingTestSession.live(store: typingBaselines)
                    },
                    loadSessions: { [health] in await health.sessions() })
                self.stats = model
                Task { await model.refresh() }
                return AnyView(RoutedStatsView(model: model, navigation: self.mainNavigation))
            },
            history: { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(HistoryView(viewModel: self.makeHistoryModel()))
            },
            modes: { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                let previewRunner = ModePreviewRunner(
                    refinement: self.refinementClient,
                    apiKey: { [weak self] provider in
                        switch provider {
                        case .groq: return self?.settings.groqAPIKey
                        case .openRouter: return self?.settings.openRouterAPIKey
                        case .codexCLI: return nil
                        }
                    },
                    vocabularyTerms: { [weak self] in self?.vocabularyStore.terms ?? [] },
                    clipboard: { nil },
                    contextEnabled: { [settings = self.settings] in settings.contextEnabled },
                    localCleanup: LocalCleanupCoordinator.shared)
                let model = ModesViewModel(store: self.modeStore,
                                           globalBindings: self.settings.hotkeyBindings,
                                           lastDictation: { [recordLog] in
                                               guard let records = try? await recordLog.all(),
                                                     let record = records.last(where: {
                                                         !$0.rawText.trimmingCharacters(
                                                             in: .whitespacesAndNewlines).isEmpty
                                                     })
                                               else { return nil }
                                               return ModePreviewSource(
                                                   rawText: record.rawText,
                                                   targetAppName: record.targetAppName)
                                           },
                                           preview: { mode, source in
                                               await previewRunner.run(mode: mode, source: source)
                                           },
                                           modesAffectPipeline: true,
                                           codex: self.codexIntegration,
                                           localCleanupAvailability: { await LocalCleanupCoordinator.shared.availability($0) })
                model.openCleanupSettings = { [weak self] in self?.openMainWindow(.settings) }
                model.modesDidChange = { [weak self] in
                    self?.firstRun.refresh()
                    self?.prewarmDefaultCleanup()
                }
                model.suspendGlobalHotkeys = { [weak self] suspended in
                    suspended ? self?.hotkeys.suspend() : self?.hotkeys.resume()
                }
                return AnyView(ModesView(model: model))
            },
            vocabulary: { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(VocabularyView(model: VocabularyViewModel(
                    vocabulary: self.vocabularyStore,
                    replacements: self.replacementStore)))
            },
            settings: { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(SettingsView(model: self.settingsModel,
                                            settings: self.settings,
                                            permissions: self.firstRun,
                                            codex: self.codexIntegration,
                                            availableModes: { [modeStore = self.modeStore] in modeStore.modes }))
            })
    }

    /// Home lives as long as its pane does; the phase sink refreshes it weakly so a
    /// closed window is not kept alive by a subscription.
    private weak var home: HomeViewModel?
    private weak var stats: StatsViewModel?

    /// The app the user was working in before they opened a Captur window.
    ///
    /// Sampling the frontmost app when History asks would answer "Captur" — opening the
    /// window is what made it frontmost. Tracked from activation notifications instead,
    /// ignoring this app, so re-insert targets where the words were meant to go.
    private var lastForegroundTarget: HistoryViewModel.Target?

    private func makeHistoryModel() -> HistoryViewModel {
        HistoryViewModel(
            records: { [recordLog] in try await recordLog.all() },
            deleteRecord: { [recordLog] id in try await recordLog.delete(id: id) },
            modeName: { [modeStore] id in modeStore.mode(id: id)?.name ?? id },
            copyText: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            reinsert: { [weak self] text, target in
                // Re-insertion goes back to the app the user was in when they opened
                // History, not to History itself.
                if let bundleID = target?.bundleID,
                   let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleID).first {
                    app.activate()
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
                _ = await self?.inserter.insert(text)
            },
            retryTranscription: { [weak self] id in await self?.pipeline.retry(recordID: id) },
            retryMode: { [weak self] id in await self?.pipeline.retryMode(recordID: id) },
            audioURL: { [audioDirectory] name in
                let url = audioDirectory.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            },
            player: HistoryAudioPlayer(),
            frontmostTarget: { [weak self] in self?.lastForegroundTarget })
    }

    // MARK: Retention (Task 20)

    /// The policy closure is re-read on every sweep, so changing it in Settings takes
    /// effect on the next sweep without re-wiring anything.
    private lazy var retention = RetentionSweepRunner(
        records: recordLog,
        audioDirectory: audioDirectory,
        remover: FileManagerRemover(),
        scheduler: DailyDispatchTimer(),
        policy: { AppSettings.retentionPolicy() })

    /// The push-to-talk key's own view of what it started, so a tap can latch and the
    /// next tap can end it.
    private var latch = PushToTalkLatch()

    private enum CaptureEdge {
        case begin(CaptureTrigger)
        /// A latched recording: starts if idle, ends if already running.
        case latch(CaptureTrigger)
        case end
        case cancel
    }

    init() {
        let support = AppPaths.supportDirectory()
        audioDirectory = support.appendingPathComponent("audio", isDirectory: true)
        recordLog = DictationRecordLog(fileURL: support.appendingPathComponent("records.jsonl"))

        let settings = self.settings
        let audioDirectory = self.audioDirectory
        let planner = SegmentPlanner()
        let localTranscriptionRuntime = self.localTranscriptionRuntime

        pipeline = DictationPipeline(
            audioEngine: engine,
            makeRecorder: {
                SegmentRecorder(
                    directory: audioDirectory,
                    planner: SegmentPlanner(config: SegmentPlannerConfig(
                        enabled: settings.lowLatencySegmentation)),
                    makeVAD: {
                        VoiceActivityDetector(config: .dictation(
                            VADSensitivity(rawValue: settings.dictationSensitivity) ?? .normal))
                    },
                    // A missing canonical format would mean AVFoundation refused the
                    // one format this app is built around; the recorder then fails to
                    // open a writer and the capture reports that instead of pretending.
                    makeWriter: { url in
                        guard let format = AudioFormatConverter.canonicalOutputFormat else {
                            throw AudioEngineError.fileFinalizationFailed(
                                "The 16 kHz mono output format is unavailable.")
                        }
                        return try FLACWriter(url: url, format: format)
                    })
            },
            makeTranscriber: { [settings, localTranscriptionRuntime, moonshineTranscriptionRuntime, ultraTranscriptionRuntime, phononTranscriptionRuntime] in
                switch settings.transcriptionProvider {
                case .groq:
                    return GroqTranscriber()
                case .localUnified:
                    return LocalUnifiedTranscriber(
                        runtime: localTranscriptionRuntime,
                        retranscribeFinalWithBatch: settings.retranscribeFinalWithBatch,
                        vocabularyBoostingEnabled: settings.speechVocabularyEnabled && settings.parakeetVocabularyBoosting)
                case .localUltra:
                    return LocalUnifiedTranscriber(
                        runtime: ultraTranscriptionRuntime,
                        vocabularyBoostingEnabled: settings.speechVocabularyEnabled && settings.parakeetVocabularyBoosting)
                case .localMoonshine:
                    return LocalMoonshineTranscriber(runtime: moonshineTranscriptionRuntime)
                case .localPhonon:
                    return LocalUnifiedTranscriber(runtime: phononTranscriptionRuntime,
                        retranscribeFinalWithBatch: false, vocabularyBoostingEnabled: false)
                }
            },
            planner: planner,
            inserter: inserter,
            recordLog: recordLog,
            sessionDirectory: audioDirectory,
            apiKey: { settings.groqAPIKey ?? "" },
            micPolicy: { settings.micPolicy },
            availableModes: { [modeStore] in modeStore.modes },
            configurationProvider: { [settings, modeStore] in
                DictationPipeline.Configuration(
                    speechVocabularyEnabled: settings.speechVocabularyEnabled,
                    parakeetVocabularyBoosting: settings.parakeetVocabularyBoosting,
                    transcriptionModel: settings.transcriptionModel,
                    transcriptionProvider: settings.transcriptionProvider,
                    liveTranscriptionEnabled: settings.liveTranscriptionEnabled(
                        for: settings.transcriptionProvider),
                    retranscribeFinalWithBatch: settings.retranscribeFinalWithBatch,
                    language: settings.transcriptionLanguage.isEmpty
                        ? nil : settings.transcriptionLanguage,
                    repairSeams: settings.lowLatencySegmentation,
                    voiceProcessing: settings.captureVoiceProcessing,
                    defaultModeID: modeStore.defaultModeID)
            },
            neverStoreAudio: { [settings] in settings.neverStoreAudio },
            modes: ModeServices(
                refinement: refinementClient,
                localCleanup: LocalCleanupCoordinator.shared,
                prewarmLocalCleanup: { choice in
                    Task(priority: .utility) { try? await LocalCleanupCoordinator.shared.prepare(choice) }
                },
                refinementAPIKey: { [settings] provider in
                    switch provider {
                    case .groq: return settings.groqAPIKey
                    case .openRouter: return settings.openRouterAPIKey
                    case .codexCLI: return nil
                    }
                },
                contextEnabled: { [settings] in settings.contextEnabled },
                contextSnapshot: { bundleID, request in ContextCollector.start(bundleID: bundleID, request: request) },
                perWebsiteMap: { [settings] in settings.websiteActivation ? settings.websiteModes : [:] },
                clipboardBeforeWebsiteResolution: { [settings] in settings.clipboardBeforeWebsiteResolution },
                clipboardStartReader: { [weak self] in
                    guard let self else { return { nil } }
                    return self.recentClipboard.startReader(recentOnly: self.settings.recentClipboardOnly)
                },
                clipboardEndReader: { [weak self] startedAt in
                    guard let self, self.settings.clipboardDuringRecording else { return { .unchanged } }
                    return self.recentClipboard.endReader(since: startedAt)
                },
                saveContextMetadata: { [settings] in settings.storeContextMetadata },
                perAppModeMap: { [modeStore] in modeStore.perAppMap },
                vocabulary: { [vocabularyStore] in vocabularyStore.terms },
                saveVocabulary: { [vocabularyStore] in vocabularyStore.replaceAll($0) },
                replacements: { [replacementStore] in replacementStore.replacements },
                // Read only when the mode asks for it: reading the clipboard is the
                // privacy-relevant act, not sending it.
                clipboard: { NSPasteboard.general.string(forType: .string) },
                hotkeyBindings: { [settings] in settings.hotkeyBindings },
                modeDigits: hotkeys))
    }

    private func prewarmDefaultCleanup() {
        guard let mode = modeStore.mode(id: modeStore.defaultModeID), mode.usesLocalCleanup else { return }
        Task(priority: .utility) { try? await LocalCleanupCoordinator.shared.prepare(mode.cleanupChoice) }
    }

    func start() {
        prewarmDefaultCleanup()
        recentClipboard.start()
        if settings.speechVocabularyEnabled, settings.parakeetVocabularyBoosting,
           settings.transcriptionProvider.supportsAcousticVocabularyBoosting, ParakeetVocabularyBooster.isDownloaded {
            Task(priority: .utility) { try? await ParakeetVocabularyBooster.shared.prepare(allowDownload: false) }
        }
        // Before any window exists, so nothing is drawn in the wrong appearance first.
        NSApp.appearance = Self.appearance(for: settings.appearance)

        switch settings.transcriptionProvider {
        case .groq:
            break
        case .localUnified:
            let runtime = self.localTranscriptionRuntime
            let liveEnabled = settings.liveTranscriptionEnabled(for: .localUnified)
            Task(priority: .utility) {
                if (await runtime.availability()).isDownloaded {
                    try? await runtime.prepare()
                }
                if liveEnabled, (await runtime.streamingAvailability()).isDownloaded {
                    try? await runtime.prepareStreaming()
                }
            }
        case .localUltra:
            let runtime = self.ultraTranscriptionRuntime
            Task(priority: .utility) {
                if (await runtime.availability()).isDownloaded {
                    try? await runtime.prepare()
                }
            }
        case .localPhonon:
            let runtime = self.phononTranscriptionRuntime
            Task(priority: .utility) {
                if (await runtime.availability()).isDownloaded { try? await runtime.prepare() }
            }
        case .localMoonshine:
            let runtime = self.moonshineTranscriptionRuntime
            Task(priority: .utility) {
                if (await runtime.availability()).isDownloaded {
                    try? await runtime.prepare()
                }
            }
        }

        wireHotkeys()
        buildMenuBar()
        observePhase()
        observeActivation()

        // Opens this run's health record and settles the previous one — a marker file
        // left behind means the last run was killed or crashed, and the matching macOS
        // crash report is read for the reason. Sampled here rather than on a timer: §15
        // budgets idle CPU at ≈ 0% with no polling anywhere, so every reading is taken at
        // a moment the app is awake for regardless.
        let launchMs = Int(Date().timeIntervalSince(Self.processStart) * 1000)
        Task { [health] in
            await health.beginSession(appVersion: SettingsViewModel.bundleVersion,
                                      build: SettingsViewModel.bundleBuild,
                                      launchMs: launchMs)
        }

        // Spec §16: audio is purged at launch and once a day. `start()` is idempotent
        // and never throws; a launch sweep that fails logs and leaves the daily one
        // armed, because that is the sweep that will still be running in a month.
        Task { await retention.start() }

        // Spec §10.6: permissions are asked for here, deliberately, and never in the
        // middle of someone's first dictation.
        if firstRun.shouldPresentAtLaunch {
            firstRunWindow.present()
        }
    }

    // MARK: Hotkeys

    private func wireHotkeys() {
        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            // A monotonic clock: the tap window must not be decided by a wall clock
            // that NTP can step underneath it.
            let now = ProcessInfo.processInfo.systemUptime
            switch action {
            case .pushToTalkDown:
                switch self.latch.down(at: now) {
                case .start: self.serializeCaptureEdge(.begin(.pushToTalk))
                case .stop: self.serializeCaptureEdge(.end)
                case .none: break
                }
            case .pushToTalkUp:
                if case .stop = self.latch.up(at: now) {
                    self.serializeCaptureEdge(.end)
                }
            case .toggleDictation:
                self.latch.reset()
                self.serializeCaptureEdge(.latch(.toggle))
            case .toggleThought:
                // Parked behind FeatureFlags.thoughtCapture, which also stops the
                // binding being registered at all — this is the belt to that braces.
                break
            case .showHistoryPalette:
                self.openMainWindow(.history)
            case .cancelCapture:
                self.latch.reset()
                self.serializeCaptureEdge(.cancel)
            case .endCapture:
                // ⏎ ends a latched recording (spec §4.1). It goes through the same
                // serialized edge as every other ending, or the down/up ordering the
                // latch depends on stops holding.
                self.latch.reset()
                self.serializeCaptureEdge(.end)
            case .retryLast:
                self.retryLastRecord()
            }
        }

        var bindings = settings.hotkeyBindings
        if !FeatureFlags.thoughtCapture {
            bindings.toggleThought = nil
        }
        // Spec §17: always say what happened. A combo the system already owns is now
        // an error rather than a silent no-op (see `HotkeyManager.onRegistrationFailure`),
        // and at launch there is no UI in front of the user to catch it — so it goes to
        // the capsule, the same surface every other failure uses.
        hotkeys.onRegistrationFailure = { [weak self] action, error in
            self?.capsule.present(notice: .warning(text: Self.warningText(action, error)))
        }
        do {
            try hotkeys.apply(bindings)
        } catch {
            capsule.present(notice: .warning(text: Self.warningText(.toggleDictation, error)))
        }
    }

    /// All capture hotkey edges join the preceding edge before inspecting phase.
    /// This preserves down/up/down ordering even when an end edge suspends while
    /// joining microphone startup.
    private func serializeCaptureEdge(_ edge: CaptureEdge) {
        let previous = captureEdgeTail
        captureEdgeTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            switch edge {
            case .begin(let trigger):
                await self.pipeline.begin(trigger: trigger)
            case .latch(let trigger):
                if self.pipeline.phase.holdsMicrophone {
                    await self.pipeline.end()
                } else {
                    await self.pipeline.begin(trigger: trigger)
                }
            case .end:
                await self.pipeline.end()
            case .cancel:
                await self.pipeline.cancel()
            }
        }
    }

    /// ⌘R from the error capsule. Not a capture edge — it never touches the
    /// microphone — so it stays off the edge queue; `retry` refuses outright if a
    /// recording is live.
    private func retryLastRecord() {
        guard let id = pipeline.lastConcludedRecordID else { return }
        capsule.dismiss()
        retryTask = Task { @MainActor [weak self] in
            await self?.pipeline.retry(recordID: id)
        }
    }

    // MARK: Menu bar

    /// `MenuBarController` never sees the pipeline: every command leaves through a
    /// closure and the phase arrives through one publisher. That is what lets the
    /// commands here stay identical to the hotkey ones — same latch reset, same
    /// serialized edge — instead of a second, subtly different path to `end()`.
    private func buildMenuBar() {
        let controller = MenuBarController(actions: .init(
            startDictation: { [weak self] in self?.beginFromMenu() },
            stopDictation: { [weak self] in self?.endFromMenu() },
            cancelDictation: { [weak self] in self?.cancelFromMenu() },
            showHistory: { [weak self] in self?.openMainWindow(.history) },
            showSettings: { [weak self] in self?.openMainWindow(.settings) },
            showDiagnostics: { [weak self] in self?.showDiagnostics() },
            showSetup: { [weak self] in self?.firstRunWindow.present() },
            needsSetup: { [weak self] in self?.firstRun.needsSetup ?? false },
            showOverview: { [weak self] in self?.openMainWindow(.home) }),
            modeSymbol: { [weak self] _ in
                guard let self, let id = self.pipeline.activeModeID else {
                    return "waveform.circle.fill"
                }
                return self.modeStore.mode(id: id)?.symbol ?? "waveform.circle.fill"
            })
        controller.install()
        controller.observe(pipeline.$phase)
        menuBar = controller
        firstRun.$prerequisites
            .map { $0.contains { !$0.isSatisfied } }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak controller] _ in controller?.refreshMenu() }
            .store(in: &cancellables)
    }

    private func beginFromMenu() {
        latch.reset()
        serializeCaptureEdge(.begin(.menuBar))
    }

    private func endFromMenu() {
        latch.reset()
        serializeCaptureEdge(.end)
    }

    private func cancelFromMenu() {
        latch.reset()
        serializeCaptureEdge(.cancel)
    }

    private func showDiagnostics() {
        if diagnosticsWindow == nil {
            diagnosticsWindow = DiagnosticsWindowController(runner: diagnosticsRunner)
        }
        diagnosticsWindow?.present()
    }

    // MARK: Phase observation → HUD + capture-key gating

    /// The menu bar is deliberately **not** driven from this sink — it holds its own
    /// subscription (`controller.observe`) so it can decide for itself when a phase
    /// change is worth rebuilding a menu for. Driving it from here as well would
    /// deliver every phase twice.
    private func observePhase() {
        // The capsule reads the meter itself; levels arrive at 30 Hz and have no
        // business going through this sink.
        capsule.attach(to: pipeline)

        pipeline.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                let holdsMicrophone = phase.holdsMicrophone
                // Registers Esc and ⏎ while the microphone is held, and — far more
                // importantly — unregisters them the instant it is not.
                self.hotkeys.setCaptureActive(holdsMicrophone)
                // A recording that ended by any other route leaves the key's latch
                // stale; clearing it here means the next tap starts rather than stops.
                if !holdsMicrophone { self.latch.reset() }
                self.capsule.update(phase: phase)

                self.recordingVolume.update(recording: phase.isRecording,
                    enabled: self.settings.lowerOutputVolumeDuringRecording,
                    pauseEnabled: self.settings.pauseMediaDuringRecording,
                    target: self.settings.recordingOutputVolume)
                self.media.update(holdsMicrophone: holdsMicrophone)
                if holdsMicrophone != self.wasHoldingMicrophone {
                    self.wasHoldingMicrophone = holdsMicrophone
                    holdsMicrophone ? self.sounds.playStart() : self.sounds.playStop()
                }

            }
            .store(in: &cancellables)

        settings.$lowerOutputVolumeDuringRecording.combineLatest(settings.$pauseMediaDuringRecording)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, pauseEnabled in
                guard let self else { return }
                self.recordingVolume.update(recording: self.pipeline.phase.isRecording,
                    enabled: enabled, pauseEnabled: pauseEnabled,
                    target: self.settings.recordingOutputVolume)
            }
            .store(in: &cancellables)

        pipeline.resourceEvents
            .sink { [weak self, health] event in
                guard let self else { return }
                let previous = self.resourceSampleTail
                self.resourceSampleTail = Task {
                    await previous?.value
                    switch event {
                    case .started(let id):
                        await health.sample(.dictationStart, captureID: id)
                    case .ended(let id):
                        await health.sample(.dictationEnd, captureID: id)
                    }
                }
            }
            .store(in: &cancellables)

        // The log changes on more than success: cancellations, failures and both retry
        // paths alter figures too. Observe the durable write, not a visual phase.
        pipeline.$recordRevision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if let home = self.home { Task { await home.refresh() } }
                if let stats = self.stats { Task { await stats.refresh() } }
                Task { await self.settingsModel.loadUsageStats() }
            }
            .store(in: &cancellables)

        // Spec §17: always say what happened. A mode that was skipped and a digit Carbon
        // refused are both things the user is entitled to know, and both are invisible
        // otherwise — the text still arrives, just untransformed.
        pipeline.$notice
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notice in
                switch notice {
                case .modeSkipped(let modeName):
                    self?.capsule.present(notice: .warning(
                        text: "\(modeName) skipped — raw text inserted"))
                case .modeDigitUnavailable(let digit):
                    self?.capsule.present(notice: .warning(
                        text: "\(digit) is taken by another app — mode not switched"))
                }
            }
            .store(in: &cancellables)
    }

    /// Permission state changes while the user is in System Settings — i.e. while
    /// Captur is in the background — so the checklist re-reads it on the way back.
    /// This is what buys the "no polling timers" rule: the one moment the answer can
    /// have changed is a moment AppKit already tells us about.
    private func observeActivation() {
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.firstRun.refresh() }
            .store(in: &cancellables)

        // Not a poll: AppKit already announces every app switch.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier
                else { return }
                self?.lastForegroundTarget = HistoryViewModel.Target(
                    bundleID: bundleID, name: app.localizedName)
            }
            .store(in: &cancellables)
    }

    // MARK: Small mappings

    /// `AppAppearance` carries no AppKit member on purpose — `AppSettings` is a value
    /// store and should not import a window system to hold three cases.
    static func appearance(for appearance: AppAppearance) -> NSAppearance? {
        switch appearance {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// One line the user can act on. Naming the shortcut matters more than naming the
    /// OSStatus: "something failed to register" is not actionable, "⌥Space is taken"
    /// is.
    static func warningText(_ action: HotkeyAction, _ error: any Error) -> String {
        let what: String
        switch action {
        case .toggleDictation: what = "The dictation shortcut"
        case .toggleThought: what = "The thought-capture shortcut"
        case .showHistoryPalette: what = "The history shortcut"
        case .cancelCapture: what = "Esc to cancel"
        case .endCapture: what = "Return to finish"
        case .retryLast: what = "⌘R to retry"
        case .pushToTalkDown, .pushToTalkUp: what = "Push-to-talk"
        }
        return "\(what) is already taken by another app — change it in Settings."
    }
}
