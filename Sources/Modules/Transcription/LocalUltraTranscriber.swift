import FluidAudio
import Foundation

/// Ultra has its own cache so upgrading or removing Unified cannot delete Ultra.
actor UltraTranscriptionRuntime: LocalTranscriptionRunning {
    static let shared = UltraTranscriptionRuntime()
    private static let catalogVersion = "fluid-0.17.4-parakeet-ultra-coreml-int8"
    private let modelsRoot: URL
    private let converter = AudioConverter()

    init(supportDirectory: URL = AppPaths.supportDirectory()) {
        // AsrModels resolves files as siblings using the repository's folder name.
        // Its target must therefore use that exact leaf, within our owned cache.
        modelsRoot = supportDirectory.appendingPathComponent("Models/ParakeetUltra", isDirectory: true)
            .appendingPathComponent(Repo.parakeetUltra.folderName, isDirectory: true)
    }
    private var activeTranscriptions = 0
    private var manager: AsrManager?
    private var preparation: Task<AsrManager, Error>?

    func prepare() async throws { try await prepare(progress: nil) }

    func prepare(progress: (@Sendable (LocalModelDownloadProgress) -> Void)?) async throws {
        if manager != nil { return }
        if let preparation { manager = try await preparation.value; return }
        let estimator = LocalModelProgressEstimator()
        let existingArtifacts = availability().isDownloaded
        let task = Task<AsrManager, Error> { [modelsRoot] in
            let models = try await AsrModels.downloadAndLoad(
                to: modelsRoot, version: .ultra,
                progressHandler: { update in
                    progress?(estimator.snapshot(fraction: update.fractionCompleted,
                        detail: "Downloading and compiling Ultra…"))
                })
            let loaded = AsrManager(config: .default)
            try await loaded.loadModels(models)
            try Task.checkCancellation()
            try LocalModelInstallation.recordPrepared(root: modelsRoot,
                version: Self.catalogVersion, existingArtifacts: existingArtifacts)
            return loaded
        }
        preparation = task
        do { manager = try await task.value; preparation = nil }
        catch { preparation = nil; throw error }
    }

    func availability() -> LocalModelAvailability {
        LocalModelInstallation.availability(root: modelsRoot,
            latestVersion: Self.catalogVersion,
            artifactsPresent: AsrModels.modelsExist(at: modelsRoot, version: .ultra))
    }

    func removeModel() throws {
        guard preparation == nil, activeTranscriptions == 0 else { throw LocalModelBusyError() }
        preparation = nil
        manager = nil
        if FileManager.default.fileExists(atPath: modelsRoot.path) {
            try FileManager.default.removeItem(at: modelsRoot)
        }
    }

    func transcribe(fileURL: URL) async throws -> String {
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        try await prepare()
        guard let manager else { throw CocoaError(.fileNoSuchFile) }
        var state = try TdtDecoderState()
        return try await manager.transcribe(fileURL, decoderState: &state).text
    }

    func transcribe(fileURL: URL, vocabularyTerms: [String]) async throws -> String {
        let terms = SpeechVocabulary.bounded(vocabularyTerms)
        guard !terms.isEmpty else { return try await transcribe(fileURL: fileURL) }
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        try await prepare()
        guard let manager else { throw CocoaError(.fileNoSuchFile) }
        let samples = try converter.resampleAudioFile(fileURL)
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        // Ultra uses the TDT rescoring defaults; Unified's numeric formatting
        // requires a different similarity threshold. The booster caches each safely.
        return await ParakeetVocabularyBooster.shared.rescore(text: result.text,
            timings: result.tokenTimings ?? [], samples: samples, terms: terms,
            inverseTextNormalized: false)
    }

    func startStreamingSession(id: UUID, vocabularyTerms: [String]) async throws {
        throw CocoaError(.featureUnsupported)
    }
    func appendStreamingAudio(sessionID: UUID, samples: [Float], sampleRate: Double) async throws -> String? {
        throw CocoaError(.featureUnsupported)
    }
    func finishStreamingSession(id: UUID) async throws -> String { throw CocoaError(.featureUnsupported) }
    func cancelStreamingSession(id: UUID) async {}
}
