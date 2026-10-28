import XCTest
@testable import Captur

final class LocalCleanupRegistryTests: XCTestCase {
    func testShippedAndUnknownChoicesKeepTheirStringEncoding() throws {
        for value in ["currentMode", "localS1Mini", "localGemma", "future-model"] {
            let data = try JSONEncoder().encode(value)
            let choice = try JSONDecoder().decode(ModeCleanupChoice.self, from: data)
            XCTAssertEqual(choice.rawValue, value)
            XCTAssertEqual(try JSONEncoder().encode(choice), data)
        }
    }

    @MainActor
    func testUnknownModelSurvivesModeStoreAndUnrelatedSaves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let unknown = ModeCleanupChoice(rawValue: "future-model")!
        let store = ModeStore(directory: root)
        var builtin = Mode.email
        builtin.cleanupChoice = unknown
        store.update(builtin)
        var custom = builtin
        custom.id = "future-custom"
        custom.isBuiltIn = false
        store.update(custom)
        let reopened = ModeStore(directory: root)
        XCTAssertNil(reopened.recoveryWarning)
        XCTAssertEqual(reopened.mode(id: builtin.id)?.cleanupChoice, unknown)
        XCTAssertEqual(reopened.mode(id: custom.id)?.cleanupChoice, unknown)
        var other = Mode.message
        other.name = "Unrelated rename"
        reopened.update(other)
        let again = ModeStore(directory: root)
        XCTAssertNil(again.recoveryWarning)
        XCTAssertEqual(again.mode(id: custom.id)?.cleanupChoice, unknown)
        XCTAssertEqual(again.mode(id: builtin.id)?.cleanupChoice, unknown)
        XCTAssertTrue(builtin.usesLocalCleanup)
        XCTAssertFalse(builtin.usesProviderRefinement)
        XCTAssertFalse(builtin.usesModePrompt)
        var context = ContextSnapshot.empty
        context.selectedText = "Private reference"
        XCTAssertNil(context.filtered(for: builtin, enabled: true).selectedText)
        let model = ModesViewModel(store: again)
        model.select(modeID: custom.id)
        XCTAssertTrue(model.cleanupChoices.contains(unknown))
        XCTAssertNil(model.cleanupDescriptor)
    }

    func testThirdModelRoutesSwitchesReusesWeightsAndShutsDown() async throws {
        let log = RegistryTestOwnership()
        let a = RegistryTestRuntime("a", ownership: log)
        let b = RegistryTestRuntime("b", ownership: log)
        let c = RegistryTestRuntime("c", ownership: log)
        let third = CleanupTestModels.third
        let registry = CleanupTestModels.registry
        let coordinator = LocalCleanupCoordinator(registry: registry,
            runtimes: [.localS1Mini: a, .localGemma: b, third.id: c])
        XCTAssertEqual(registry.choices, LocalCleanupRegistry.builtIn.choices + [third.id])
        try await coordinator.prepare(.localS1Mini)
        try await coordinator.prepare(.localGemma)
        try await coordinator.prepare(third.id)
        let request = LocalCleanupRequest(choice: third.id, systemMessage: "Keep this instruction", temperature: 0.4)
        let output = try await coordinator.clean("raw", request: request)
        XCTAssertEqual(output, "Third model result")
        let requests = await c.requests
        XCTAssertEqual(requests.first?.systemMessage, request.systemMessage)
        XCTAssertEqual(requests.first?.temperature, 0.4)
        let prepares = await c.prepares
        XCTAssertEqual(prepares, 1)
        let peak = await log.peak
        XCTAssertEqual(peak, 1)
        let usage = third.id.usage(elapsed: 0.2, outcome: .succeeded, registry: registry)
        XCTAssertEqual(usage.requestedModelID, third.usageModelID)
        XCTAssertEqual(usage.actualModelID, third.usageModelID)
        XCTAssertEqual(usage.providerID, third.id.rawValue)
        XCTAssertEqual(usage.costUSD, 0)
        try await coordinator.remove(third.id)
        let removed = await c.removed
        XCTAssertEqual(removed, 1)
        await coordinator.shutdown()
        let live = await log.live
        XCTAssertTrue(live.isEmpty)
        for runtime in [a, b, c] {
            let unloaded = await runtime.unloaded
            XCTAssertGreaterThan(unloaded, 0)
        }
        do { try await coordinator.prepare(third.id); XCTFail("Shutdown must prevent reload") }
        catch is CancellationError {}
    }

    func testUnknownModelNeverRoutesToS1OrUnloadsTheActiveModel() async throws {
        let log = RegistryTestOwnership()
        let s1 = RegistryTestRuntime("s1", ownership: log)
        let coordinator = LocalCleanupCoordinator(runtimes: [.localS1Mini: s1])
        try await coordinator.prepare(.localS1Mini)
        let unknown = ModeCleanupChoice(rawValue: "missing")!
        for operation in 0..<4 {
            do {
                switch operation {
                case 0: try await coordinator.prepare(unknown)
                case 1: _ = try await coordinator.clean("raw", request: .init(choice: unknown, systemMessage: "", temperature: 0))
                case 2: try await coordinator.download(unknown) { _ in XCTFail("No download") }
                default: try await coordinator.remove(unknown)
                }
                XCTFail("Unknown model must fail")
            } catch LocalCleanupError.unavailable(let id) { XCTAssertEqual(id, unknown) }
        }
        let live = await log.live
        let requests = await s1.requests
        XCTAssertEqual(live, ["s1"])
        XCTAssertTrue(requests.isEmpty)
        let availability = await coordinator.availability(unknown)
        XCTAssertFalse(availability.isDownloaded)
        XCTAssertNil(unknown.usage(elapsed: 0, outcome: .failed).actualModelID)
        await coordinator.shutdown()
    }

    @MainActor
    func testThirdModelPreviewUsesPromptVocabularyAndNoCredentials() async throws {
        let registry = CleanupTestModels.registry
        let third = CleanupTestModels.third
        let runtime = RegistryTestRuntime()
        let coordinator = LocalCleanupCoordinator(registry: registry, runtimes: [third.id: runtime])
        var mode = Mode.clean
        mode.cleanupChoice = third.id
        mode.systemPrompt = "Make two bullets."
        mode.includeAppNameContext = true
        let term = VocabularyTerm(id: UUID(), text: "CapturVocabularyFixture", soundsLike: nil,
            isPinned: false, useCount: 0, lastUsed: nil, appBundleIDs: [])
        let runner = ModePreviewRunner(refinement: FakeChatClient(),
            apiKey: { _ in XCTFail("No cloud credentials"); return nil },
            vocabularyTerms: { [term] }, clipboard: { XCTFail("No live clipboard in preview"); return nil },
            localCleanup: coordinator, cleanupRegistry: registry)
        let result = await runner.run(mode: mode, source: .init(rawText: "first and second", targetAppName: "Editor"))
        XCTAssertEqual(try result.get(), "Third model result")
        let requests = await runtime.requests
        XCTAssertTrue(try XCTUnwrap(requests.first).systemMessage.contains("Make two bullets."))
        XCTAssertTrue(try XCTUnwrap(requests.first).systemMessage.contains("Editor"))
        XCTAssertTrue(try XCTUnwrap(requests.first).systemMessage.contains(term.text))
        var context = ContextSnapshot.empty
        context.selectedText = "Reference"
        mode.contextOptions.selectedText = true
        XCTAssertEqual(context.filtered(for: mode, enabled: true, registry: registry).selectedText, "Reference")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ModesViewModel(store: ModeStore(directory: root), cleanupRegistry: registry)
        XCTAssertTrue(model.cleanupChoices.contains(third.id))
        await coordinator.shutdown()
    }

    func testProbeReportsFailureAndUnloadsAfterAFixtureError() async throws {
        let runtime = RegistryTestRuntime()
        await runtime.failCleanup()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let third = CleanupTestModels.third
        let registry = LocalCleanupRegistry([.init(model: third) { _ in runtime }])
        let succeeded = await CleanupProbe.run(arguments: ["--probe-cleanup", third.id.rawValue,
            "--model-directory", root.path], registry: registry)
        XCTAssertFalse(succeeded)
        let unloaded = await runtime.unloaded
        XCTAssertGreaterThan(unloaded, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testProbeReportsSuccessForCompletedFixturesAndFailureForUnavailableModels() async throws {
        let runtime = RegistryTestRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let third = CleanupTestModels.third
        let registry = LocalCleanupRegistry([.init(model: third) { _ in runtime }])
        let succeeded = await CleanupProbe.run(arguments: ["--probe-cleanup", third.id.rawValue,
            "--model-directory", root.path], registry: registry)
        XCTAssertTrue(succeeded)
        let missing = await CleanupProbe.run(arguments: ["--probe-cleanup", "localGemma", "--model-directory", root.path])
        XCTAssertFalse(missing)
        let unknown = await CleanupProbe.run(arguments: ["--probe-cleanup", "unknown", "--model-directory", root.path])
        XCTAssertFalse(unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testQwenCandidatePersistsAndUsesModeInstructionsThroughLocalPreview() async throws {
        let descriptor = Qwen35CleanupModel.model
        let registry = LocalCleanupRegistry.builtIn
        XCTAssertNotNil(registry.registration(descriptor.id))
        try Qwen35CleanupModel.manifest.validate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var mode = Mode.clean
        mode.cleanupChoice = descriptor.id
        mode.systemPrompt = "Rewrite as two concise bullets."
        let store = ModeStore(directory: root)
        store.update(mode)
        let reopened = ModeStore(directory: root)
        let saved = try XCTUnwrap(reopened.mode(id: mode.id))
        XCTAssertEqual(saved.cleanupChoice, descriptor.id)
        XCTAssertTrue(saved.usesModePrompt)
        XCTAssertFalse(saved.usesProviderRefinement)
        let editor = ModesViewModel(store: reopened)
        XCTAssertTrue(editor.cleanupChoices.contains(descriptor.id))
        let local = StubLocalCleanup(.success("Qwen fixture output"))
        let runner = ModePreviewRunner(refinement: FakeChatClient(),
            apiKey: { _ in XCTFail("Qwen preview must not read cloud credentials"); return nil },
            vocabularyTerms: { [] }, clipboard: { XCTFail("No live clipboard for preview"); return nil }, localCleanup: local)
        let result = await runner.run(mode: saved, source: .init(rawText: "first and second", targetAppName: nil))
        XCTAssertEqual(try result.get(), "Qwen fixture output")
        let requests = await local.requests
        XCTAssertEqual(requests.first?.choice, descriptor.id)
        XCTAssertTrue(try XCTUnwrap(requests.first).systemMessage.contains(mode.systemPrompt))
        let usage = descriptor.id.usage(elapsed: 0.2, outcome: .succeeded)
        XCTAssertEqual(usage.requestedModelID, Qwen35CleanupModel.modelID)
        XCTAssertEqual(usage.costKind, .noCharge)
    }

    func testProbeSelectsOnlyRegisteredModelsAndRequiresIsolatedRoot() throws {
        let options = try CleanupProbe.Options(arguments: ["--probe-cleanup", CleanupTestModels.third.id.rawValue,
            "--model-directory", "/tmp/captur-third-probe", "--fixtures", "/tmp/fixtures.json"], registry: CleanupTestModels.registry)
        XCTAssertEqual(options.choice, CleanupTestModels.third.id)
        XCTAssertEqual(options.root.path, "/tmp/captur-third-probe")
        XCTAssertFalse(options.download)
        XCTAssertThrowsError(try CleanupProbe.Options(arguments: ["--probe-cleanup", "missing", "--model-directory", "/tmp/x"]))
        XCTAssertThrowsError(try CleanupProbe.Options(arguments: ["--probe-cleanup", "localGemma"]))
    }
}
