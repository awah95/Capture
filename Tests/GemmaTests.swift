import XCTest
@testable import Captur

private actor CleanupOwnershipLog {
    var live: Set<String> = []
    var peak = 0
    func load(_ name: String) { live.insert(name); peak = max(peak, live.count) }
    func unload(_ name: String) { live.remove(name) }
}

private actor TestManagedCleanup: ManagedLocalCleanup {
    let name: String
    let ownership: CleanupOwnershipLog
    var prepares = 0
    var requests: [LocalCleanupRequest] = []
    var held: CheckedContinuation<Void, Never>?
    var holdGeneration = false
    var holdDownload = false
    var downloading = false
    var generating = false
    var missing = false
    init(_ name: String, ownership: CleanupOwnershipLog) { self.name = name; self.ownership = ownership }
    func availability() -> LocalModelAvailability { .init(isDownloaded: true, updateAvailable: false) }
    func prepare() async throws {
        prepares += 1
        if missing { throw LocalCleanupError.notDownloaded("Test") }
        await ownership.load(name)
    }
    func markMissing() { missing = true }
    func unload() async { await ownership.unload(name) }
    func download(progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void) async throws {
        downloading = true
        defer { downloading = false }
        if holdDownload { try await Task.sleep(for: .seconds(60)) }
        missing = false
    }
    func holdNextDownload() { holdDownload = true }
    func removeModel() async { await unload() }
    func clean(_ transcript: String) async -> String { transcript }
    func clean(_ transcript: String, request: LocalCleanupRequest) async -> String {
        requests.append(request)
        generating = true
        if holdGeneration { await withCheckedContinuation { held = $0 } }
        generating = false
        return "Rewritten: \(transcript)"
    }
    func hold() { holdGeneration = true }
    func release() { held?.resume(); held = nil; holdGeneration = false }
}

final class GemmaTests: XCTestCase {
    func testDownloadAfterMissingModelFailureRestoresManualLoadState() async throws {
        for choice in [ModeCleanupChoice.localGemma, .localS1Mini] {
            let log = CleanupOwnershipLog()
            let model = TestManagedCleanup("model", ownership: log)
            let coordinator = LocalCleanupCoordinator(runtimes: [.localS1Mini: model, .localGemma: model])
            await model.markMissing()
            do { try await coordinator.prepare(choice); XCTFail("Expected missing model") }
            catch LocalCleanupError.notDownloaded {}
            let failed = await coordinator.memoryState(choice)
            guard case .failed = failed else { return XCTFail("Expected failed memory state") }
            try await coordinator.download(choice) { _ in }
            let afterDownload = await coordinator.memoryState(choice)
            XCTAssertEqual(afterDownload, .unloaded)
            try await coordinator.prepare(choice)
            let afterLoad = await coordinator.memoryState(choice)
            XCTAssertEqual(afterLoad, .ready)
            await coordinator.shutdown()
        }
    }

    func testSameSizeCorruptionMakesGemmaEligibleForRepairDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Sparse files match the manifest sizes without allocating model weights.
        for artifact in GemmaModel.artifacts {
            let url = root.appendingPathComponent(artifact.name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(artifact.bytes))
            try handle.close()
        }
        try Data(GemmaModel.revision.utf8).write(to: root.appendingPathComponent("captur-model-version.txt"))
        let runtime = MLXCleanupRuntime(model: LocalCleanupRegistry.gemma, manifest: GemmaModel.manifest, configuration: .gemma, root: root)
        let before = await runtime.availability()
        XCTAssertTrue(before.isDownloaded)
        XCTAssertFalse(before.updateAvailable)
        do { try await runtime.prepare(); XCTFail("Expected checksum failure") }
        catch LocalCleanupError.invalidDownload {}
        let after = await runtime.availability()
        XCTAssertTrue(!after.isDownloaded || after.updateAvailable,
                      "Settings must offer download/update and download() must replace the corrupt installation")
        let reopened = MLXCleanupRuntime(model: LocalCleanupRegistry.gemma, manifest: GemmaModel.manifest, configuration: .gemma, root: root)
        let persisted = await reopened.availability()
        XCTAssertTrue(!persisted.isDownloaded || persisted.updateAvailable)
    }

    func testSwitchingKeepsOneModelAndReusesWarmWeights() async throws {
        let log = CleanupOwnershipLog()
        let s1 = TestManagedCleanup("s1", ownership: log)
        let gemma = TestManagedCleanup("gemma", ownership: log)
        let coordinator = LocalCleanupCoordinator(runtimes: [.localS1Mini: s1, .localGemma: gemma])
        try await coordinator.prepare(.localGemma)
        try await coordinator.prepare(.localGemma)
        let prepares = await gemma.prepares
        XCTAssertEqual(prepares, 1)
        try await coordinator.prepare(.localS1Mini)
        var live = await log.live
        XCTAssertEqual(live, ["s1"])
        try await coordinator.prepare(.localGemma)
        live = await log.live
        XCTAssertEqual(live, ["gemma"])
        let peak = await log.peak
        XCTAssertEqual(peak, 1)
        await coordinator.shutdown()
        live = await log.live
        XCTAssertTrue(live.isEmpty)
    }

    func testConcurrentSwitchWaitsForActiveGeneration() async throws {
        let log = CleanupOwnershipLog()
        let s1 = TestManagedCleanup("s1", ownership: log)
        let gemma = TestManagedCleanup("gemma", ownership: log)
        let coordinator = LocalCleanupCoordinator(runtimes: [.localS1Mini: s1, .localGemma: gemma])
        await gemma.hold()
        let generation = Task { try await coordinator.clean("hello", request: .init(choice: .localGemma, systemMessage: "Rewrite", temperature: 0)) }
        while !(await gemma.generating) { await Task.yield() }
        let switchModel = Task { try await coordinator.prepare(.localS1Mini) }
        // Give the competing request a chance to enter the coordinator at an await.
        for _ in 0..<20 { await Task.yield() }
        let prepares = await s1.prepares
        XCTAssertEqual(prepares, 0)
        await gemma.release()
        _ = try await generation.value
        try await switchModel.value
        let peak = await log.peak
        XCTAssertEqual(peak, 1)
        await coordinator.shutdown()
    }

    func testThirdModelSwitchWaitsForGenerationAndPreservesSingleOwnership() async throws {
        let log = CleanupOwnershipLog()
        let s1 = TestManagedCleanup("s1", ownership: log)
        let gemma = TestManagedCleanup("gemma", ownership: log)
        let third = TestManagedCleanup("third", ownership: log)
        let id = CleanupTestModels.third.id
        let coordinator = LocalCleanupCoordinator(registry: CleanupTestModels.registry,
            runtimes: [.localS1Mini: s1, .localGemma: gemma, id: third])
        try await coordinator.prepare(.localS1Mini)
        await gemma.hold()
        let generation = Task { try await coordinator.clean("hello", request: .init(choice: .localGemma, systemMessage: "Rewrite", temperature: 0)) }
        while !(await gemma.generating) { await Task.yield() }
        let switchModel = Task { try await coordinator.prepare(id) }
        for _ in 0..<20 { await Task.yield() }
        let before = await third.prepares
        XCTAssertEqual(before, 0)
        await gemma.release()
        _ = try await generation.value
        try await switchModel.value
        let peak = await log.peak
        let live = await log.live
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(live, ["third"])
        await coordinator.shutdown()
    }

    func testCancelledQueuedRequestNeverLoadsAnotherModel() async throws {
        let log = CleanupOwnershipLog()
        let s1 = TestManagedCleanup("s1", ownership: log)
        let gemma = TestManagedCleanup("gemma", ownership: log)
        let coordinator = LocalCleanupCoordinator(runtimes: [.localS1Mini: s1, .localGemma: gemma])
        await gemma.hold()
        let generation = Task { try await coordinator.clean("hello", request: .init(choice: .localGemma, systemMessage: "Rewrite", temperature: 0)) }
        while !(await gemma.generating) { await Task.yield() }
        let queued = Task { try await coordinator.prepare(.localS1Mini) }
        queued.cancel()
        await gemma.release()
        _ = try await generation.value
        do { try await queued.value; XCTFail("Expected cancellation") } catch is CancellationError {} 
        let prepares = await s1.prepares
        XCTAssertEqual(prepares, 0)
        await coordinator.shutdown()
    }

    func testDownloadingOtherModelDoesNotBlockDictation() async throws {
        let log = CleanupOwnershipLog()
        let s1 = TestManagedCleanup("s1", ownership: log)
        let gemma = TestManagedCleanup("gemma", ownership: log)
        let coordinator = LocalCleanupCoordinator(runtimes: [.localS1Mini: s1, .localGemma: gemma])
        try await coordinator.prepare(.localS1Mini)
        await gemma.holdNextDownload()
        let download = Task { try await coordinator.download(.localGemma) { _ in } }
        while !(await gemma.downloading) { await Task.yield() }
        let completed = expectation(description: "S1 dictation completes while Gemma downloads")
        let request = Task {
            _ = try await coordinator.clean("hello")
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        download.cancel()
        _ = await download.result
        try await request.value
        let live = await log.live
        XCTAssertEqual(live, ["s1"])
        await coordinator.shutdown()
    }

    func testShutdownCancelsDownloadsAndPreventsReloading() async throws {
        let log = CleanupOwnershipLog()
        let gemma = TestManagedCleanup("gemma", ownership: log)
        let coordinator = LocalCleanupCoordinator(runtimes: [.localS1Mini: TestManagedCleanup("s1", ownership: log), .localGemma: gemma])
        await gemma.holdNextDownload()
        let download = Task { try await coordinator.download(.localGemma) { _ in } }
        while !(await gemma.downloading) { await Task.yield() }
        await coordinator.shutdown()
        do { try await download.value; XCTFail("Download must be cancelled") } catch is CancellationError {}
        do { try await coordinator.prepare(.localGemma); XCTFail("Shutdown must prohibit reload") } catch is CancellationError {}
        let live = await log.live
        XCTAssertTrue(live.isEmpty)
    }

    func testGemmaModePreservesPromptContextAndLocalTelemetry() throws {
        var mode = Mode.clean
        mode.cleanupChoice = .localGemma
        mode.systemPrompt = "Rewrite in two short bullets."
        mode.contextOptions.selectedText = true
        XCTAssertTrue(mode.usesLocalCleanup)
        XCTAssertTrue(mode.usesModePrompt)
        XCTAssertFalse(mode.usesProviderRefinement)
        let decoded = try JSONDecoder().decode(Mode.self, from: JSONEncoder().encode(mode))
        XCTAssertEqual(decoded, mode)
        var snapshot = ContextSnapshot.empty
        snapshot.selectedText = "Reference selection"
        XCTAssertEqual(snapshot.filtered(for: mode, enabled: true).selectedText, "Reference selection")
        XCTAssertNil(snapshot.filtered(for: mode, enabled: false).selectedText)
        let usage = mode.cleanupChoice.usage(elapsed: 0.25, outcome: .succeeded)
        XCTAssertEqual(usage.providerID, "localGemma")
        XCTAssertEqual(usage.requestedModelID, GemmaModel.modelID)
        XCTAssertEqual(usage.costUSD, 0)
    }

    @MainActor
    func testGemmaPreviewUsesActualInstructionsWithoutCredentials() async throws {
        let log = CleanupOwnershipLog()
        let gemma = TestManagedCleanup("gemma", ownership: log)
        let coordinator = LocalCleanupCoordinator(runtimes: [.localS1Mini: TestManagedCleanup("s1", ownership: log), .localGemma: gemma])
        var mode = Mode.clean
        mode.cleanupChoice = .localGemma
        mode.systemPrompt = "Rewrite in two short bullets."
        let runner = ModePreviewRunner(refinement: FakeChatClient(), apiKey: { _ in XCTFail("Local preview must not read credentials"); return nil },
            vocabularyTerms: { [] }, clipboard: { nil }, localCleanup: coordinator)
        let result = await runner.run(mode: mode, source: .init(rawText: "first and second", targetAppName: nil))
        XCTAssertEqual(try result.get(), "Rewritten: first and second")
        let requests = await gemma.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].systemMessage.contains(mode.systemPrompt))
        XCTAssertTrue(requests[0].systemMessage.contains(Mode.cleanAntiInjectionClause))
        XCTAssertEqual(requests[0].choice, .localGemma)
        await coordinator.shutdown()
    }

    func testCorruptGemmaArtifactIsRejectedAndMissingModelStaysOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("bad")
        try Data("bad".utf8).write(to: bad)
        XCTAssertThrowsError(try CleanupModelInstaller.validate(bad, artifact: GemmaModel.artifacts[0]))
        let runtime = MLXCleanupRuntime(model: LocalCleanupRegistry.gemma, manifest: GemmaModel.manifest, configuration: .gemma, root: root)
        do { try await runtime.prepare(); XCTFail("Missing model") } catch is LocalCleanupError {}
        let available = await runtime.availability()
        XCTAssertFalse(available.isDownloaded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["bad"])
    }
}
