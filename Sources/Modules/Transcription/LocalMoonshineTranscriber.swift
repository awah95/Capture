import AVFoundation
import CapturMoonshineC
import Darwin
import FluidAudio
import Foundation

protocol MoonshineTranscriptionRunning: Sendable {
    func prepare() async throws
    func startSession(id: UUID, vocabularyTerms: [String]) async throws
    /// Returns a revised partial transcript when this audio advances decoding.
    func addAudio(sessionID: UUID, samples: [Float], sampleRate: Int32) async throws -> String?
    func finishSession(id: UUID) async throws -> String
    func cancelSession(id: UUID) async
    func transcribe(fileURL: URL) async throws -> String
    func transcribe(fileURL: URL, vocabularyTerms: [String]) async throws -> String
}

extension MoonshineTranscriptionRunning {
    func transcribe(fileURL: URL, vocabularyTerms: [String]) async throws -> String {
        try await transcribe(fileURL: fileURL)
    }
}

private enum CapturMoonshineError: LocalizedError {
    case native(Int32)
    case invalidManifest
    case invalidResponse(URL)
    case incompleteDownload(String)

    var errorDescription: String? {
        switch self {
        case .native(let code):
            return String(cString: moonshine_error_to_string(code))
        case .invalidManifest:
            return "Moonshine returned an invalid model manifest."
        case .invalidResponse(let url):
            return "The Moonshine model server returned an invalid response for \(url.lastPathComponent)."
        case .incompleteDownload(let name):
            return "The download of \(name) ended before the complete file arrived."
        }
    }
}

private func requireMoonshineSuccess(_ code: Int32) throws {
    guard code == 0 else { throw CapturMoonshineError.native(code) }
}

private func transcriptText(_ transcript: UnsafeMutablePointer<transcript_t>?) -> String {
    guard let transcript, let lines = transcript.pointee.lines else { return "" }
    return (0..<Int(transcript.pointee.line_count)).compactMap { index in
        lines[index].text.map { String(cString: $0) }
    }
    .joined(separator: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Thin Swift ownership layer over Moonshine's stable C API. Captur vendors only the
/// arm64 static runtime, avoiding an upstream Xcode module-map collision with
/// FluidAudio's own native dependency.
private final class NativeMoonshineTranscriber {
    let handle: Int32
    private var appliedKeyterms: [String]?

    init(modelPath: String) throws {
        handle = modelPath.withCString {
            moonshine_load_transcriber_from_files($0, 5, nil, 0, 30_000)
        }
        guard handle >= 0 else { throw CapturMoonshineError.native(handle) }
    }

    deinit { moonshine_free_transcriber(handle) }

    func setKeyterms(_ terms: [String]) throws {
        guard terms != appliedKeyterms else { return }
        let joined = terms.joined(separator: ",")
        let code = joined.withCString { moonshine_transcriber_set_keyterms(handle, $0) }
        try requireMoonshineSuccess(code)
        appliedKeyterms = terms
    }

    func makeStream() throws -> NativeMoonshineStream {
        try NativeMoonshineStream(transcriberHandle: handle)
    }

    func transcribe(_ samples: [Float], sampleRate: Int32) throws -> String {
        var transcript: UnsafeMutablePointer<transcript_t>?
        let code = samples.withUnsafeBufferPointer { buffer in
            moonshine_transcribe_without_streaming(
                handle, UnsafeMutablePointer(mutating: buffer.baseAddress),
                UInt64(buffer.count), sampleRate, 0, &transcript)
        }
        try requireMoonshineSuccess(code)
        return transcriptText(transcript)
    }
}

private final class NativeMoonshineStream {
    private let transcriberHandle: Int32
    private let streamHandle: Int32
    private var audioSinceUpdate: TimeInterval = 0
    private(set) var text = ""

    init(transcriberHandle: Int32) throws {
        self.transcriberHandle = transcriberHandle
        streamHandle = moonshine_create_stream(transcriberHandle, 0)
        guard streamHandle >= 0 else { throw CapturMoonshineError.native(streamHandle) }
        try requireMoonshineSuccess(moonshine_start_stream(transcriberHandle, streamHandle))
    }

    deinit { _ = moonshine_free_stream(transcriberHandle, streamHandle) }

    func addAudio(_ samples: [Float], sampleRate: Int32) throws -> String? {
        let code = samples.withUnsafeBufferPointer { buffer in
            moonshine_transcribe_add_audio_to_stream(
                transcriberHandle, streamHandle, buffer.baseAddress,
                UInt64(buffer.count), sampleRate, 0)
        }
        try requireMoonshineSuccess(code)
        audioSinceUpdate += Double(samples.count) / Double(sampleRate)
        if audioSinceUpdate >= 0.35 {
            let previous = text
            try update(flags: 0)
            audioSinceUpdate = 0
            return text.isEmpty || text == previous ? nil : text
        }
        return nil
    }

    func finish() throws -> String {
        try requireMoonshineSuccess(moonshine_stop_stream(transcriberHandle, streamHandle))
        try update(flags: 1)
        return text
    }

    private func update(flags: UInt32) throws {
        var transcript: UnsafeMutablePointer<transcript_t>?
        try requireMoonshineSuccess(moonshine_transcribe_stream(
            transcriberHandle, streamHandle, flags, &transcript))
        text = transcriptText(transcript)
    }
}

private struct MoonshineModelFile: Sendable {
    let name: String
    let url: URL
    let size: Int64
}

/// Process-wide Moonshine Medium Streaming model. Streams are capture-scoped, while
/// the expensive model stays warm between dictations.
actor MoonshineTranscriptionRuntime: MoonshineTranscriptionRunning {
    static let shared = MoonshineTranscriptionRuntime()

    private static let catalogVersion = "moonshine-0.1.5-medium-streaming-en"
    private static let modelDirectory = AppPaths.supportDirectory()
        .appendingPathComponent("Models/Moonshine/medium-streaming-en", isDirectory: true)

    private let converter = AudioConverter()
    private var transcriber: NativeMoonshineTranscriber?
    private var preparation: Task<NativeMoonshineTranscriber, Error>?
    private var sessions: [UUID: NativeMoonshineStream] = [:]
    private var sessionVocabulary: [UUID: [String]] = [:]

    func prepare() async throws { try await prepare(progress: nil) }

    func prepare(
        progress: (@Sendable (LocalModelDownloadProgress) -> Void)?
    ) async throws {
        if transcriber != nil { return }
        if let preparation {
            transcriber = try await preparation.value
            return
        }

        let estimator = LocalModelProgressEstimator()
        let existingArtifacts = availability().isDownloaded
        let task = Task<NativeMoonshineTranscriber, Error> {
            let files = try Self.resolveModelFiles()
            try await Self.downloadMissing(files: files, estimator: estimator, progress: progress)
            let loaded = try NativeMoonshineTranscriber(modelPath: Self.modelDirectory.path)
            try LocalModelInstallation.recordPrepared(root: Self.modelDirectory,
                version: Self.catalogVersion, existingArtifacts: existingArtifacts)
            return loaded
        }
        preparation = task
        do {
            transcriber = try await task.value
            preparation = nil
        } catch {
            preparation = nil
            throw error
        }
    }

    func availability() -> LocalModelAvailability {
        guard let files = try? Self.resolveModelFiles() else {
            return LocalModelAvailability(isDownloaded: false, updateAvailable: false)
        }
        let present = files.allSatisfy { file in
            let url = Self.modelDirectory.appendingPathComponent(file.name)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return false
            }
            return file.size <= 0 || Int64(size) == file.size
        }
        guard present else {
            return LocalModelAvailability(isDownloaded: false, updateAvailable: false)
        }
        return LocalModelInstallation.availability(root: Self.modelDirectory,
            latestVersion: Self.catalogVersion, artifactsPresent: true)
    }

    func removeModel() throws {
        guard preparation == nil, sessions.isEmpty else { throw LocalModelBusyError() }
        preparation = nil
        sessions.removeAll()
        sessionVocabulary.removeAll()
        transcriber = nil
        if FileManager.default.fileExists(atPath: Self.modelDirectory.path) {
            try FileManager.default.removeItem(at: Self.modelDirectory)
        }
    }

    func startSession(id: UUID, vocabularyTerms: [String]) async throws {
        try await prepare()
        guard let transcriber else { throw CocoaError(.fileNoSuchFile) }
        let terms = SpeechVocabulary.bounded(vocabularyTerms)
        try transcriber.setKeyterms(terms)
        sessions[id] = try transcriber.makeStream()
        sessionVocabulary[id] = terms
    }

    func addAudio(sessionID: UUID, samples: [Float], sampleRate: Int32) async throws -> String? {
        try transcriber?.setKeyterms(sessionVocabulary[sessionID] ?? [])
        return try sessions[sessionID]?.addAudio(samples, sampleRate: sampleRate)
    }

    func finishSession(id: UUID) async throws -> String {
        guard let session = sessions.removeValue(forKey: id) else { return "" }
        try transcriber?.setKeyterms(sessionVocabulary.removeValue(forKey: id) ?? [])
        return try session.finish()
    }

    func cancelSession(id: UUID) async { sessions[id] = nil; sessionVocabulary[id] = nil }

    func transcribe(fileURL: URL) async throws -> String {
        try await transcribe(fileURL: fileURL, vocabularyTerms: [])
    }

    func transcribe(fileURL: URL, vocabularyTerms: [String]) async throws -> String {
        try await prepare()
        guard let transcriber else { throw CocoaError(.fileNoSuchFile) }
        try transcriber.setKeyterms(SpeechVocabulary.bounded(vocabularyTerms))
        return try transcriber.transcribe(converter.resampleAudioFile(fileURL), sampleRate: 16_000)
    }

    private static func resolveModelFiles() throws -> [MoonshineModelFile] {
        var jsonPointer: UnsafeMutablePointer<CChar>?
        let code: Int32 = "en".withCString { language in
            "model_arch".withCString { name in
                "5".withCString { value in
                    var option = moonshine_option_t(name: name, value: value)
                    return moonshine_get_stt_dependencies(language, &option, 1, &jsonPointer)
                }
            }
        }
        try requireMoonshineSuccess(code)
        guard let jsonPointer else { throw CapturMoonshineError.invalidManifest }
        defer { free(jsonPointer) }
        guard let data = String(cString: jsonPointer).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = object["groups"] as? [[String: Any]]
        else { throw CapturMoonshineError.invalidManifest }

        return try groups.flatMap { group -> [MoonshineModelFile] in
            guard let files = group["files"] as? [[String: Any]] else {
                throw CapturMoonshineError.invalidManifest
            }
            return try files.map { file in
                guard let name = file["name"] as? String,
                      let urlString = file["url"] as? String,
                      let url = URL(string: urlString)
                else { throw CapturMoonshineError.invalidManifest }
                return MoonshineModelFile(
                    name: name, url: url,
                    size: (file["size"] as? NSNumber)?.int64Value ?? -1)
            }
        }
    }

    private static func downloadMissing(
        files: [MoonshineModelFile],
        estimator: LocalModelProgressEstimator,
        progress: (@Sendable (LocalModelDownloadProgress) -> Void)?
    ) async throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let missing = files.filter { file in
            let url = modelDirectory.appendingPathComponent(file.name)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return true
            }
            return file.size > 0 && Int64(size) != file.size
        }
        let totalBytes = missing.reduce(Int64(0)) { total, file in
            total + max(file.size, 1)
        }
        var completedBytes: Int64 = 0
        for file in missing {
            try Task.checkCancellation()
            try await download(file, completedBytes: completedBytes, totalBytes: totalBytes,
                               estimator: estimator, progress: progress)
            completedBytes += max(file.size, 1)
        }
    }

    private static func download(
        _ file: MoonshineModelFile,
        completedBytes: Int64,
        totalBytes: Int64,
        estimator: LocalModelProgressEstimator,
        progress: (@Sendable (LocalModelDownloadProgress) -> Void)?
    ) async throws {
        let destination = modelDirectory.appendingPathComponent(file.name)
        let part = destination.appendingPathExtension("part")
        var existing = ((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
        var request = URLRequest(url: file.url)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CapturMoonshineError.invalidResponse(file.url)
        }
        let resumes = existing > 0 && http.statusCode == 206
        if !resumes {
            existing = 0
            try? FileManager.default.removeItem(at: part)
        }
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: part)
        if resumes { try handle.seekToEnd() }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var downloaded = existing
        var lastReported = existing
        defer { try? handle.close() }
        report(file: file, completedBytes: completedBytes, totalBytes: totalBytes,
               downloaded: downloaded, estimator: estimator, progress: progress)

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            guard buffer.count >= 64 * 1024 else { continue }
            try handle.write(contentsOf: buffer)
            downloaded += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            if downloaded - lastReported >= 256 * 1024 {
                report(file: file, completedBytes: completedBytes, totalBytes: totalBytes,
                       downloaded: downloaded, estimator: estimator, progress: progress)
                lastReported = downloaded
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            downloaded += Int64(buffer.count)
        }
        try handle.close()
        if file.size > 0 && downloaded != file.size {
            throw CapturMoonshineError.incompleteDownload(file.name)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: part, to: destination)
        report(file: file, completedBytes: completedBytes, totalBytes: totalBytes,
               downloaded: downloaded, estimator: estimator, progress: progress)
    }

    private static func report(
        file: MoonshineModelFile,
        completedBytes: Int64,
        totalBytes: Int64,
        downloaded: Int64,
        estimator: LocalModelProgressEstimator,
        progress: (@Sendable (LocalModelDownloadProgress) -> Void)?
    ) {
        let fileBytes = max(file.size, 1)
        let currentBytes = min(max(downloaded, 0), fileBytes)
        let total = max(totalBytes, 1)
        progress?(estimator.snapshot(
            fraction: Double(completedBytes + currentBytes) / Double(total),
            detail: "Downloading \(file.name)…"))
    }
}

/// Capture-scoped streaming coordinator. Audio inference is chained off the audio
/// callback so buffers stay ordered without ever blocking AVAudioEngine's queue.
final class LocalMoonshineTranscriber: DictationTranscribing, @unchecked Sendable {
    private struct DeferredBatchSegment: Sendable {
        let index: Int
        let url: URL
        let precedingSilence: TimeInterval
    }

    private let runtime: any MoonshineTranscriptionRunning
    private let registry = TranscriptionSegmentRegistry()
    private let lock = NSLock()
    private var vocabularyTerms: [String] = []
    private var liveSessionID: UUID?
    private var liveTail: Task<Void, Never>?
    private var liveTranscriptHandler: (@Sendable (String) -> Void)?
    private var liveFallbackSegments: [DeferredBatchSegment] = []
    private var selectedPath: DictationTranscriptionPath?

    init(runtime: any MoonshineTranscriptionRunning = MoonshineTranscriptionRuntime.shared) {
        self.runtime = runtime
    }

    deinit {
        registry.cancelAll()
        let sessionID = lock.withLock { liveSessionID }
        if let sessionID {
            let runtime = self.runtime
            Task { await runtime.cancelSession(id: sessionID) }
        }
    }

    func setLiveTranscriptHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.withLock { liveTranscriptHandler = handler }
    }

    func configureVocabulary(_ terms: [String]) {
        lock.withLock { vocabularyTerms = SpeechVocabulary.bounded(terms) }
    }

    func beginLiveTranscription(vocabularyTerms: [String]) {
        configureVocabulary(vocabularyTerms)
        let terms = lock.withLock { self.vocabularyTerms }
        let id = UUID()
        let runtime = self.runtime
        let task = Task<Void, Never> {
            try? await runtime.startSession(id: id, vocabularyTerms: terms)
        }
        lock.withLock {
            liveSessionID = id
            liveTail = task
            liveFallbackSegments = []
        }
    }

    func ingestLiveAudio(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channels[0], count: count))
        let sampleRate = Int32(buffer.format.sampleRate.rounded())
        let runtime = self.runtime
        lock.withLock {
            guard let id = liveSessionID else { return }
            let prior = liveTail
            liveTail = Task { [weak self] in
                await prior?.value
                guard let partial = try? await runtime.addAudio(
                    sessionID: id, samples: samples, sampleRate: sampleRate
                ) else { return }
                let handler = self?.lock.withLock { self?.liveTranscriptHandler }
                handler?(partial)
            }
        }
    }

    func enqueue(
        index: Int, url: URL, precedingSilence: TimeInterval,
        apiKey: String, model: String, language: String?, vocabularyPrompt: String
    ) {
        let deferredForLiveFallback = lock.withLock {
            guard liveSessionID != nil else { return false }
            liveFallbackSegments.append(DeferredBatchSegment(
                index: index, url: url, precedingSilence: precedingSilence))
            return true
        }
        if deferredForLiveFallback { return }
        let generation = registry.currentGeneration
        let runtime = self.runtime
        let terms = lock.withLock { vocabularyTerms }
        let task = Task<String?, Never> { try? await runtime.transcribe(fileURL: url, vocabularyTerms: terms) }
        if !registry.register(index: index, precedingSilence: precedingSilence, task: task,
                              expectedGeneration: generation) {
            task.cancel()
        }
    }

    func awaitAll() async -> [SegmentResult] {
        let live = lock.withLock { (liveSessionID, liveTail, liveFallbackSegments) }
        if let id = live.0 {
            await live.1?.value
            let text = try? await runtime.finishSession(id: id)
            lock.withLock {
                liveSessionID = nil
                liveTail = nil
                liveTranscriptHandler = nil
                liveFallbackSegments = []
            }
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lock.withLock { selectedPath = .liveStream }
                return [SegmentResult(index: 0, text: text, precedingSilence: 0)]
            }
            let fallback = await transcribeFallback(live.2)
            lock.withLock { selectedPath = .batchSegment }
            return fallback
        }
        var results: [SegmentResult] = []
        for entry in registry.snapshot().sorted(by: { $0.index < $1.index }) {
            results.append(SegmentResult(index: entry.index, text: await entry.task.value,
                                         precedingSilence: entry.precedingSilence))
        }
        lock.withLock { selectedPath = .batchSegment }
        return results
    }

    func selectedTranscriptionPath() -> DictationTranscriptionPath? {
        lock.withLock { selectedPath }
    }

    private func transcribeFallback(_ segments: [DeferredBatchSegment]) async -> [SegmentResult] {
        var results: [SegmentResult] = []
        for segment in segments.sorted(by: { $0.index < $1.index }) {
            let text = try? await runtime.transcribe(fileURL: segment.url, vocabularyTerms: lock.withLock { vocabularyTerms })
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

    func reset() {
        registry.cancelAll()
        let live = lock.withLock { () -> (UUID?, Task<Void, Never>?) in
            let result = (liveSessionID, liveTail)
            liveSessionID = nil
            liveTail = nil
            liveTranscriptHandler = nil
            liveFallbackSegments = []
            selectedPath = nil
            return result
        }
        live.1?.cancel()
        if let id = live.0 {
            let runtime = self.runtime
            Task { await runtime.cancelSession(id: id) }
        }
    }
}
