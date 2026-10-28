import AVFAudio
import Foundation
import XCTest
@testable import Captur

private actor FakeLocalTranscriptionRuntime: LocalTranscriptionRunning {
    var texts: [String: String] = [:]
    var failingFiles: Set<String> = []
    private(set) var prepareCount = 0
    private(set) var transcribedFiles: [String] = []
    private(set) var streamingStartCount = 0
    private(set) var streamingAppendCount = 0
    var streamingPartial = "A revisable Unified partial"
    var streamingFinal = "A final Unified transcript."
    var streamingStartFails = false
    private var streamingStarted = false

    func prepare() async throws {
        prepareCount += 1
    }

    private(set) var batchTerms: [[String]] = []
    private var termsByFile: [String: [String]] = [:]
    func capturedTermsByFile() -> [String: [String]] { termsByFile }
    func capturedBatchTerms() -> [[String]] { batchTerms }
    func transcribe(fileURL: URL, vocabularyTerms: [String]) async throws -> String {
        batchTerms.append(vocabularyTerms)
        termsByFile[fileURL.lastPathComponent] = vocabularyTerms
        return try await transcribe(fileURL: fileURL)
    }

    func transcribe(fileURL: URL) async throws -> String {
        let name = fileURL.lastPathComponent
        transcribedFiles.append(name)
        if failingFiles.contains(name) {
            throw NSError(domain: "test.local-transcription", code: 1)
        }
        return texts[name] ?? "local \(name)"
    }

    func startStreamingSession(id: UUID, vocabularyTerms: [String]) async throws {
        streamingStartCount += 1
        if streamingStartFails {
            throw NSError(domain: "test.unified-stream", code: 1)
        }
        streamingStarted = true
    }

    func appendStreamingAudio(
        sessionID: UUID, samples: [Float], sampleRate: Double
    ) async throws -> String? {
        streamingAppendCount += 1
        return streamingPartial
    }

    func finishStreamingSession(id: UUID) async throws -> String {
        streamingStarted ? streamingFinal : ""
    }

    func cancelStreamingSession(id: UUID) async {}

    func snapshot() -> (prepareCount: Int, transcribedFiles: [String]) {
        (prepareCount, transcribedFiles)
    }
}

final class LocalUnifiedTranscriberTests: XCTestCase {
    @MainActor
    func testUltraVocabularyRequiresBothSettingsAndUsesSavedTerms() async {
        for speechEnabled in [false, true] {
            for boostingEnabled in [false, true] {
                var configuration = DictationPipeline.Configuration.default
                configuration.transcriptionProvider = .localUltra
                configuration.speechVocabularyEnabled = speechEnabled
                configuration.parakeetVocabularyBoosting = boostingEnabled
                let runtime = FakeLocalTranscriptionRuntime()
                let transcriber = LocalUnifiedTranscriber(runtime: runtime,
                    vocabularyBoostingEnabled: speechEnabled && boostingEnabled,
                    audioDuration: { _ in 1 })
                let capture = ActiveCapture(id: UUID(), generation: 0, trigger: .menuBar,
                    startedAt: Date(), modeID: "clean", targetBundleID: nil, targetAppName: nil,
                    vocabularyTerms: [VocabularyTerm(id: UUID(), text: "Captur", isPinned: true, useCount: 0, appBundleIDs: [])],
                    recorder: nil, transcriber: transcriber, configuration: configuration)
                let expected = speechEnabled && boostingEnabled ? ["Captur"] : []
                XCTAssertEqual(capture.nativeVocabularyTerms, expected)
                transcriber.configureVocabulary(capture.nativeVocabularyTerms)
                transcriber.enqueue(index: 0, url: URL(fileURLWithPath: "/tmp/ultra-vocabulary.flac"),
                    precedingSilence: 0, apiKey: "", model: "", language: nil, vocabularyPrompt: "")
                _ = await transcriber.awaitAll()
                let received = await runtime.capturedBatchTerms()
                XCTAssertEqual(received, [expected])
            }
        }
    }

    func testVocabularyBoosterPreservesTranscriptWithoutEligibleAudio() async {
        for inverseTextNormalized in [true, false] {
            let text = await ParakeetVocabularyBooster.shared.rescore(
                text: "Original Ultra transcript", timings: [], samples: [], terms: ["Captur"],
                inverseTextNormalized: inverseTextNormalized)
            XCTAssertEqual(text, "Original Ultra transcript")
        }
    }

    func testBatchUsesCaptureVocabularyAndClearsItForNextCapture() async {
        let runtime = FakeLocalTranscriptionRuntime()
        let transcriber = LocalUnifiedTranscriber(runtime: runtime, vocabularyBoostingEnabled: true, audioDuration: { _ in 1 })
        transcriber.configureVocabulary([" Captur ", "Captur", "Moonshine"])
        transcriber.enqueue(index: 0, url: URL(fileURLWithPath: "/tmp/vocabulary.flac"),
            precedingSilence: 0, apiKey: "", model: "", language: nil, vocabularyPrompt: "")
        _ = await transcriber.awaitAll()
        transcriber.reset()
        transcriber.configureVocabulary([])
        transcriber.enqueue(index: 0, url: URL(fileURLWithPath: "/tmp/no-vocabulary.flac"),
            precedingSilence: 0, apiKey: "", model: "", language: nil, vocabularyPrompt: "")
        _ = await transcriber.awaitAll()
        let terms = await runtime.capturedBatchTerms()
        XCTAssertEqual(terms, [["Captur", "Moonshine"], []])
    }

    func testAcousticBudgetCapsCumulativeSegmentAudio() async {
        let runtime = FakeLocalTranscriptionRuntime()
        let transcriber = LocalUnifiedTranscriber(runtime: runtime, vocabularyBoostingEnabled: true, audioDuration: { _ in 20 })
        transcriber.configureVocabulary(["Captur"])
        for index in 0..<5 {
            transcriber.enqueue(index: index, url: URL(fileURLWithPath: "/tmp/segment-\(index).flac"),
                precedingSilence: 0, apiKey: "", model: "", language: nil, vocabularyPrompt: "")
        }
        _ = await transcriber.awaitAll()
        let terms = await runtime.capturedBatchTerms()
        XCTAssertEqual(terms.filter { !$0.isEmpty }.count, 3)
        XCTAssertEqual(terms.filter { $0.isEmpty }.count, 2)
        let files = await runtime.capturedTermsByFile()
        XCTAssertEqual(files["segment-0.flac"], ["Captur"])
        XCTAssertEqual(files["segment-2.flac"], ["Captur"])
        XCTAssertEqual(files["segment-3.flac"], [])
        XCTAssertEqual(files["segment-4.flac"], [])
    }

    func testReturnsLocalSegmentsInIndexOrderAndPreservesSilence() async {
        let runtime = FakeLocalTranscriptionRuntime()
        await runtime.setTexts([
            "first.flac": "First local sentence.",
            "second.flac": "Second local sentence."
        ])
        let transcriber = LocalUnifiedTranscriber(runtime: runtime)

        transcriber.enqueue(
            index: 1,
            url: URL(fileURLWithPath: "/tmp/second.flac"),
            precedingSilence: 0.8,
            apiKey: "unused",
            model: "unused",
            language: "de",
            vocabularyPrompt: "unused")
        transcriber.enqueue(
            index: 0,
            url: URL(fileURLWithPath: "/tmp/first.flac"),
            precedingSilence: 0,
            apiKey: "unused",
            model: "unused",
            language: nil,
            vocabularyPrompt: "unused")

        let results = await transcriber.awaitAll()

        XCTAssertEqual(results.map(\.index), [0, 1])
        XCTAssertEqual(results.map(\.text), ["First local sentence.", "Second local sentence."])
        XCTAssertEqual(results.map(\.precedingSilence), [0, 0.8])
    }

    func testAFailedLocalSegmentBecomesAVisiblePipelineHole() async {
        let runtime = FakeLocalTranscriptionRuntime()
        await runtime.setFailingFiles(["failed.flac"])
        let transcriber = LocalUnifiedTranscriber(runtime: runtime)

        transcriber.enqueue(
            index: 0,
            url: URL(fileURLWithPath: "/tmp/failed.flac"),
            precedingSilence: 0,
            apiKey: "",
            model: "",
            language: nil,
            vocabularyPrompt: "")

        let results = await transcriber.awaitAll()
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].text)
    }

    func testWarmStartsModelPreparationWithoutACloudKey() async {
        let runtime = FakeLocalTranscriptionRuntime()
        let transcriber = LocalUnifiedTranscriber(runtime: runtime)

        transcriber.warmConnection(apiKey: "")
        for _ in 0..<100 {
            let snapshot = await runtime.snapshot()
            if snapshot.prepareCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.prepareCount, 1)
    }

    func testLiveModePublishesPartialsAndReturnsOneFinalResult() async throws {
        let runtime = FakeLocalTranscriptionRuntime()
        let transcriber = LocalUnifiedTranscriber(runtime: runtime)
        let partial = expectation(description: "Unified partial")
        transcriber.setLiveTranscriptHandler { text in
            XCTAssertEqual(text, "A revisable Unified partial")
            partial.fulfill()
        }
        transcriber.beginLiveTranscription(vocabularyTerms: ["Captur"])

        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        transcriber.ingestLiveAudio(buffer)
        await fulfillment(of: [partial], timeout: 1)

        let results = await transcriber.awaitAll()
        XCTAssertEqual(results, [SegmentResult(
            index: 0,
            text: "A final Unified transcript.",
            precedingSilence: 0)])
        let snapshot = await runtime.streamingSnapshot()
        XCTAssertEqual(snapshot.startCount, 1)
        XCTAssertEqual(snapshot.appendCount, 1)
    }

    func testLiveBatchFinalizationUsesContinuousRecordingAsAuthoritativeResult() async {
        let runtime = FakeLocalTranscriptionRuntime()
        await runtime.setTexts(["session.flac": "Batch-corrected final."])
        let transcriber = LocalUnifiedTranscriber(
            runtime: runtime,
            retranscribeFinalWithBatch: true)

        transcriber.beginLiveTranscription(vocabularyTerms: ["Captur"])
        transcriber.setFinalRecordingURL(URL(fileURLWithPath: "/tmp/session.flac"))

        let results = await transcriber.awaitAll()
        let snapshot = await runtime.snapshot()

        XCTAssertEqual(results, [SegmentResult(
            index: 0,
            text: "Batch-corrected final.",
            precedingSilence: 0)])
        XCTAssertEqual(snapshot.transcribedFiles, ["session.flac"])
    }

    func testFailedLiveBatchFinalizationFallsBackToStreamingResult() async {
        let runtime = FakeLocalTranscriptionRuntime()
        await runtime.setFailingFiles(["session.flac"])
        let transcriber = LocalUnifiedTranscriber(
            runtime: runtime,
            retranscribeFinalWithBatch: true)

        transcriber.beginLiveTranscription(vocabularyTerms: [])
        transcriber.setFinalRecordingURL(URL(fileURLWithPath: "/tmp/session.flac"))

        let results = await transcriber.awaitAll()
        let snapshot = await runtime.snapshot()

        XCTAssertEqual(results, [SegmentResult(
            index: 0,
            text: "A final Unified transcript.",
            precedingSilence: 0)])
        XCTAssertEqual(snapshot.transcribedFiles, ["session.flac"])
    }

    func testDisablingLiveBatchFinalizationKeepsStreamingResult() async {
        let runtime = FakeLocalTranscriptionRuntime()
        await runtime.setTexts(["session.flac": "Batch result should not be used."])
        let transcriber = LocalUnifiedTranscriber(
            runtime: runtime,
            retranscribeFinalWithBatch: false)

        transcriber.beginLiveTranscription(vocabularyTerms: [])
        transcriber.setFinalRecordingURL(URL(fileURLWithPath: "/tmp/session.flac"))

        let results = await transcriber.awaitAll()
        let snapshot = await runtime.snapshot()

        XCTAssertEqual(results, [SegmentResult(
            index: 0,
            text: "A final Unified transcript.",
            precedingSilence: 0)])
        XCTAssertTrue(snapshot.transcribedFiles.isEmpty)
    }

    func testFailedStreamingStartupFallsBackToTheDurableSegments() async {
        let runtime = FakeLocalTranscriptionRuntime()
        await runtime.setStreamingStartFails(true)
        await runtime.setTexts([
            "first.flac": "First fallback.",
            "second.flac": "Second fallback.",
        ])
        let transcriber = LocalUnifiedTranscriber(runtime: runtime)

        transcriber.beginLiveTranscription(vocabularyTerms: ["Captur"])
        transcriber.enqueue(
            index: 1, url: URL(fileURLWithPath: "/tmp/second.flac"),
            precedingSilence: 0.7, apiKey: "", model: "", language: nil,
            vocabularyPrompt: "")
        transcriber.enqueue(
            index: 0, url: URL(fileURLWithPath: "/tmp/first.flac"),
            precedingSilence: 0, apiKey: "", model: "", language: nil,
            vocabularyPrompt: "")

        let results = await transcriber.awaitAll()
        let snapshot = await runtime.snapshot()

        XCTAssertEqual(results.map(\.text), ["First fallback.", "Second fallback."])
        XCTAssertEqual(results.map(\.precedingSilence), [0, 0.7])
        XCTAssertEqual(snapshot.transcribedFiles, ["first.flac", "second.flac"])
    }
}

private extension FakeLocalTranscriptionRuntime {
    func setTexts(_ values: [String: String]) {
        texts = values
    }

    func setFailingFiles(_ values: Set<String>) {
        failingFiles = values
    }

    func setStreamingStartFails(_ fails: Bool) {
        streamingStartFails = fails
    }

    func streamingSnapshot() -> (startCount: Int, appendCount: Int) {
        (streamingStartCount, streamingAppendCount)
    }
}
