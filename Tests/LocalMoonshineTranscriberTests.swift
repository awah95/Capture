import AVFoundation
import Foundation
import XCTest
@testable import Captur

private actor FakeMoonshineRuntime: MoonshineTranscriptionRunning {
    private(set) var prepared = 0
    private(set) var startedTerms: [String] = []
    private(set) var transcribedFiles: [String] = []
    var finalText = "Streamed locally."
    var batchText = "Retried locally."
    var partialText: String?
    var streamingStartFails = false
    private var streamingStarted = false

    func prepare() async throws { prepared += 1 }
    func startSession(id: UUID, vocabularyTerms: [String]) async throws {
        if streamingStartFails {
            throw NSError(domain: "test.moonshine-stream", code: 1)
        }
        streamingStarted = true
        startedTerms = vocabularyTerms
    }
    func addAudio(sessionID: UUID, samples: [Float], sampleRate: Int32) async throws -> String? {
        partialText
    }
    func finishSession(id: UUID) async throws -> String {
        guard streamingStarted else { return "" }
        return finalText
    }
    func cancelSession(id: UUID) async {}
    private(set) var batchTerms: [[String]] = []
    func capturedBatchTerms() -> [[String]] { batchTerms }
    func transcribe(fileURL: URL, vocabularyTerms: [String]) async throws -> String {
        batchTerms.append(vocabularyTerms)
        return try await transcribe(fileURL: fileURL)
    }

    func transcribe(fileURL: URL) async throws -> String {
        transcribedFiles.append(fileURL.lastPathComponent)
        return batchText
    }

    func snapshot() -> (prepared: Int, terms: [String], files: [String]) {
        (prepared, startedTerms, transcribedFiles)
    }
}

final class LocalMoonshineTranscriberTests: XCTestCase {
    func testBatchUsesCaptureVocabularyAndClearsItForNextCapture() async {
        let runtime = FakeMoonshineRuntime()
        let transcriber = LocalMoonshineTranscriber(runtime: runtime)
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

    func testLiveCaptureReturnsTheStreamingTranscriptAndIgnoresSegmentUploads() async {
        let runtime = FakeMoonshineRuntime()
        let transcriber = LocalMoonshineTranscriber(runtime: runtime)

        transcriber.beginLiveTranscription(vocabularyTerms: ["Captur", "Moonshine"])
        transcriber.enqueue(
            index: 0, url: URL(fileURLWithPath: "/tmp/segment.flac"),
            precedingSilence: 0, apiKey: "", model: "", language: nil,
            vocabularyPrompt: "")

        let results = await transcriber.awaitAll()
        let snapshot = await runtime.snapshot()

        XCTAssertEqual(results.map(\.text), ["Streamed locally."])
        XCTAssertEqual(snapshot.terms, ["Captur", "Moonshine"])
        XCTAssertTrue(snapshot.files.isEmpty)
    }

    func testHistoryRetryUsesTheDurableAudioFileWithoutStartingAStream() async {
        let runtime = FakeMoonshineRuntime()
        let transcriber = LocalMoonshineTranscriber(runtime: runtime)

        transcriber.enqueue(
            index: 0, url: URL(fileURLWithPath: "/tmp/session.flac"),
            precedingSilence: 0, apiKey: "", model: "", language: nil,
            vocabularyPrompt: "")

        let results = await transcriber.awaitAll()
        let snapshot = await runtime.snapshot()

        XCTAssertEqual(results.map(\.text), ["Retried locally."])
        XCTAssertEqual(snapshot.files, ["session.flac"])
        XCTAssertTrue(snapshot.terms.isEmpty)
    }

    func testFailedStreamingStartupFallsBackToTheDurableSegment() async {
        let runtime = FakeMoonshineRuntime()
        await runtime.setStreamingStartFails(true)
        let transcriber = LocalMoonshineTranscriber(runtime: runtime)

        transcriber.beginLiveTranscription(vocabularyTerms: ["Captur"])
        transcriber.enqueue(
            index: 0, url: URL(fileURLWithPath: "/tmp/fallback.flac"),
            precedingSilence: 0.4, apiKey: "", model: "", language: nil,
            vocabularyPrompt: "")

        let results = await transcriber.awaitAll()
        let snapshot = await runtime.snapshot()

        XCTAssertEqual(results, [SegmentResult(
            index: 0, text: "Retried locally.", precedingSilence: 0.4)])
        XCTAssertEqual(snapshot.files, ["fallback.flac"])
    }

    func testLiveAudioPublishesRevisablePartialTranscript() async throws {
        let runtime = FakeMoonshineRuntime()
        await runtime.setPartialText("Words arriving now")
        let transcriber = LocalMoonshineTranscriber(runtime: runtime)
        let received = expectation(description: "partial transcript")
        transcriber.setLiveTranscriptHandler { text in
            XCTAssertEqual(text, "Words arriving now")
            received.fulfill()
        }
        transcriber.beginLiveTranscription(vocabularyTerms: [])

        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
            interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        buffer.frameLength = 320
        transcriber.ingestLiveAudio(buffer)

        await fulfillment(of: [received], timeout: 1)
        transcriber.reset()
    }
}

private extension FakeMoonshineRuntime {
    func setPartialText(_ text: String?) { partialText = text }
    func setStreamingStartFails(_ fails: Bool) { streamingStartFails = fails }
}
