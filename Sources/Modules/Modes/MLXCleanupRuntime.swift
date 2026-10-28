import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

/// Text-only MLX loading skips the checkpoint's vision/audio encoders. Every call
/// prepares a new input and KV cache; only model weights survive between calls.
struct MLXCleanupConfiguration: Sendable {
    let inputTokenLimit: Int
    let outputTokenLimit: Int
    let inputByteLimit: Int
    let timeout: TimeInterval
    let additionalContext: [String: any Sendable]
    let forbiddenOutput: [String]


}

actor MLXCleanupRuntime: ManagedLocalCleanup {
    private let model: CleanupModelDescriptor
    private let manifest: CleanupModelManifest
    private let configuration: MLXCleanupConfiguration
    private let root: URL
    private var container: ModelContainer?

    init(model: CleanupModelDescriptor, manifest: CleanupModelManifest,
         configuration: MLXCleanupConfiguration, root: URL) {
        precondition(configuration.inputTokenLimit > 0 && configuration.outputTokenLimit > 0 &&
                     configuration.inputByteLimit > 0 && configuration.timeout.isFinite && configuration.timeout > 0)
        self.model = model
        self.manifest = manifest
        self.configuration = configuration
        self.root = root
    }

    func availability() -> LocalModelAvailability {
        CleanupModelInstaller.availability(root: root, manifest: manifest)
    }

    func download(progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void) async throws {
        if availability().isDownloaded && !availability().updateAvailable { return }
        do { try await CleanupModelInstaller.download(to: root, manifest: manifest, name: model.name, progress: progress) }
        catch is CleanupInstallationError { throw LocalCleanupError.invalidDownload(model.name) }
    }

    func prepare() async throws {
        try Task.checkCancellation()
        if container != nil { return }
        guard availability().isDownloaded, !availability().updateAvailable else {
            throw LocalCleanupError.notDownloaded(model.name)
        }
        do { try CleanupModelInstaller.verifyInstalled(root: root, manifest: manifest) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LocalCleanupError.invalidDownload(model.name) }
        container = try await LLMModelFactory.shared.loadContainer(
            from: root, using: #huggingFaceTokenizerLoader())
    }

    func unload() {
        container = nil
        Memory.clearCache()
    }

    func removeModel() throws {
        unload()
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func clean(_ transcript: String) async throws -> String {
        try await clean(transcript, request: .init(choice: model.id,
            systemMessage: Mode.clean.systemPrompt, temperature: 0.2))
    }

    func clean(_ transcript: String, request: LocalCleanupRequest) async throws -> String {
        try Task.checkCancellation()
        if transcript.contains(TranscriptStitcher.failureMarker) { return transcript }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        guard transcript.utf8.count + request.systemMessage.utf8.count <= configuration.inputByteLimit,
              request.temperature.isFinite, (0...2).contains(request.temperature)
        else { throw LocalCleanupError.inputTooLong(model.name, configuration.inputTokenLimit) }
        try await prepare()
        guard let container else { throw LocalCleanupError.notDownloaded(model.name) }
        let configuration = self.configuration
        let model = self.model
        let (stream, worker) = try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(
                chat: [.system(request.systemMessage), .user(transcript)],
                additionalContext: configuration.additionalContext))
            guard input.text.tokens.size <= configuration.inputTokenLimit else { throw LocalCleanupError.inputTooLong(model.name, configuration.inputTokenLimit) }
            let parameters = GenerateParameters(maxTokens: configuration.outputTokenLimit, temperature: Float(request.temperature))
            let iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
            return MLXLMCommon.generateTask(promptTokenCount: input.text.tokens.size,
                modelConfiguration: context.configuration, tokenizer: context.tokenizer, iterator: iterator)
        }
        let deadline = Date().addingTimeInterval(configuration.timeout)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(configuration.timeout)); worker.cancel() }
            catch { /* Normal completion cancels the watchdog. */ }
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            var output = ""
            var completed = false
            var hasToolCall = false
            for await generation in stream {
                switch generation {
                case .chunk(let text): output += text
                case .info(let info): completed = info.stopReason == .stop
                case .toolCall: hasToolCall = true
                }
            }
            // Never let a model switch/unload race unfinished GPU computation.
            await worker.value
            try Task.checkCancellation()
            guard Date() < deadline else { throw LocalCleanupError.timedOut(model.name) }
            guard completed, !hasToolCall else { throw LocalCleanupError.incompleteOutput(model.name) }
            let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty, !configuration.forbiddenOutput.contains(where: result.contains)
            else { throw LocalCleanupError.incompleteOutput(model.name) }
            return result
        } onCancel: { worker.cancel() }
    }
}
