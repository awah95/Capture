import Foundation

/// Stable persisted selection. Unknown IDs survive catalog changes in registry-aware builds.
struct ModeCleanupChoice: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
    static let currentMode = Self(rawValue: "currentMode")!
    static let localS1Mini = Self(rawValue: "localS1Mini")!
    static let localGemma = Self(rawValue: "localGemma")!

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let choice = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Empty cleanup model ID")
        }
        self = choice
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    var title: String { title(in: .builtIn) }
    func title(in registry: LocalCleanupRegistry) -> String {
        if self == .currentMode { return "Mode's AI provider" }
        return registry.model(self).map { "\($0.name) (local)" } ?? "Unavailable local model (\(rawValue))"
    }
}

enum CleanupPromptPolicy: Sendable {
    case fixedNormalization, modeInstructions
}

struct CleanupModelDescriptor: Identifiable, Sendable {
    let id: ModeCleanupChoice
    let name: String
    let format: String
    let detail: String
    let inputLimitDescription: String
    let promptPolicy: CleanupPromptPolicy
    let usageModelID: String
    let directoryName: String

    var defaultRoot: URL {
        AppPaths.supportDirectory().appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }
}

struct LocalCleanupRegistration: Sendable {
    let model: CleanupModelDescriptor
    /// A root override keeps probes/tests isolated from the user's installation.
    let makeRuntime: @Sendable (URL?) -> any ManagedLocalCleanup

    static func mlx(model: CleanupModelDescriptor, manifest: CleanupModelManifest,
                    configuration: MLXCleanupConfiguration) -> Self {
        Self(model: model) { root in
            MLXCleanupRuntime(model: model, manifest: manifest, configuration: configuration,
                              root: root ?? model.defaultRoot)
        }
    }
}

/// Finite, ordered, app-owned registrations. Runtime instances belong to a coordinator.
struct LocalCleanupRegistry: Sendable {
    let registrations: [LocalCleanupRegistration]
    var models: [CleanupModelDescriptor] { registrations.map(\.model) }
    var choices: [ModeCleanupChoice] { [.currentMode] + models.map(\.id) }

    init(_ registrations: [LocalCleanupRegistration]) {
        precondition(!registrations.contains { $0.model.id == .currentMode }, "Reserved cleanup ID")
        precondition(Set(registrations.map { $0.model.id }).count == registrations.count, "Duplicate cleanup ID")
        let directories = registrations.map { $0.model.directoryName }
        precondition(directories.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") }, "Unsafe cleanup directory")
        precondition(Set(directories.map { $0.lowercased() }).count == directories.count, "Shared cleanup directory")
        self.registrations = registrations
    }
    func model(_ id: ModeCleanupChoice) -> CleanupModelDescriptor? {
        registrations.first { $0.model.id == id }?.model
    }
    func registration(_ id: ModeCleanupChoice) -> LocalCleanupRegistration? {
        registrations.first { $0.model.id == id }
    }

    // Add a supported model here. Views, routing, telemetry and shutdown read this registry.
    static let builtIn = Self([
        LocalCleanupRegistration(model: s1Mini) { root in S1MiniRuntime(root: root ?? s1Mini.defaultRoot) },
        .mlx(model: gemma, manifest: GemmaModel.manifest, configuration: .gemma),
        Qwen35CleanupModel.registration,
    ])

    static let s1Mini = CleanupModelDescriptor(
        id: .localS1Mini, name: "S1-mini by Superwhisper", format: "v1 · Q4_K_M · 462 MiB",
        detail: "Cleans English dictation into standard prose. Custom prompts, vocabulary hints, and context are saved but do not apply. Explicit word replacements apply first.",
        inputLimitDescription: "1,000 transcript tokens", promptPolicy: .fixedNormalization,
        usageModelID: S1MiniModel.modelID, directoryName: "S1-mini")
    static let gemma = CleanupModelDescriptor(
        id: .localGemma, name: "Gemma 4 E2B", format: "QAT · MLX 4-bit · ≈4.36 GB",
        detail: "Rewrites using your mode's prompt, vocabulary hints, and enabled context. Thinking is off for fast responses. Explicit word replacements apply first.",
        inputLimitDescription: "8,192 input tokens", promptPolicy: .modeInstructions,
        usageModelID: GemmaModel.modelID, directoryName: "Gemma-4-E2B")
}

enum LocalCleanupError: LocalizedError {
    case unavailable(ModeCleanupChoice)
    case notDownloaded(String)
    case invalidDownload(String)
    case inputTooLong(String, Int)
    case incompleteOutput(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let id): return "Local cleanup model '\(id.rawValue)' is unavailable in this build. Choose a model in Modes. The original text was kept."
        case .notDownloaded(let name): return "Download \(name) in Settings before using this mode."
        case .invalidDownload(let name): return "\(name) download failed verification. Retry the download."
        case .inputTooLong(let name, let limit): return "This input exceeds \(name)'s \(limit)-token cleanup limit. The original text was kept."
        case .incompleteOutput(let name): return "\(name) did not return a complete rewrite. The original text was kept."
        case .timedOut(let name): return "\(name) cleanup timed out. The original text was kept."
        }
    }
}
