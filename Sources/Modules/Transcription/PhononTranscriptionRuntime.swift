import CoreML
import Foundation
import PhononCoreML

enum PhononError: LocalizedError {
    case notDownloaded, verificationFailed, streamingUnsupported

    var errorDescription: String? {
        switch self {
        case .notDownloaded: return "Download and prepare Phonon-2 in Settings → Transcription first."
        case .verificationFailed: return "Phonon-2 model verification failed. Download the model again in Settings."
        case .streamingUnsupported: return "Phonon-2 Core ML supports English batch transcription, without live text."
        }
    }
}

protocol PhononTranscribing: AnyObject, Sendable {
    func transcribe(fileURL: URL) throws -> String
}

/// Only the runtime actor calls this synchronous native instance. Construction is
/// on its preparation worker; no audio callback or main-actor work loads Core ML.
private final class NativePhononModel: PhononTranscribing, @unchecked Sendable {
    private let transcriber: PhononCoreML.Transcriber

    init(root: URL, progress: @escaping @Sendable (String) -> Void) throws {
        // Own the compiled cache beside the verified weights. Upstream otherwise
        // writes a second cache outside our model folder, which Remove could not clear.
        let compiled = root.appendingPathComponent("Phonon-2.mlmodelc", isDirectory: true)
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: compiled.path) {
                progress("Compiling Phonon-2 for this Mac — first preparation can take several minutes…")
                let temporary = try MLModel.compileModel(at: root.appendingPathComponent("Phonon-2.mlpackage"))
                defer { try? fm.removeItem(at: temporary) }
                try fm.moveItem(at: temporary, to: compiled)
            }
            var options = PhononCoreML.Transcriber.Options()
            options.computeUnits = .cpuAndNeuralEngine
            options.eagerFunctions = [5, 10, 15, 35]
            options.backgroundLoad = false
            options.progress = { phase, _ in progress("Preparing Phonon-2: \(phase)…") }
            transcriber = try PhononCoreML.Transcriber(bundle: root, options: options)
        } catch {
            // An OS/Core ML upgrade can invalidate a compiled cache. A later Prepare
            // retries compilation, keeping the checksum-verified source weights.
            try? fm.removeItem(at: compiled)
            throw error
        }
    }

    func transcribe(fileURL: URL) throws -> String {
        try transcriber.transcribe(url: fileURL).text
    }
}

actor PhononTranscriptionRuntime: LocalTranscriptionRunning {
    static let shared = PhononTranscriptionRuntime()
    typealias Loader = @Sendable (URL, @escaping @Sendable (String) -> Void) throws -> any PhononTranscribing

    private let root: URL
    private let manifest: CleanupModelManifest
    private let loader: Loader
    private var model: (any PhononTranscribing)?
    private var preparation: Task<any PhononTranscribing, Error>?
    private var activeTranscriptions = 0

    init(supportDirectory: URL = AppPaths.supportDirectory(),
         manifest: CleanupModelManifest = PhononModel.manifest,
         loader: @escaping Loader = { try NativePhononModel(root: $0, progress: $1) }) {
        root = supportDirectory.appendingPathComponent("Models/Phonon2", isDirectory: true)
        self.manifest = manifest
        self.loader = loader
    }

    func availability() -> LocalModelAvailability {
        CleanupModelInstaller.availability(root: root, manifest: manifest)
    }

    /// Inference and startup never silently download weights. Settings explicitly
    /// opts in through the progress overload, which downloads, verifies and prepares.
    func prepare() async throws { try await prepare(allowDownload: false, progress: nil) }

    func prepare(progress: (@Sendable (LocalModelDownloadProgress) -> Void)?) async throws {
        try await prepare(allowDownload: true, progress: progress)
    }

    private func prepare(allowDownload: Bool,
                         progress: (@Sendable (LocalModelDownloadProgress) -> Void)?) async throws {
        try Task.checkCancellation()
        if model != nil { return }
        if let preparation {
            let loaded = try await preparation.value
            try Task.checkCancellation()
            model = loaded
            return
        }
        let task = Task.detached(priority: .utility) { [root, manifest, loader] in
            if !CleanupModelInstaller.availability(root: root, manifest: manifest).isDownloaded {
                guard allowDownload else { throw PhononError.notDownloaded }
                try await CleanupModelInstaller.download(to: root, manifest: manifest, name: "Phonon-2") {
                    progress?($0)
                }
            }
            try Task.checkCancellation()
            do { try CleanupModelInstaller.verifyInstalled(root: root, manifest: manifest) }
            catch is CancellationError { throw CancellationError() }
            catch { throw PhononError.verificationFailed }
            let loaded = try loader(root) { detail in progress?(.fraction(1, detail: detail)) }
            try Task.checkCancellation()
            return loaded
        }
        preparation = task
        defer { preparation = nil }
        // Native Core ML compilation/decode has no interruption API. Keep ownership
        // until it returns; cancellation still prevents accepting or inserting output.
        let loaded = try await task.value
        try Task.checkCancellation()
        model = loaded
    }

    func removeModel() throws {
        guard preparation == nil, activeTranscriptions == 0 else { throw LocalModelBusyError() }
        model = nil
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func transcribe(fileURL: URL) async throws -> String {
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        try await prepare()
        try Task.checkCancellation()
        guard let model else { throw PhononError.notDownloaded }
        let text = try model.transcribe(fileURL: fileURL)
        try Task.checkCancellation()
        return text
    }

    func startStreamingSession(id: UUID, vocabularyTerms: [String]) async throws {
        throw PhononError.streamingUnsupported
    }
    func appendStreamingAudio(sessionID: UUID, samples: [Float], sampleRate: Double) async throws -> String? {
        throw PhononError.streamingUnsupported
    }
    func finishStreamingSession(id: UUID) async throws -> String { throw PhononError.streamingUnsupported }
    func cancelStreamingSession(id: UUID) async {}
}
