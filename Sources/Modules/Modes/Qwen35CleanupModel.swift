import Foundation

/// Optional cleanup candidate. Pin the conversion, tokenizer and chat template together.
enum Qwen35CleanupModel {
    static let repository = "mlx-community/Qwen3.5-4B-6bit"
    static let revision = "fbb1092aa9daef007603ea9273cd24c225a409f1"
    static let modelID = "\(repository)@\(revision)"
    static let artifacts: [CleanupModelArtifact] = [
        .init(name: "chat_template.jinja", bytes: 7756, sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
        .init(name: "config.json", bytes: 3366, sha256: "86e6f28f1b175e5b088ca648a089cc00b15adbfa45cd4a65228ba97e07779fc6"),
        .init(name: "model.safetensors", bytes: 4085498443, sha256: "0fefe2844ed7c9201da4927a1930147669b05b24ca819bfe593e6e3b03fc33f0"),
        .init(name: "model.safetensors.index.json", bytes: 101944, sha256: "a81689f1901b3aa1ccb894c270d7bb30db471073b8b36f7d92c161f02b3a1980"),
        .init(name: "preprocessor_config.json", bytes: 390, sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
        .init(name: "processor_config.json", bytes: 1300, sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
        .init(name: "tokenizer.json", bytes: 19989343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
        .init(name: "tokenizer_config.json", bytes: 1139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
        .init(name: "video_preprocessor_config.json", bytes: 385, sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
        .init(name: "vocab.json", bytes: 6722759, sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
    ]
    static let manifest = CleanupModelManifest(repository: repository, revision: revision, artifacts: artifacts)
    static let model = CleanupModelDescriptor(
        id: ModeCleanupChoice(rawValue: "localQwen35_4B")!, name: "Qwen3.5 4B", format: "Candidate · MLX 6-bit · ≈4.1 GB",
        detail: "Cleanup candidate using your mode's prompt, vocabulary hints, and enabled context. Thinking is off. Explicit word replacements apply first. Downloading does not change your selected model.",
        inputLimitDescription: "8,192 input tokens", promptPolicy: .modeInstructions,
        usageModelID: modelID, directoryName: "Qwen3.5-4B-6bit")
    static let configuration = MLXCleanupConfiguration(inputTokenLimit: 8_192, outputTokenLimit: 2_048,
        inputByteLimit: 100_000, timeout: 30, additionalContext: ["enable_thinking": false],
        forbiddenOutput: ["<|", "<think>", "</think>"])
    static let registration = LocalCleanupRegistration.mlx(model: model, manifest: manifest, configuration: configuration)
}
