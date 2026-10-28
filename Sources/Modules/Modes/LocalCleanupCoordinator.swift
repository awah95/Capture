import Foundation

struct LocalCleanupRequest: Sendable {
    var choice: ModeCleanupChoice
    var systemMessage: String
    var temperature: Double
}

protocol LocalCleanCompleting: Sendable {
    func clean(_ transcript: String) async throws -> String
    func clean(_ transcript: String, request: LocalCleanupRequest) async throws -> String
}

protocol ManagedLocalCleanup: LocalCleanCompleting {
    func prepare() async throws
    func unload() async
    func availability() async -> LocalModelAvailability
    func download(progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void) async throws
    func removeModel() async throws
}

enum CleanupMemoryState: Equatable, Sendable {
    case unloaded, loading, ready, failed(String)
}

/// A gate spans awaits so previews, prewarming and dictation cannot load two
/// cleanup models simultaneously. Actor isolation alone permits that reentrancy.
actor LocalCleanupCoordinator: LocalCleanCompleting {
    static let shared = LocalCleanupCoordinator()
    nonisolated let registry: LocalCleanupRegistry
    private let runtimes: [ModeCleanupChoice: any ManagedLocalCleanup]
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var downloads: [ModeCleanupChoice: Task<Void, Error>] = [:]
    private var loaded: ModeCleanupChoice?
    private var observers: [UUID: AsyncStream<[ModeCleanupChoice: CleanupMemoryState]>.Continuation] = [:]
    private var states: [ModeCleanupChoice: CleanupMemoryState] = [:] {
        didSet { for observer in observers.values { observer.yield(states) } }
    }

    init(registry: LocalCleanupRegistry = .builtIn,
         runtimes: [ModeCleanupChoice: any ManagedLocalCleanup]? = nil) {
        self.registry = registry
        self.runtimes = runtimes ?? Dictionary(uniqueKeysWithValues:
            registry.registrations.map { ($0.model.id, $0.makeRuntime(nil)) })
    }

    func memoryUpdates() -> AsyncStream<[ModeCleanupChoice: CleanupMemoryState]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[ModeCleanupChoice: CleanupMemoryState]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(states)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func acquire() async throws {
        if occupied { await withCheckedContinuation { waiters.append($0) } }
        else { occupied = true }
        do {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
        } catch { release(); throw error }
    }

    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }

    private func runtime(_ choice: ModeCleanupChoice) throws -> any ManagedLocalCleanup {
        guard registry.model(choice) != nil, let runtime = runtimes[choice] else {
            throw LocalCleanupError.unavailable(choice)
        }
        return runtime
    }

    func memoryState(_ choice: ModeCleanupChoice) -> CleanupMemoryState {
        states[choice] ?? .unloaded
    }

    func availability(_ choice: ModeCleanupChoice) async -> LocalModelAvailability {
        (try? await runtime(choice).availability()) ?? LocalModelAvailability(isDownloaded: false, updateAvailable: false)
    }

    private func load(_ choice: ModeCleanupChoice) async throws {
        guard choice != .currentMode else { return }
        let model = try runtime(choice)
        guard downloads[choice] == nil else { throw LocalModelBusyError() }
        if loaded == choice { return }
        if let previous = loaded {
            try await runtime(previous).unload()
            states[previous] = .unloaded
            loaded = nil
        }
        states[choice] = .loading
        do {
            try await model.prepare()
            try Task.checkCancellation()
            loaded = choice
            states[choice] = .ready
        } catch {
            await model.unload()
            states[choice] = .failed(error.localizedDescription)
            throw error
        }
    }

    func prepare(_ choice: ModeCleanupChoice) async throws {
        guard choice != .currentMode else { return }
        try await acquire()
        defer { release() }
        try await load(choice)
    }

    func clean(_ transcript: String) async throws -> String {
        try await clean(transcript, request: .init(choice: .localS1Mini, systemMessage: "", temperature: 0))
    }

    func clean(_ transcript: String, request: LocalCleanupRequest) async throws -> String {
        try await acquire()
        defer { release() }
        guard request.choice != .currentMode else { return transcript }
        if transcript.contains(TranscriptStitcher.failureMarker) { return transcript }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        try await load(request.choice)
        return try await runtime(request.choice).clean(transcript, request: request)
    }

    func download(_ choice: ModeCleanupChoice, progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void) async throws {
        try await acquire()
        let model: any ManagedLocalCleanup
        do { model = try runtime(choice) }
        catch { release(); throw error }
        guard downloads[choice] == nil else { release(); throw LocalModelBusyError() }
        if loaded == choice {
            await model.unload()
            loaded = nil
            states[choice] = .unloaded
        }
        let work = Task { try await model.download(progress: progress) }
        downloads[choice] = work
        // Downloads do not own model weights. Let dictation use the other model
        // while network I/O runs, but forbid loading/removing the downloading one.
        release()
        defer { downloads[choice] = nil }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        // A failed prewarm before installation must not hide Settings' Load action
        // after the model has been downloaded successfully.
        states[choice] = .unloaded
    }

    func remove(_ choice: ModeCleanupChoice) async throws {
        try await acquire()
        defer { release() }
        guard downloads[choice] == nil else { throw LocalModelBusyError() }
        try await runtime(choice).removeModel()
        if loaded == choice { loaded = nil }
        states[choice] = .unloaded
    }

    func shutdown() async {
        // Invalidate queued operations before waiting for active generation to end.
        closed = true
        if occupied { await withCheckedContinuation { waiters.append($0) } }
        else { occupied = true }
        defer { release() }
        let pending = Array(downloads.values)
        for download in pending { download.cancel() }
        for download in pending { _ = await download.result }
        for runtime in runtimes.values { await runtime.unload() }
        loaded = nil
        states = [:]
    }
}

extension ModeCleanupChoice {
    var usageModelID: String { LocalCleanupRegistry.builtIn.model(self)?.usageModelID ?? rawValue }
    func usage(elapsed: TimeInterval, outcome: DictationUsageOutcome,
               registry: LocalCleanupRegistry = .builtIn) -> DictationUsageEntry {
        let modelID = registry.model(self)?.usageModelID ?? rawValue
        return DictationUsageEntry(stage: .refinement, providerID: rawValue,
            requestedModelID: modelID, actualModelID: registry.model(self) == nil ? nil : modelID,
            promptTokens: nil, completionTokens: nil, reasoningTokens: 0,
            cachedTokens: nil, costUSD: 0, costKind: .noCharge, generationID: nil,
            latencyMs: Int(max(0, elapsed) * 1_000), outcome: outcome)
    }
}
