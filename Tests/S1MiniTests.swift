import XCTest
@testable import Captur

actor StubLocalCleanup: LocalCleanCompleting {
    private(set) var calls: [String] = []
    private(set) var requests: [LocalCleanupRequest] = []
    let result: Result<String, Error>
    init(_ result: Result<String, Error>) { self.result = result }
    func clean(_ transcript: String, request: LocalCleanupRequest) async throws -> String {
        requests.append(request)
        return try await clean(transcript)
    }
    func clean(_ transcript: String) async throws -> String {
        calls.append(transcript)
        return try result.get()
    }
}

@MainActor
final class HeldLocalCleanup: LocalCleanCompleting {
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func clean(_ transcript: String) async throws -> String {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
        return "Cleaned text."
    }
    func clean(_ transcript: String, request: LocalCleanupRequest) async throws -> String {
        try await clean(transcript)
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class S1MiniTests: XCTestCase {
    func testLegacyPreferenceIsReadWithoutChangingTranscriptionOrWritingDefaults() {
        let suite = "S1MiniTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(TranscriptionProvider.localMoonshine.rawValue, forKey: "captur.transcriptionProvider")
        XCTAssertEqual(AppSettings(defaults: defaults).legacyCleanCleanupChoice, .currentMode)
        XCTAssertNil(defaults.object(forKey: "captur.cleanCleanupChoice"))
        defaults.set("localS1Mini", forKey: "captur.cleanCleanupChoice")
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.legacyCleanCleanupChoice, .localS1Mini)
        XCTAssertEqual(reloaded.transcriptionProvider, .localMoonshine)
        defaults.set("futureModel", forKey: "captur.cleanCleanupChoice")
        XCTAssertEqual(AppSettings(defaults: defaults).legacyCleanCleanupChoice, .currentMode)
    }

    func testLocalCleanupIsOptInForEveryAIModeAndNeverChangesPassThrough() {
        for original in Mode.builtIns {
            var mode = original
            XCTAssertFalse(mode.usesLocalCleanup)
            mode.cleanupChoice = .localS1Mini
            XCTAssertEqual(mode.usesLocalCleanup, mode.usesLLM)
            XCTAssertFalse(mode.usesProviderRefinement)
        }
        var custom = Mode.clean
        custom.id = "custom"
        custom.cleanupChoice = .localS1Mini
        XCTAssertTrue(custom.usesLocalCleanup)
    }

    func testRequiredPromptAndThinkingDisabledPrefix() {
        let raw = "um ship thursday"
        let expected = "<|im_start|>system\nYou are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.<|im_end|>\n<|im_start|>user\n[Styling: semi-formal] [Structure: prose] [Context: general]\num ship thursday<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        XCTAssertEqual(S1MiniModel.prompt(raw), expected)
        XCTAssertEqual(S1MiniModel.revision.count, 40)
        XCTAssertEqual(S1MiniModel.sha256.count, 64)
    }

    func testMissingModelDoesNotDownloadAndBlankInputNeedsNoModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = S1MiniRuntime(root: root)
        let blank = try await runtime.clean(" \n ")
        XCTAssertEqual(blank, "")
        do { _ = try await runtime.clean("hello"); XCTFail("Expected missing model") }
        catch { XCTAssertTrue(error is S1MiniError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testPartialTranscriptBypassesNativeModelEvenForFillerOnlyText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = S1MiniRuntime(root: root)
        for text in ["send the report […] on thursday", "[…] the second half", "um […] uh"] {
            let result = try await runtime.clean(text)
            XCTAssertEqual(result, text)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testShutdownIsIdempotentPreservesFilesAndRejectsFurtherWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("captur-model-version.txt")
        try Data("installed version".utf8).write(to: sentinel)
        let runtime = S1MiniRuntime(root: root)
        await runtime.shutdown()
        await runtime.shutdown()
        do { _ = try await runtime.clean("hello"); XCTFail("Shutdown must prohibit reloading") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { try await runtime.download { _ in XCTFail("No download after shutdown") }; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "installed version")
    }

    func testCorruptDownloadIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("bad model".utf8).write(to: url)
        XCTAssertThrowsError(try S1MiniModel.validate(file: url))
    }

    func testLocalPreviewNeedsNoAPIKeyAndAcceptsEmptyResult() async {
        let local = StubLocalCleanup(.success(""))
        let runner = ModePreviewRunner(refinement: FakeChatClient(), apiKey: { _ in XCTFail("No key read"); return nil },
            vocabularyTerms: { XCTFail("No vocabulary read"); return [] }, clipboard: { XCTFail("No clipboard read"); return nil },
            localCleanup: local)
        var mode = Mode.clean
        mode.cleanupChoice = .localS1Mini
        let result = await runner.run(mode: mode, source: .init(rawText: "um", targetAppName: nil))
        switch result {
        case .success(let value): XCTAssertEqual(value, "")
        case .failure(let error): XCTFail("\(error)")
        }
        let calls = await local.calls
        XCTAssertEqual(calls, ["um"])
    }

    func testPartialPreviewKeepsMarkerWithoutInvokingCleanup() async throws {
        let local = StubLocalCleanup(.success(""))
        let runner = ModePreviewRunner(refinement: FakeChatClient(), apiKey: { _ in XCTFail("No key read"); return nil },
            vocabularyTerms: { [] }, clipboard: { nil },
            localCleanup: local)
        let text = "um […] uh"
        var mode = Mode.clean
        mode.cleanupChoice = .localS1Mini
        let result = await runner.run(mode: mode, source: .init(rawText: text, targetAppName: nil))
        XCTAssertEqual(try result.get(), text)
        let calls = await local.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testLocalUsageIsNoChargeAndPinned() {
        let usage = S1MiniModel.usage(elapsed: 0.25, outcome: .failed)
        XCTAssertEqual(usage.costKind, .noCharge)
        XCTAssertEqual(usage.costUSD, 0)
        XCTAssertEqual(usage.providerID, "localS1Mini")
        XCTAssertEqual(usage.latencyMs, 250)
        XCTAssertEqual(usage.outcome, .failed)
        XCTAssertTrue(usage.requestedModelID.contains(S1MiniModel.revision))
    }

    func testCustomLocalPreviewBypassesCloudAndReportsMissingModel() async throws {
        var custom = Mode.email
        custom.id = "custom"
        custom.cleanupChoice = .localS1Mini
        let chat = FakeChatClient()
        let runner = ModePreviewRunner(refinement: chat,
            apiKey: { _ in XCTFail("Local preview must not read credentials"); return nil },
            vocabularyTerms: { XCTFail("Local preview must not read vocabulary"); return [] },
            clipboard: { XCTFail("Local preview must not read clipboard"); return nil })
        let result = await runner.run(mode: custom, source: .init(rawText: "keep this", targetAppName: "Mail"))
        switch result {
        case .success: XCTFail("Missing runtime must be reported")
        case .failure(let error): XCTAssertTrue(error is LocalCleanupError)
        }
        XCTAssertTrue(chat.calls.isEmpty)
    }

}
