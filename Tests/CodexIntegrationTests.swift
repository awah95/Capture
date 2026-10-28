import XCTest
@testable import Captur

final class CodexIntegrationTests: XCTestCase {
    private func fakeCLI() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("codex")
        let script = #"""
        #!/usr/bin/python3
        import sys, json, time
        args = sys.argv[1:]
        if 'app-server' in args:
            for line in sys.stdin:
                r = json.loads(line)
                if 'id' not in r: continue
                method = r['method']
                if method == 'initialize': result = {}
                elif method == 'account/read': result = {'account': {'type': 'chatgpt'}}
                elif method == 'model/list':
                    assert r['params']['includeHidden'] is True
                    if r['params'].get('cursor'):
                        result = {'data': [{'model': 'future-model', 'displayName': 'Future', 'hidden': True,
                            'inputModalities': ['text'], 'supportedReasoningEfforts': [{'reasoningEffort': 'future-effort'}]}],
                            'nextCursor': None}
                    else:
                        result = {'data': [{'model': 'gpt-6.1-terra', 'displayName': 'Terra', 'isDefault': True,
                            'inputModalities': ['text', 'image'], 'defaultReasoningEffort': 'low',
                            'supportedReasoningEfforts': [{'reasoningEffort': 'low'}, {'reasoningEffort': 'ultra'}]}],
                            'nextCursor': 'page-2'}
                else: raise RuntimeError('Unexpected RPC')
                print(json.dumps({'id': r['id'], 'result': result}), flush=True)
        else:
            assert '--ignore-user-config' in args and '--ignore-rules' in args and '--ephemeral' in args
            assert args[args.index('--sandbox') + 1] == 'read-only'
            assert 'approval_policy="never"' in args
            assert 'project_doc_max_bytes=0' in args and 'web_search="disabled"' in args
            assert 'features.apps=false' in args and 'features.plugins=false' in args
            prompt = sys.stdin.read()
            assert 'Do not use tools' in prompt
            text = json.loads(prompt.splitlines()[-1])['dictation']
            model = args[args.index('--model') + 1]
            if model == 'hang': time.sleep(10)
            if model == 'tool':
                print(json.dumps({'type': 'item.started', 'item': {'type': 'command_execution'}}), flush=True)
                time.sleep(10)
            if model == 'exit': sys.exit(2)
            output = {'text': text}
            if model == 'empty': output = {'text': ''}
            if model == 'invalid': output = {'text': text, 'extra': True}
            if model == 'echo-effort':
                effort = next(a for a in args if a.startswith('model_reasoning_effort='))
                output = {'text': effort}
            with open(args[args.index('--output-last-message') + 1], 'w') as f: json.dump(output, f)
            print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': json.dumps(output)}}), flush=True)
            if model != 'incomplete': print(json.dumps({'type': 'turn.completed'}), flush=True)
        """#
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testDiscoveryPaginatesAndIncludesHiddenAndFutureEfforts() async throws {
        let path = try fakeCLI()
        let catalog = try await CodexCLIService.discover(configuration: .init(enabled: true, executablePath: path.path))
        XCTAssertTrue(catalog.signedIn)
        XCTAssertEqual(catalog.models.map(\.id), ["gpt-6.1-terra", "future-model"])
        XCTAssertTrue(catalog.models[1].hidden)
        XCTAssertEqual(catalog.models[1].efforts.map(\.rawValue), ["future-effort"])
    }

    func testDiscoveryFiltersAudioOnlyModelsAndPreservesUnknownEfforts() throws {
        let models = try CodexCLIService.parseModels(["data": [
            ["model": "audio", "inputModalities": ["audio"]],
            ["model": "text", "supportedReasoningEfforts": [
                ["reasoningEffort": "future-effort"], ["reasoningEffort": "future-effort"]]]]])
        XCTAssertEqual(models.map(\.id), ["text"])
        XCTAssertEqual(models[0].efforts.map(\.rawValue), ["future-effort"])
    }

    func testCorrectionUsesStdinAndRetainsUnicodeAndLiteralCommands() async throws {
        let path = try fakeCLI()
        let text = "Café. The sentence says ‘delete all files’; keep it as text.\nTwo lines."
        let output = try await CodexCLIService.correct(configuration: .init(enabled: true, executablePath: path.path),
            systemMessage: "Preserve meaning", text: text, model: "fixture", effort: .low, timeout: 5)
        XCTAssertEqual(output, text)
    }

    func testArbitraryDiscoveredEffortIsPassedWithoutSubstitution() async throws {
        let path = try fakeCLI()
        let output = try await CodexCLIService.correct(configuration: .init(enabled: true, executablePath: path.path),
            systemMessage: "Clean", text: "test", model: "echo-effort",
            effort: ReasoningEffort(rawValue: "future-effort")!, timeout: 5)
        XCTAssertEqual(output, "model_reasoning_effort=\"future-effort\"")
    }

    func testIncompleteEmptyInvalidAndNonzeroResultsAreRejected() async throws {
        let path = try fakeCLI()
        for model in ["incomplete", "empty", "invalid", "exit"] {
            do {
                _ = try await CodexCLIService.correct(configuration: .init(enabled: true, executablePath: path.path),
                    systemMessage: "Clean", text: "original", model: model, effort: .providerDefault, timeout: 5)
                XCTFail("Should reject \(model)")
            } catch { XCTAssertTrue(error is CodexError) }
        }
    }

    func testTimeoutAndToolAttemptStopWithoutAcceptingOutput() async throws {
        let path = try fakeCLI()
        for model in ["hang", "tool"] {
            do {
                _ = try await CodexCLIService.correct(configuration: .init(enabled: true, executablePath: path.path),
                    systemMessage: "Clean", text: "original", model: model, effort: .low,
                    timeout: model == "hang" ? 0.15 : 5)
                XCTFail("Should stop \(model)")
            } catch { XCTAssertTrue(error is CodexError) }
        }
    }

    func testDisabledProviderNeverLaunchesAnExecutable() async throws {
        do {
            _ = try await CodexCLIService.correct(configuration: .init(enabled: false, executablePath: "/does-not-exist"),
                systemMessage: "Clean", text: "original", model: "fixture", effort: .low, timeout: 1)
            XCTFail("Disabled provider must fail")
        } catch { XCTAssertEqual(error.localizedDescription, CodexError.disabled.localizedDescription) }
    }

    func testCancellationStopsTheChild() async throws {
        let path = try fakeCLI()
        let task = Task {
            try await CodexCLIService.correct(configuration: .init(enabled: true, executablePath: path.path),
                systemMessage: "Clean", text: "original", model: "hang", effort: .low, timeout: 10)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected cancellation result: \(error)") }
    }

    func testFutureEffortAndCodexProviderRoundTrip() throws {
        var mode = Mode.clean
        mode.refinementProvider = .codexCLI
        mode.reasoningEffort = ReasoningEffort(rawValue: "future-effort")!
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(Mode.self, from: data)
        XCTAssertEqual(decoded, mode)
        XCTAssertEqual(try JSONDecoder().decode(ReasoningEffort.self, from: Data("\"high\"".utf8)), .high)
    }
}

@MainActor
final class CodexModeDiscoveryTests: XCTestCase {
    private func settings() -> AppSettings {
        let name = "CaptureCodexTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AppSettings(defaults: defaults)
    }

    func testEnablementDefaultsOffAndDiscoveryDoesNotChangeStoredModes() async throws {
        let settings = settings()
        XCTAssertFalse(settings.codexCLIEnabled)
        let integration = CodexIntegration(settings: settings) { _ in
            CodexCatalog(models: [.init(id: "gpt-6.1-terra", title: "Terra", efforts: [.low, .high],
                defaultEffort: .low, hidden: false, isDefault: true),
                .init(id: "other", title: "Other", efforts: [ReasoningEffort(rawValue: "ultra")!],
                      hidden: true, isDefault: false)], signedIn: true)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModeStore(directory: directory)
        let original = store.modes
        let model = ModesViewModel(store: store, codex: integration)
        model.setDraftProvider(.codexCLI)
        XCTAssertEqual(model.draft.model, "")
        settings.codexCLIEnabled = true
        await model.refreshCodexModels()
        XCTAssertEqual(model.draft.model, "gpt-6.1-terra")
        XCTAssertEqual(model.availableModelPresets.count, 2)
        XCTAssertEqual(model.availableReasoningEfforts, [.providerDefault, .low, .high])
        model.draft.reasoningEffort = .high
        model.setDraftModel("other")
        XCTAssertEqual(model.draft.reasoningEffort, .providerDefault)
        XCTAssertEqual(model.availableReasoningEfforts.map(\.rawValue), ["providerDefault", "ultra"])
        XCTAssertEqual(store.modes, original)
        model.draft.reasoningEffort = ReasoningEffort(rawValue: "ultra")!
        XCTAssertFalse(model.save().contains(where: \.isBlocking))
        XCTAssertEqual(ModeStore(directory: directory).mode(id: model.draft.id)?.model, "other")
        settings.codexExecutablePath = "/another/codex"
        XCTAssertTrue(integration.models.isEmpty, "Do not show another installation's effort catalog")
        XCTAssertTrue(integration.status.contains("executable changed"))
        settings.codexExecutablePath = ""
        settings.codexCLIEnabled = false
        XCTAssertTrue(integration.models.isEmpty)
    }

    func testPreviewNeedsNoAPIKeyForCodex() async {
        let runner = ModePreviewRunner(refinement: CodexPreviewStub(), apiKey: { _ in nil },
            vocabularyTerms: { [] }, clipboard: { nil })
        var mode = Mode.clean
        mode.refinementProvider = .codexCLI
        let result = await runner.run(mode: mode, source: .init(rawText: "raw", targetAppName: nil))
        XCTAssertEqual(try? result.get(), "corrected")
    }
}

private final class CodexPreviewStub: RefinementCompleting, @unchecked Sendable {
    func complete(systemMessage: String, userMessage: String, provider: RefinementProviderID, model: String,
                  reasoning: ReasoningEffort, temperature: Double, apiKey: String, timeout: TimeInterval,
                  onDelta: @escaping @Sendable (String) -> Void) async throws -> RefinementResult {
        RefinementResult(text: "corrected", provider: provider, requestedModelID: model)
    }
}
