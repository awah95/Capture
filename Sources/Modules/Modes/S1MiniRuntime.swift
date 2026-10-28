import Foundation
import llama

enum S1MiniError: LocalizedError {
    case notDownloaded, invalidDownload, loadFailed, inputTooLong, generationFailed, timedOut
    var errorDescription: String? {
        switch self {
        case .notDownloaded: return "Download S1-mini by Superwhisper in Settings before using local cleanup."
        case .invalidDownload: return "S1-mini download failed its integrity check. Try downloading again."
        case .loadFailed: return "S1-mini could not load on this Mac."
        case .inputTooLong: return "This transcript exceeds S1-mini's 1,000-token dictation limit. The original text was kept."
        case .generationFailed: return "S1-mini could not complete cleanup. The original text was kept."
        case .timedOut: return "S1-mini cleanup timed out. The original text was kept."
        }
    }
}

enum S1MiniModel {
    static let revision = "34add00a48a2e5d24e5a4ee5405a99620a3a240c"
    static let fileName = "s1-mini-q4_k_m.gguf"
    static let bytes = 484_219_808
    static let sha256 = "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"
    static let modelID = "superwhisper/s1-mini-GGUF@\(revision)/\(fileName)"
    static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
    static let controlLine = "[Styling: semi-formal] [Structure: prose] [Context: general]"
    static let assistantPrefix = "<|im_start|>assistant\n<think>\n\n</think>\n\n"

    static func prompt(_ transcript: String) -> String {
        "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(controlLine)\n\(transcript)<|im_end|>\n\(assistantPrefix)"
    }

    static func usage(elapsed: TimeInterval, outcome: DictationUsageOutcome) -> DictationUsageEntry {
        DictationUsageEntry(stage: .refinement, providerID: "localS1Mini",
            requestedModelID: modelID, actualModelID: modelID,
            promptTokens: nil, completionTokens: nil, reasoningTokens: 0,
            cachedTokens: nil, costUSD: 0, costKind: .noCharge, generationID: nil,
            latencyMs: Int(max(0, elapsed) * 1_000), outcome: outcome)
    }

    static let manifest = CleanupModelManifest(repository: "superwhisper/s1-mini-GGUF", revision: revision,
        artifacts: [.init(name: fileName, bytes: Int64(bytes), sha256: sha256)])

    static func validate(file: URL) throws {
        do { try CleanupModelInstaller.validate(file, artifact: manifest.artifacts[0]) }
        catch is CancellationError { throw CancellationError() }
        catch { throw S1MiniError.invalidDownload }
    }
}

/// Serialized native model ownership. No network is reachable from `clean`.
/// The model stays warm; each request gets a fresh context and greedy sampler.
actor S1MiniRuntime: ManagedLocalCleanup {
    static let shared = S1MiniRuntime()
    private let root: URL
    private var model: OpaquePointer?
    private var downloading = false
    private var isShuttingDown = false
    private var modelURL: URL { root.appendingPathComponent(S1MiniModel.fileName) }

    init(root: URL = AppPaths.supportDirectory().appendingPathComponent("Models/S1-mini", isDirectory: true)) {
        self.root = root
    }
    deinit { if let model { llama_model_free(model) } }

    /// Awaited before AppKit exits so Metal resources precede native global teardown.
    /// Actor isolation lets any active inference release its context first.
    func shutdown() {
        isShuttingDown = true
        if let model { llama_model_free(model); self.model = nil }
    }

    func unload() {
        if let model { llama_model_free(model); self.model = nil }
    }

    func prepare() throws {
        guard !isShuttingDown else { throw CancellationError() }
        if model != nil { return }
        guard availability().isDownloaded, !availability().updateAvailable else { throw S1MiniError.notDownloaded }
        do { try CleanupModelInstaller.verifyInstalled(root: root, manifest: S1MiniModel.manifest) }
        catch is CancellationError { throw CancellationError() }
        catch { throw S1MiniError.invalidDownload }
        llama_backend_init()
        var params = llama_model_default_params()
        params.n_gpu_layers = 99
        model = llama_model_load_from_file(modelURL.path, params)
        guard model != nil else { throw S1MiniError.loadFailed }
    }

    func availability() -> LocalModelAvailability {
        CleanupModelInstaller.availability(root: root, manifest: S1MiniModel.manifest)
    }

    func download(progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void) async throws {
        guard !isShuttingDown else { throw CancellationError() }
        guard !downloading else { throw LocalModelBusyError() }
        if availability().isDownloaded && !availability().updateAvailable { return }
        downloading = true
        defer { downloading = false }
        do {
            try await CleanupModelInstaller.download(to: root, manifest: S1MiniModel.manifest,
                name: "S1-mini by Superwhisper", progress: progress)
        } catch is CancellationError { throw CancellationError() }
        catch is CleanupInstallationError { throw S1MiniError.invalidDownload }
        if let model { llama_model_free(model); self.model = nil }
    }

    /// This specialized model deliberately uses its fixed prompt, never mode instructions.
    func clean(_ transcript: String, request: LocalCleanupRequest) async throws -> String {
        try await clean(transcript)
    }

    func removeModel() throws {
        guard !isShuttingDown else { throw CancellationError() }
        guard !downloading else { throw LocalModelBusyError() }
        if let model { llama_model_free(model); self.model = nil }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func clean(_ transcript: String) async throws -> String {
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        // A missing ASR segment must remain visible and retryable in History.
        if transcript.contains(TranscriptStitcher.failureMarker) { return transcript }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        // Bound work before tokenization and reject chat delimiters in raw ASR text.
        guard transcript.utf8.count <= 16_000,
              !transcript.contains("<|"), !transcript.contains("<think>"), !transcript.contains("</think>")
        else { throw S1MiniError.inputTooLong }
        let deadline = Date().addingTimeInterval(30)
        try prepare()
        guard let model, let vocab = llama_model_get_vocab(model) else { throw S1MiniError.loadFailed }
        let rawTokens = try tokenize(transcript, vocab: vocab, special: false)
        guard rawTokens.count <= 1_000 else { throw S1MiniError.inputTooLong }
        var tokens = try tokenize(S1MiniModel.prompt(transcript), vocab: vocab, special: true)
        var params = llama_context_default_params()
        params.n_ctx = 2_560
        params.n_batch = 2_048
        params.n_ubatch = 512
        params.n_threads = 4
        params.n_threads_batch = 4
        guard let context = llama_init_from_model(model, params) else { throw S1MiniError.loadFailed }
        defer { llama_free(context) }
        guard let sampler = llama_sampler_init_greedy() else { throw S1MiniError.loadFailed }
        defer { llama_sampler_free(sampler) }
        var output = Data()
        let limit = Int(Double(rawTokens.count) * 1.3) + 32
        for step in 0...limit {
            try Task.checkCancellation()
            guard Date() < deadline else { throw S1MiniError.timedOut }
            let code = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            guard code == 0 else { throw S1MiniError.generationFailed }
            try Task.checkCancellation()
            guard Date() < deadline else { throw S1MiniError.timedOut }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                let result = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.contains("<think>"), !result.contains("</think>"), !result.contains("<|") else { throw S1MiniError.generationFailed }
                return result
            }
            guard step < limit else { throw S1MiniError.generationFailed } // Never insert truncated output.
            var piece = [CChar](repeating: 0, count: 256)
            let count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            guard count >= 0 else { throw S1MiniError.generationFailed }
            output.append(contentsOf: piece.prefix(Int(count)).map { UInt8(bitPattern: $0) })
            tokens = [token]
        }
        throw S1MiniError.generationFailed
    }

    private func tokenize(_ text: String, vocab: OpaquePointer, special: Bool) throws -> [llama_token] {
        var tokens = [llama_token](repeating: 0, count: text.utf8.count + 16)
        let count = text.withCString { pointer in
            llama_tokenize(vocab, pointer, Int32(text.utf8.count), &tokens, Int32(tokens.count), false, special)
        }
        guard count >= 0 else { throw S1MiniError.generationFailed }
        return Array(tokens.prefix(Int(count)))
    }
}
