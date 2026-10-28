import Combine
import Foundation

/// How the app should look. `system` follows the appearance in System Settings, which
/// is the only value that is right for a menu-bar app most of the time — the other two
/// exist because a HUD that fights the user's chosen theme is worth overriding.
enum AppAppearance: String, CaseIterable, Codable, Sendable {
    case system, light, dark
}

/// Where Captur turns recorded speech into text.
///
/// Clean-up modes are a separate stage: choosing a local provider keeps the audio on
/// this Mac, while the selected mode independently chooses its text provider.
enum TranscriptionProvider: String, CaseIterable, Codable, Sendable {
    case groq
    case localUnified
    case localMoonshine
    case localUltra

    var isLocal: Bool { self != .groq }

    var supportsAcousticVocabularyBoosting: Bool {
        self == .localUnified || self == .localUltra
    }

    /// Live transcription is an engine capability, not a synonym for "local".
    /// Keeping the distinction here prevents a future batch-only model from
    /// accidentally acquiring a toggle that cannot do anything.
    var supportsLiveTranscription: Bool {
        switch self {
        case .groq, .localUltra: false
        case .localUnified, .localMoonshine: true
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var codexCLIEnabled: Bool {
        didSet { defaults.set(codexCLIEnabled, forKey: "captur.codexCLIEnabled") }
    }
    @Published var codexExecutablePath: String {
        didSet { defaults.set(codexExecutablePath, forKey: "captur.codexExecutablePath") }
    }
    private enum Key {
        static let micPolicy = "captur.micPolicy"
        static let hotkeyBindings = "captur.hotkeyBindings"
        static let dictationSensitivity = "captur.dictationSensitivity"
        static let thoughtSensitivity = "captur.thoughtSensitivity"
        static let thoughtStyle = "captur.thoughtStyle"
        static let openBrainEndpoint = "captur.openBrainEndpoint"
        // Task 25 (Settings). Nothing here is a secret: the Groq key lives in the
        // Keychain and this file must never learn how to store one.
        static let appearance = "captur.appearance"
        static let retentionPolicy = "captur.retentionPolicy"
        static let voiceProcessing = "captur.voiceProcessing"
        static let transcriptionProvider = "captur.transcriptionProvider"
        static let transcriptionModel = "captur.transcriptionModel"
        static let transcriptionLanguage = "captur.transcriptionLanguage"
        static let lowLatencySegmentation = "captur.lowLatencySegmentation"
        static let liveTranscriptionProviders = "captur.liveTranscriptionProviders"
        static let retranscribeFinalWithBatch = "captur.retranscribeFinalWithBatch"
        // Task 27 (media pause, sounds) and the Privacy section.
        static let pauseMediaDuringRecording = "captur.pauseMediaDuringRecording"
        static let lowerOutputVolumeDuringRecording = "captur.lowerOutputVolumeDuringRecording"
        static let recordingOutputVolume = "captur.recordingOutputVolume"
        static let soundFeedback = "captur.soundFeedback"
        static let soundFeedbackVolume = "captur.soundFeedbackVolume"
        static let neverStoreAudio = "captur.neverStoreAudio"
    }

    @Published var clipboardBeforeWebsiteResolution: Bool {
        didSet { defaults.set(clipboardBeforeWebsiteResolution, forKey: "captur.clipboardBeforeWebsiteResolution") }
    }
    @Published var speechVocabularyEnabled: Bool { didSet { defaults.set(speechVocabularyEnabled, forKey: "captur.speechVocabularyEnabled") } }
    @Published var parakeetVocabularyBoosting: Bool { didSet { defaults.set(parakeetVocabularyBoosting, forKey: "captur.parakeetVocabularyBoosting") } }
    @Published var contextEnabled: Bool { didSet { defaults.set(contextEnabled, forKey: "captur.contextEnabled") } }
    @Published var recentClipboardOnly: Bool { didSet { defaults.set(recentClipboardOnly, forKey: "captur.recentClipboardOnly") } }
    @Published var clipboardDuringRecording: Bool { didSet { defaults.set(clipboardDuringRecording, forKey: "captur.clipboardDuringRecording") } }
    @Published var websiteActivation: Bool { didSet { defaults.set(websiteActivation, forKey: "captur.websiteActivation") } }
    @Published var storeContextMetadata: Bool { didSet { defaults.set(storeContextMetadata, forKey: "captur.storeContextMetadata") } }
    @Published var websiteModes: [String: String] { didSet { defaults.set(websiteModes, forKey: "captur.websiteModes") } }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()

    @Published var micPolicy: MicSelectionPolicy {
        didSet { persist(micPolicy, forKey: Key.micPolicy) }
    }

    @Published var hotkeyBindings: HotkeyBindings {
        didSet { persist(hotkeyBindings, forKey: Key.hotkeyBindings) }
    }

    @Published var dictationSensitivity: String {
        didSet { defaults.set(dictationSensitivity, forKey: Key.dictationSensitivity) }
    }

    @Published var thoughtSensitivity: String {
        didSet { defaults.set(thoughtSensitivity, forKey: Key.thoughtSensitivity) }
    }

    @Published var thoughtStyle: String {
        didSet { defaults.set(thoughtStyle, forKey: Key.thoughtStyle) }
    }

    @Published var openBrainEndpoint: String {
        didSet { defaults.set(openBrainEndpoint, forKey: Key.openBrainEndpoint) }
    }

    // MARK: Task 25 — Settings

    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// How long session audio is kept (spec §16; default 30 days). Read by
    /// `RetentionSweepRunner` on **every** sweep, so a change takes effect on the next
    /// one with nothing to re-wire.
    @Published var retentionPolicy: RetentionPolicy {
        didSet { defaults.set(retentionPolicy.rawValue, forKey: Key.retentionPolicy) }
    }

    /// The same value, readable from a non-main-actor context.
    ///
    /// `RetentionSweepRunner` re-reads its policy on every sweep from inside an actor,
    /// so it cannot touch this `@MainActor` class. Reading the persisted value instead
    /// of mirroring it into a lock-protected box keeps exactly one source of truth —
    /// the `didSet` above has already written it — and `UserDefaults` is thread-safe.
    /// The key lives in one place either way.
    nonisolated static func retentionPolicy(
        from defaults: UserDefaults = .standard
    ) -> RetentionPolicy {
        RetentionPolicy(rawValue: defaults.string(forKey: Key.retentionPolicy) ?? "")
            ?? .default
    }

    /// Echo cancellation (AVAudioEngine voice processing). Spec §4.3: on by default.
    @Published var voiceProcessing: Bool {
        didSet { defaults.set(voiceProcessing, forKey: Key.voiceProcessing) }
    }

    /// Read only for the one-time migration into modes.json. Mode settings own
    /// cleanup after migration; the old preference must never override later edits.
    let legacyCleanCleanupChoice: ModeCleanupChoice

    @Published var transcriptionProvider: TranscriptionProvider {
        didSet { defaults.set(transcriptionProvider.rawValue, forKey: Key.transcriptionProvider) }
    }

    /// A Groq Whisper model id. Stored as the raw string rather than an enum so a model
    /// the app has never heard of survives a downgrade instead of silently resetting.
    @Published var transcriptionModel: String {
        didSet { defaults.set(transcriptionModel, forKey: Key.transcriptionModel) }
    }

    /// An ISO 639-1 code, or `""` for "let Whisper detect it".
    @Published var transcriptionLanguage: String {
        didSet { defaults.set(transcriptionLanguage, forKey: Key.transcriptionLanguage) }
    }

    /// Whether long dictations are cut into segments and uploaded while the user is
    /// still speaking (spec §5). Off means one upload at the end: slower, simpler.
    @Published var lowLatencySegmentation: Bool {
        didSet { defaults.set(lowLatencySegmentation, forKey: Key.lowLatencySegmentation) }
    }

    /// A per-provider preference because switching models should restore each model's
    /// last behavior. Moonshine defaults on to preserve its streaming-first behavior;
    /// Unified remains batch until its additional streaming encoder is requested.
    @Published private(set) var liveTranscriptionProviders: Set<TranscriptionProvider> {
        didSet {
            defaults.set(
                liveTranscriptionProviders.map(\.rawValue).sorted(),
                forKey: Key.liveTranscriptionProviders)
        }
    }

    /// Keep streaming text provisional, then use the complete recording for the one
    /// transcript that reaches the cursor. This currently applies to Parakeet Unified:
    /// Moonshine remains streaming-first and Groq has no live path.
    @Published var retranscribeFinalWithBatch: Bool {
        didSet { defaults.set(retranscribeFinalWithBatch, forKey: Key.retranscribeFinalWithBatch) }
    }

    // MARK: Task 27 — media, sounds, and the privacy master switch

    /// Whether a recording pauses verified playback in the active macOS Now Playing session.
    ///
    /// **Off by default, and that is a product decision rather than caution.** Echo
    /// cancellation (§4.3) exists so dictation works *while* music plays, and LV2 gates
    /// the release on the music staying audible. A default that pauses the music would
    /// make the headline feature untestable in ordinary use and quietly remove the
    /// reason AEC is there at all.
    @Published var pauseMediaDuringRecording: Bool {
        didSet { defaults.set(pauseMediaDuringRecording, forKey: Key.pauseMediaDuringRecording) }
    }

    @Published var lowerOutputVolumeDuringRecording: Bool {
        didSet { defaults.set(lowerOutputVolumeDuringRecording, forKey: Key.lowerOutputVolumeDuringRecording) }
    }

    @Published var recordingOutputVolume: Double {
        didSet { defaults.set(recordingOutputVolume, forKey: Key.recordingOutputVolume) }
    }

    /// Short start/stop sounds. Off by default: a dictation tool that beeps out of the
    /// box beeps inside whatever call the user is on.
    @Published var soundFeedback: Bool {
        didSet { defaults.set(soundFeedback, forKey: Key.soundFeedback) }
    }

    /// 0…1. Zero means *do not play*, which is why it cannot be the unset default —
    /// see `double(_:_:default:)`.
    @Published var soundFeedbackVolume: Double {
        didSet { defaults.set(soundFeedbackVolume, forKey: Key.soundFeedbackVolume) }
    }

    /// Spec §16's master switch: delete each session file the moment transcription
    /// succeeds. History keeps the text and loses playback and retry.
    ///
    /// Stored here; **the behaviour belongs to `DictationPipeline`** and is not
    /// implemented yet. Settings says so on screen rather than implying the audio has
    /// already stopped being written (`SettingsViewModel.pipelineHonoursNeverStoreAudio`).
    @Published var neverStoreAudio: Bool {
        didSet { defaults.set(neverStoreAudio, forKey: Key.neverStoreAudio) }
    }

    var groqAPIKey: String? {
        get { Keychain.apiKey() }
        set { Keychain.setAPIKey(newValue) }
    }

    var openRouterAPIKey: String? {
        get { Keychain.openRouterAPIKey() }
        set { Keychain.setOpenRouterAPIKey(newValue) }
    }

    var brainKey: String? {
        get { Keychain.brainKey() }
        set { Keychain.setBrainKey(newValue) }
    }

    init(defaults: UserDefaults = .standard) {
        codexCLIEnabled = defaults.bool(forKey: "captur.codexCLIEnabled")
        codexExecutablePath = defaults.string(forKey: "captur.codexExecutablePath") ?? ""
        self.defaults = defaults
        clipboardBeforeWebsiteResolution = defaults.object(forKey: "captur.clipboardBeforeWebsiteResolution") as? Bool ?? false
        speechVocabularyEnabled = Self.bool(defaults, "captur.speechVocabularyEnabled", default: true)
        parakeetVocabularyBoosting = Self.bool(defaults, "captur.parakeetVocabularyBoosting", default: false)
        contextEnabled = Self.bool(defaults, "captur.contextEnabled", default: true)
        recentClipboardOnly = Self.bool(defaults, "captur.recentClipboardOnly", default: true)
        clipboardDuringRecording = Self.bool(defaults, "captur.clipboardDuringRecording", default: false)
        websiteActivation = Self.bool(defaults, "captur.websiteActivation", default: false)
        storeContextMetadata = Self.bool(defaults, "captur.storeContextMetadata", default: true)
        websiteModes = defaults.dictionary(forKey: "captur.websiteModes") as? [String: String] ?? [:]
        micPolicy = Self.decode(MicSelectionPolicy.self, from: defaults.data(forKey: Key.micPolicy))
            ?? .default
        hotkeyBindings = Self.decode(HotkeyBindings.self, from: defaults.data(forKey: Key.hotkeyBindings))
            ?? .default
        dictationSensitivity = defaults.string(forKey: Key.dictationSensitivity) ?? "normal"
        thoughtSensitivity = defaults.string(forKey: Key.thoughtSensitivity) ?? "normal"
        thoughtStyle = defaults.string(forKey: Key.thoughtStyle) ?? "idea"
        openBrainEndpoint = defaults.string(forKey: Key.openBrainEndpoint) ?? ""
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "")
            ?? .system
        retentionPolicy = Self.retentionPolicy(from: defaults)
        voiceProcessing = Self.bool(defaults, Key.voiceProcessing, default: true)
        legacyCleanCleanupChoice = defaults.string(forKey: "captur.cleanCleanupChoice") == "localS1Mini" ? .localS1Mini : .currentMode
        transcriptionProvider = TranscriptionProvider(
            rawValue: defaults.string(forKey: Key.transcriptionProvider) ?? ""
        ) ?? .groq
        transcriptionModel = defaults.string(forKey: Key.transcriptionModel)
            ?? GroqClient.defaultModel
        transcriptionLanguage = defaults.string(forKey: Key.transcriptionLanguage) ?? ""
        lowLatencySegmentation = Self.bool(defaults, Key.lowLatencySegmentation, default: true)
        if let stored = defaults.stringArray(forKey: Key.liveTranscriptionProviders) {
            liveTranscriptionProviders = Set(stored.compactMap(TranscriptionProvider.init(rawValue:)))
                .filter(\.supportsLiveTranscription)
        } else {
            liveTranscriptionProviders = [.localMoonshine]
        }
        retranscribeFinalWithBatch = Self.bool(
            defaults, Key.retranscribeFinalWithBatch, default: true)
        pauseMediaDuringRecording = Self.bool(defaults, Key.pauseMediaDuringRecording, default: false)
        lowerOutputVolumeDuringRecording = Self.bool(defaults, Key.lowerOutputVolumeDuringRecording, default: false)
        let storedVolume = Self.double(defaults, Key.recordingOutputVolume, default: 0.25)
        recordingOutputVolume = storedVolume.isFinite ? min(max(storedVolume, 0), 1) : 0.25
        soundFeedback = Self.bool(defaults, Key.soundFeedback, default: false)
        soundFeedbackVolume = Self.double(defaults, Key.soundFeedbackVolume, default: 0.5)
        neverStoreAudio = Self.bool(defaults, Key.neverStoreAudio, default: false)
    }

    /// macOS voice processing always ducks output. Use it only when the owner
    /// opted to pause playback; the ordinary capture path must preserve output.
    var captureVoiceProcessing: Bool { voiceProcessing && pauseMediaDuringRecording }

    func liveTranscriptionEnabled(for provider: TranscriptionProvider) -> Bool {
        provider.supportsLiveTranscription && liveTranscriptionProviders.contains(provider)
    }

    func setLiveTranscriptionEnabled(_ enabled: Bool, for provider: TranscriptionProvider) {
        guard provider.supportsLiveTranscription else { return }
        if enabled {
            liveTranscriptionProviders.insert(provider)
        } else {
            liveTranscriptionProviders.remove(provider)
        }
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? encoder.encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    /// `UserDefaults.bool(forKey:)` cannot tell "never set" from "set to false", so a
    /// setting whose default is `true` has to ask whether the key exists at all.
    private static func bool(_ defaults: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    /// The same hole as `bool`, and it bites harder: `UserDefaults.double(forKey:)`
    /// returns 0 for a key that was never written, and 0 volume means *never play*. An
    /// unset sound volume would ship as permanently silent.
    private static func double(_ defaults: UserDefaults, _ key: String, default fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
