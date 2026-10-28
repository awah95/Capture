import FluidAudio
import AVFAudio
import Foundation

/// The small surface Captur needs from an on-device model runtime.
///
/// Keeping this behind a protocol prevents unit tests from downloading or loading a
/// Core ML model, and keeps `LocalUnifiedTranscriber` concerned only with the same
/// segment lifecycle as the cloud transcriber.
protocol LocalTranscriptionRunning: Sendable {
    func prepare() async throws
    func transcribe(fileURL: URL) async throws -> String
    func transcribe(fileURL: URL, vocabularyTerms: [String]) async throws -> String
    func finishStreamingSession(id: UUID, audioURL: URL?) async throws -> String
    func startStreamingSession(id: UUID, vocabularyTerms: [String]) async throws
    func appendStreamingAudio(
        sessionID: UUID, samples: [Float], sampleRate: Double
    ) async throws -> String?
    func finishStreamingSession(id: UUID) async throws -> String
    func cancelStreamingSession(id: UUID) async
}

extension LocalTranscriptionRunning {
    func transcribe(fileURL: URL, vocabularyTerms: [String]) async throws -> String {
        try await transcribe(fileURL: fileURL)
    }
    func finishStreamingSession(id: UUID, audioURL: URL?) async throws -> String {
        try await finishStreamingSession(id: id)
    }
}

/// Owns the one Parakeet Unified model instance for the process.
///
/// `UnifiedAsrManager` is an actor, so concurrent segment requests are serialized at
/// the model boundary where its RNNT decoder state is protected. The runtime itself is
/// shared and never unloaded during the process: with ample memory, avoiding a cold
/// Core ML load on every dictation is the useful trade-off.
actor FluidAudioTranscriptionRuntime: LocalTranscriptionRunning {
    static let shared = FluidAudioTranscriptionRuntime()

    private var activeTranscriptions = 0
    private let converter = AudioConverter()
    private var manager: UnifiedAsrManager?
    private var preparation: Task<UnifiedAsrManager, Error>?
    private var warmedStreamingManager: StreamingUnifiedAsrManager?
    private var streamingPreparation: Task<StreamingUnifiedAsrManager, Error>?
    private var streamingSessions: [UUID: StreamingSession] = [:]

    private struct StreamingSession: Sendable {
        let manager: StreamingUnifiedAsrManager
        var vocabularyTerms: [String]
        var lastTranscript: String
    }

    private static let catalogVersion = "fluid-0.17.4-parakeet-unified-en-0.6b-int8"
    private static let modelsRoot = AppPaths.supportDirectory()
        .appendingPathComponent("Models/FluidAudio", isDirectory: true)
    private static let streamingCatalogVersion =
        "fluid-0.17.4-parakeet-unified-en-0.6b-streaming-70-7-1-int8"
    private static let streamingEncoderURL = modelsRoot
        .appendingPathComponent("parakeet-unified-en-0.6b", isDirectory: true)
        .appendingPathComponent("parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc")
    /// FluidAudio's 640 ms tier: a practical balance between visible responsiveness
    /// and repeated encoder work for continuous desktop dictation.
    private static let streamingConfig = UnifiedConfig(
        leftFrames: 70, chunkFrames: 7, rightFrames: 1)

    func prepare() async throws {
        try await prepare(progress: nil)
    }

    func prepare(
        progress: (@Sendable (LocalModelDownloadProgress) -> Void)?
    ) async throws {
        if manager != nil { return }
        if let preparation {
            manager = try await preparation.value
            return
        }

        let estimator = LocalModelProgressEstimator()
        let existingArtifacts = availability().isDownloaded
        let task = Task<UnifiedAsrManager, Error> {
            let loaded = UnifiedAsrManager(encoderPrecision: .int8)
            try await loaded.loadModels(
                to: Self.modelsRoot,
                configuration: nil,
                progressHandler: { update in
                    progress?(estimator.snapshot(
                        fraction: update.fractionCompleted,
                        detail: "Downloading and compiling Unified…"))
                })
            try FileManager.default.createDirectory(
                at: Self.modelsRoot, withIntermediateDirectories: true)
            try LocalModelInstallation.recordPrepared(root: Self.modelsRoot,
                version: Self.catalogVersion, existingArtifacts: existingArtifacts)
            return loaded
        }
        preparation = task

        do {
            manager = try await task.value
            preparation = nil
        } catch {
            preparation = nil
            throw error
        }
    }

    func availability() -> LocalModelAvailability {
        let directory = Self.modelsRoot.appendingPathComponent("parakeet-unified-en-0.6b")
        let required = [ModelNames.ParakeetUnified.offlineEncoderFile(precision: .int8),
                        ModelNames.ParakeetUnified.decoderFile, ModelNames.ParakeetUnified.jointDecisionFile,
                        ModelNames.ParakeetUnified.vocab]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
            return LocalModelAvailability(isDownloaded: false, updateAvailable: false)
        }
        return LocalModelInstallation.availability(root: Self.modelsRoot,
            latestVersion: Self.catalogVersion, artifactsPresent: true)
    }

    func prepareStreaming(
        progress: (@Sendable (LocalModelDownloadProgress) -> Void)? = nil
    ) async throws {
        // The streaming artifact shares the vocabulary, decoder, and joint model with
        // batch Unified. Preparing batch first avoids duplicate shared downloads.
        try await prepare(progress: nil)
        if warmedStreamingManager != nil { return }
        if let streamingPreparation {
            warmedStreamingManager = try await streamingPreparation.value
            return
        }

        let estimator = LocalModelProgressEstimator()
        let existingArtifacts = streamingAvailability().isDownloaded
        let task = Task<StreamingUnifiedAsrManager, Error> {
            let loaded = StreamingUnifiedAsrManager(
                config: Self.streamingConfig,
                encoderPrecision: .int8)
            try await loaded.loadModels(
                to: Self.modelsRoot,
                configuration: nil,
                progressHandler: { update in
                    progress?(estimator.snapshot(
                        fraction: update.fractionCompleted,
                        detail: "Downloading and compiling Unified live model…"))
                })
            try FileManager.default.createDirectory(
                at: Self.modelsRoot, withIntermediateDirectories: true)
            try LocalModelInstallation.recordPrepared(root: Self.modelsRoot,
                markerName: "captur-streaming-model-version.txt",
                version: Self.streamingCatalogVersion, existingArtifacts: existingArtifacts)
            return loaded
        }
        streamingPreparation = task

        do {
            warmedStreamingManager = try await task.value
            streamingPreparation = nil
        } catch {
            streamingPreparation = nil
            throw error
        }
    }

    func streamingAvailability() -> LocalModelAvailability {
        let directory = Self.streamingEncoderURL.deletingLastPathComponent()
        let shared = [ModelNames.ParakeetUnified.decoderFile,
                      ModelNames.ParakeetUnified.jointDecisionFile, ModelNames.ParakeetUnified.vocab]
        let downloaded = FileManager.default.fileExists(atPath: Self.streamingEncoderURL.path)
            && shared.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        guard downloaded else {
            return LocalModelAvailability(isDownloaded: false, updateAvailable: false)
        }
        return LocalModelInstallation.availability(root: Self.modelsRoot,
            markerName: "captur-streaming-model-version.txt",
            latestVersion: Self.streamingCatalogVersion, artifactsPresent: true)
    }

    func removeModel() throws {
        guard preparation == nil, streamingPreparation == nil,
              activeTranscriptions == 0, streamingSessions.isEmpty else { throw LocalModelBusyError() }
        preparation = nil
        streamingPreparation?.cancel()
        streamingPreparation = nil
        manager = nil
        warmedStreamingManager = nil
        streamingSessions.removeAll()
        if FileManager.default.fileExists(atPath: Self.modelsRoot.path) {
            try FileManager.default.removeItem(at: Self.modelsRoot)
        }
    }

    func transcribe(fileURL: URL) async throws -> String {
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        try await prepare()
        // SegmentRecorder already writes 16 kHz mono FLAC. Going through FluidAudio's
        // converter still validates the container and protects this path if that format
        // changes later.
        let samples = try converter.resampleAudioFile(fileURL)
        guard let manager else { throw CocoaError(.fileNoSuchFile) }
        return try await manager.transcribe(samples)
    }

    func transcribe(fileURL: URL, vocabularyTerms: [String]) async throws -> String {
        guard !vocabularyTerms.isEmpty else { return try await transcribe(fileURL: fileURL) }
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        try await prepare()
        let samples = try converter.resampleAudioFile(fileURL)
        guard let manager else { throw CocoaError(.fileNoSuchFile) }
        guard samples.count <= ParakeetVocabularyBooster.maximumSamples else { return try await manager.transcribe(samples) }
        let result = try await manager.transcribeWithTimings(samples)
        return await ParakeetVocabularyBooster.shared.rescore(text: result.text,
            timings: result.tokenTimings, samples: samples, terms: vocabularyTerms)
    }

    func startStreamingSession(id: UUID, vocabularyTerms: [String]) async throws {
        guard streamingSessions[id] == nil else { return }
        try await prepareStreaming()
        guard let streamingManager = warmedStreamingManager else {
            throw CocoaError(.fileNoSuchFile)
        }
        warmedStreamingManager = nil
        try await streamingManager.reset()
        streamingSessions[id] = StreamingSession(
            manager: streamingManager, vocabularyTerms: SpeechVocabulary.bounded(vocabularyTerms), lastTranscript: "")
    }

    func appendStreamingAudio(
        sessionID: UUID,
        samples: [Float],
        sampleRate: Double
    ) async throws -> String? {
        guard var session = streamingSessions[sessionID], !samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CocoaError(.fileReadCorruptFile) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let destination = buffer.floatChannelData?[0], let base = source.baseAddress else {
                return
            }
            destination.update(from: base, count: samples.count)
        }

        try await session.manager.appendAudio(buffer)
        try await session.manager.processBufferedAudio()
        let transcript = await session.manager.getPartialTranscript()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty, transcript != session.lastTranscript else { return nil }
        session.lastTranscript = transcript
        streamingSessions[sessionID] = session
        return transcript
    }

    func finishStreamingSession(id: UUID) async throws -> String {
        try await finishStreamingSession(id: id, audioURL: nil)
    }

    func finishStreamingSession(id: UUID, audioURL: URL?) async throws -> String {
        guard let session = streamingSessions.removeValue(forKey: id) else { return "" }
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        var final = try await session.manager.finish()
        if !session.vocabularyTerms.isEmpty, let audioURL,
           let file = try? AVAudioFile(forReading: audioURL), file.processingFormat.sampleRate > 0,
           Double(file.length) / file.processingFormat.sampleRate <= 60 {
            let timings = await session.manager.consumeTokenTimings()
            if let samples = try? converter.resampleAudioFile(audioURL) {
                final = await ParakeetVocabularyBooster.shared.rescore(text: final,
                    timings: timings, samples: samples, terms: session.vocabularyTerms)
            }
        }
        try? await session.manager.reset()
        if warmedStreamingManager == nil {
            warmedStreamingManager = session.manager
        }
        return final
    }

    func cancelStreamingSession(id: UUID) async {
        guard let session = streamingSessions.removeValue(forKey: id) else { return }
        try? await session.manager.reset()
        if warmedStreamingManager == nil {
            warmedStreamingManager = session.manager
        }
    }
}

/// Per-capture segment coordinator backed by the process-wide local model.
///
/// Every capture gets its own registry so cancelling a new dictation cannot cancel an
/// older dictation that is finishing in the background. The expensive model remains
/// shared and warm across those coordinators.
private final class VocabularyAudioBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingSeconds: Double = 60
    func reserve(_ duration: Double?) -> Bool {
        guard let duration, duration.isFinite, duration > 0 else { return false }
        return lock.withLock {
            guard duration <= remainingSeconds else { return false }
            remainingSeconds -= duration
            return true
        }
    }
}

final class LocalUnifiedTranscriber: DictationTranscribing, @unchecked Sendable {
    private struct DeferredBatchSegment: Sendable {
        let index: Int
        let url: URL
        let precedingSilence: TimeInterval
    }

    private let runtime: any LocalTranscriptionRunning
    private let retranscribeFinalWithBatch: Bool
    private let vocabularyBoostingEnabled: Bool
    private var vocabularyTerms: [String] = []
    private var boostBudget = VocabularyAudioBudget()
    private var budgetDecisionTail: Task<Bool, Never>?
    private let audioDuration: @Sendable (URL) -> Double?
    private let registry = TranscriptionSegmentRegistry()
    private let lock = NSLock()
    private var streamingSessionID: UUID?
    private var streamingTail: Task<Void, Never>?
    private var liveTranscriptHandler: (@Sendable (String) -> Void)?
    private var streamingFallbackSegments: [DeferredBatchSegment] = []
    private var finalRecordingURL: URL?
    private var selectedPath: DictationTranscriptionPath?

    init(
        runtime: any LocalTranscriptionRunning = FluidAudioTranscriptionRuntime.shared,
        retranscribeFinalWithBatch: Bool = false,
        vocabularyBoostingEnabled: Bool = false,
        audioDuration: @escaping @Sendable (URL) -> Double? = { url in
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
            return Double(file.length) / file.processingFormat.sampleRate
        }
    ) {
        self.runtime = runtime
        self.retranscribeFinalWithBatch = retranscribeFinalWithBatch
        self.vocabularyBoostingEnabled = vocabularyBoostingEnabled
        self.audioDuration = audioDuration
    }

    deinit {
        registry.cancelAll()
        streamingTail?.cancel()
        if let id = streamingSessionID {
            let runtime = runtime
            Task { await runtime.cancelStreamingSession(id: id) }
        }
    }

    func configureVocabulary(_ terms: [String]) {
        lock.withLock { vocabularyTerms = vocabularyBoostingEnabled ? SpeechVocabulary.bounded(terms) : [] }
    }

    func enqueue(
        index: Int,
        url: URL,
        precedingSilence: TimeInterval,
        apiKey: String,
        model: String,
        language: String?,
        vocabularyPrompt: String
    ) {
        let deferredForStreamingFallback = lock.withLock {
            guard streamingSessionID != nil else { return false }
            streamingFallbackSegments.append(DeferredBatchSegment(
                index: index, url: url, precedingSilence: precedingSilence))
            return true
        }
        if deferredForStreamingFallback { return }
        let generation = registry.currentGeneration
        let runtime = self.runtime
        let (terms, budget) = lock.withLock { (vocabularyTerms, boostBudget) }
        let audioDuration = self.audioDuration
        // Reserve in enqueue order, on background tasks. File metadata never blocks
        // the microphone/main actor, and inference does not serialize behind it.
        let decision = lock.withLock {
            let previous = budgetDecisionTail
            let decision = Task<Bool, Never> {
                _ = await previous?.value
                guard !Task.isCancelled, !terms.isEmpty else { return false }
                return budget.reserve(audioDuration(url))
            }
            budgetDecisionTail = decision
            return decision
        }
        let task = Task<String?, Never> {
            guard !Task.isCancelled else { return nil }
            do {
                let eligible = await decision.value
                guard !Task.isCancelled else { return nil }
                let text = try await runtime.transcribe(fileURL: url, vocabularyTerms: eligible ? terms : [])
                return Task.isCancelled ? nil : text
            } catch {
                return nil
            }
        }

        if !registry.register(
            index: index,
            precedingSilence: precedingSilence,
            task: task,
            expectedGeneration: generation
        ) {
            task.cancel()
        }
    }

    func awaitAll() async -> [SegmentResult] {
        let streaming: (UUID, Task<Void, Never>?, [DeferredBatchSegment], URL?)? = lock.withLock {
            guard let id = streamingSessionID else { return nil }
            return (id, streamingTail, streamingFallbackSegments, finalRecordingURL)
        }
        if let (id, tail, fallbackSegments, recordingURL) = streaming {
            await tail?.value
            let boostURL = !retranscribeFinalWithBatch && recordingURL.map { reserveBoost(for: $0) } == true ? recordingURL : nil
            let streamingText = try? await runtime.finishStreamingSession(id: id, audioURL: boostURL)
            lock.withLock {
                if streamingSessionID == id {
                    streamingSessionID = nil
                    streamingTail = nil
                    streamingFallbackSegments = []
                    finalRecordingURL = nil
                }
            }

            // The live transcript is intentionally provisional. When requested, run the
            // complete durable recording through Unified's full-attention batch encoder
            // and use that as the single result inserted at the cursor. A failed or empty
            // batch pass falls back to the completed stream, so this accuracy option can
            // add latency but can never turn a usable dictation into a failure.
            if retranscribeFinalWithBatch, let recordingURL,
               let batchText = try? await runtime.transcribe(fileURL: recordingURL, vocabularyTerms: reserveBoost(for: recordingURL) ? lock.withLock { vocabularyTerms } : []),
               !batchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lock.withLock { selectedPath = .finalBatchRecheck }
                return [SegmentResult(index: 0, text: batchText, precedingSilence: 0)]
            }
            if let streamingText,
               !streamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lock.withLock { selectedPath = .liveStream }
                return [SegmentResult(index: 0, text: streamingText, precedingSilence: 0)]
            }
            let fallback = await transcribeFallback(fallbackSegments)
            lock.withLock { selectedPath = .batchSegment }
            return fallback
        }

        var results: [Int: SegmentResult] = [:]
        var awaited: Set<Int> = []

        while true {
            let pending = registry.snapshot().filter { !awaited.contains($0.index) }
            if pending.isEmpty { break }

            for entry in pending {
                awaited.insert(entry.index)
                results[entry.index] = SegmentResult(
                    index: entry.index,
                    text: await entry.task.value,
                    precedingSilence: entry.precedingSilence)
            }
        }

        let resolved = results.values.sorted { $0.index < $1.index }
        lock.withLock { selectedPath = .batchSegment }
        return resolved
    }

    func selectedTranscriptionPath() -> DictationTranscriptionPath? {
        lock.withLock { selectedPath }
    }

    private func reserveBoost(for url: URL) -> Bool {
        let (terms, budget) = lock.withLock { (vocabularyTerms, boostBudget) }
        return !terms.isEmpty && budget.reserve(audioDuration(url))
    }

    private func transcribeFallback(_ segments: [DeferredBatchSegment]) async -> [SegmentResult] {
        var results: [SegmentResult] = []
        for segment in segments.sorted(by: { $0.index < $1.index }) {
            let text = try? await runtime.transcribe(fileURL: segment.url, vocabularyTerms: reserveBoost(for: segment.url) ? lock.withLock { vocabularyTerms } : [])
            results.append(SegmentResult(
                index: segment.index,
                text: text,
                precedingSilence: segment.precedingSilence))
        }
        return results
    }

    func warmConnection(apiKey: String) {
        let runtime = self.runtime
        Task(priority: .utility) { try? await runtime.prepare() }
    }

    func setLiveTranscriptHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.withLock { liveTranscriptHandler = handler }
    }

    func setFinalRecordingURL(_ url: URL) {
        lock.withLock { finalRecordingURL = url }
    }

    func beginLiveTranscription(vocabularyTerms: [String]) {
        configureVocabulary(vocabularyTerms)
        let terms = lock.withLock { self.vocabularyTerms }
        let id = UUID()
        let runtime = runtime
        let start = Task<Void, Never> {
            try? await runtime.startStreamingSession(id: id, vocabularyTerms: terms)
        }
        lock.withLock {
            streamingSessionID = id
            streamingTail = start
            streamingFallbackSegments = []
        }
    }

    func ingestLiveAudio(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(
            start: channel, count: Int(buffer.frameLength)))
        let sampleRate = buffer.format.sampleRate
        let state: (UUID, Task<Void, Never>?)? = lock.withLock {
            guard let id = streamingSessionID else { return nil }
            return (id, streamingTail)
        }
        guard let (id, previous) = state else { return }
        let runtime = runtime
        let task = Task<Void, Never> { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            if let text = try? await runtime.appendStreamingAudio(
                sessionID: id, samples: samples, sampleRate: sampleRate) {
                let handler = self?.lock.withLock { self?.liveTranscriptHandler }
                handler?(text)
            }
        }
        lock.withLock {
            if streamingSessionID == id { streamingTail = task }
        }
    }

    func reset() {
        registry.cancelAll()
        lock.withLock {
            boostBudget = VocabularyAudioBudget()
            budgetDecisionTail?.cancel()
            budgetDecisionTail = nil
        }
        let state: (UUID?, Task<Void, Never>?) = lock.withLock {
            let state = (streamingSessionID, streamingTail)
            streamingSessionID = nil
            streamingTail = nil
            liveTranscriptHandler = nil
            selectedPath = nil
            streamingFallbackSegments = []
            finalRecordingURL = nil
            return state
        }
        state.1?.cancel()
        if let id = state.0 {
            let runtime = runtime
            Task { await runtime.cancelStreamingSession(id: id) }
        }
    }
}
