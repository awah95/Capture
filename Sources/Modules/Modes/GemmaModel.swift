import Foundation

/// Immutable model artifacts; no network lookup occurs while dictating.
enum GemmaModel {
    static let repository = "mlx-community/gemma-4-E2B-it-qat-4bit"
    static let revision = "42f62737af7a9fd8c1d55d79666c1a217be4e2e2"
    static let modelID = "\(repository)@\(revision)"
    static let artifacts: [CleanupModelArtifact] = [
        .init(name: "chat_template.jinja", bytes: 16804, sha256: "33204f1acb5bd0002713e16a593847f24ceeafe711ed88bda2a352dc996a3373"),
        .init(name: "config.json", bytes: 31198, sha256: "e996bc6f3887d18d1176438680b17c24e988576d5c15a43ccf3a482a737a8f7e"),
        .init(name: "generation_config.json", bytes: 203, sha256: "b69207f9be617e982d13cc273cce6fd88c98dda99a4bdc5e2d52ffe0a0d9f0a9"),
        .init(name: "model.safetensors", bytes: 4329240325, sha256: "d52e64b9cb669c65da88c1597fe12ab90e63ab9f79cc1b053eb1fa8bb06c493f"),
        .init(name: "model.safetensors.index.json", bytes: 218323, sha256: "8ee3112362c6dfa13a26df2da4592c0a9aa541013918469accd86d7e8a54b11a"),
        .init(name: "processor_config.json", bytes: 902, sha256: "1bd0d00776284f369c1eff5fb631e865dfcdca861e0b7d60dbef27fcf37436a8"),
        .init(name: "tokenizer.json", bytes: 32169626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
        .init(name: "tokenizer_config.json", bytes: 2740, sha256: "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656"),
    ]
    static let manifest = CleanupModelManifest(repository: repository, revision: revision, artifacts: artifacts)
}

extension MLXCleanupConfiguration {
    static let gemma = Self(inputTokenLimit: 8_192, outputTokenLimit: 2_048,
        inputByteLimit: 100_000, timeout: 30, additionalContext: ["enable_thinking": false],
        forbiddenOutput: ["<|", "<think>", "<channel|>", "<turn|>"])
}
