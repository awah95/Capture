import Foundation
@testable import Captur

actor RegistryTestOwnership {
    var live: Set<String> = []
    var peak = 0
    func load(_ name: String) { live.insert(name); peak = max(peak, live.count) }
    func unload(_ name: String) { live.remove(name) }
}

actor RegistryTestRuntime: ManagedLocalCleanup {
    let name: String
    let ownership: RegistryTestOwnership
    var installed = false
    var prepares = 0
    var removed = 0
    var unloaded = 0
    var requests: [LocalCleanupRequest] = []
    var downloading = false
    var holdDownload = false
    var failGeneration = false
    var failDownload = false
    var progressCallback: (@Sendable (LocalModelDownloadProgress) -> Void)?

    init(_ name: String = "third", ownership: RegistryTestOwnership = RegistryTestOwnership()) {
        self.name = name
        self.ownership = ownership
    }
    func setInstalled(_ value: Bool) { installed = value }
    func holdNextDownload() { holdDownload = true }
    func failNextDownload() { failDownload = true }
    func failCleanup() { failGeneration = true }
    func availability() -> LocalModelAvailability { .init(isDownloaded: installed, updateAvailable: false) }
    func prepare() async throws { prepares += 1; await ownership.load(name) }
    func unload() async { unloaded += 1; await ownership.unload(name) }
    func removeModel() async { removed += 1; installed = false; await unload() }
    func download(progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void) async throws {
        downloading = true
        defer { downloading = false }
        progressCallback = progress
        progress(.fraction(0.5, detail: "Fixture download"))
        if holdDownload { try await Task.sleep(for: .seconds(60)) }
        if failDownload { failDownload = false; throw LocalCleanupError.invalidDownload(name) }
        installed = true
    }
    func sendLateProgress() { progressCallback?(.fraction(0.9, detail: "Stale progress")) }
    func clean(_ transcript: String) async throws -> String { try await clean(transcript, request: .init(choice: CleanupTestModels.third.id, systemMessage: "", temperature: 0)) }
    func clean(_ transcript: String, request: LocalCleanupRequest) async throws -> String {
        requests.append(request)
        if failGeneration { throw LocalCleanupError.incompleteOutput(name) }
        return "Third model result"
    }
}

enum CleanupTestModels {
    static let third = CleanupModelDescriptor(
        id: ModeCleanupChoice(rawValue: "testThirdModel")!, name: "Third test model", format: "Test-only",
        detail: "Uses mode instructions", inputLimitDescription: "512 input tokens",
        promptPolicy: .modeInstructions, usageModelID: "test/third@pinned-revision", directoryName: "TestThird")
    static let registry = LocalCleanupRegistry(LocalCleanupRegistry.builtIn.registrations + [
        LocalCleanupRegistration(model: third) { _ in RegistryTestRuntime() },
    ])
}
