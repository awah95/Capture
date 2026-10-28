import XCTest
@testable import Captur

// MARK: - Stub transport

/// A `URLProtocol` stub that can route on the *body* of the upload.
///
/// Segment audio files are written with a distinctive marker inside them, so a
/// test can say "fail segment 1 twice, hang segment 2" without knowing anything
/// about request ordering — which is exactly what a concurrent dispatcher makes
/// unpredictable.
final class SegmentStubURLProtocol: URLProtocol {

    struct Request {
        let url: URL
        /// The multipart body, decoded as UTF-8 (audio bytes included; the test
        /// fixtures are ASCII on purpose).
        let body: String
        /// 0-based position in the whole run.
        let ordinal: Int
    }

    enum Outcome {
        case respond(status: Int, headers: [String: String], body: Data)
        case failure(URLError)
        /// Never answers until `releaseHungRequests()` is called.
        case hang

        static func text(_ text: String) -> Outcome {
            .respond(
                status: 200,
                headers: [:],
                body: Data(#"{"text":"\#(text)"}"#.utf8)
            )
        }

        static func status(_ status: Int, headers: [String: String] = [:]) -> Outcome {
            .respond(
                status: status,
                headers: headers,
                body: Data(#"{"error":{"message":"stub"}}"#.utf8)
            )
        }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var requests: [Request] = []
        var handler: (@Sendable (Request) -> Outcome)?
        var hung: [() -> Void] = []
    }

    nonisolated(unsafe) private static let box = Box()

    static func reset(handler: (@Sendable (Request) -> Outcome)? = nil) {
        box.lock.lock()
        box.requests = []
        box.hung = []
        box.handler = handler
        box.lock.unlock()
    }

    static var requests: [Request] {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.requests
    }

    /// Requests whose body contained `marker` (i.e. attempts on one segment).
    static func requests(matching marker: String) -> [Request] {
        requests.filter { $0.body.contains(marker) }
    }

    static func transcriptionRequests() -> [Request] {
        requests.filter { $0.url.path.hasSuffix("/audio/transcriptions") }
    }

    static func releaseHungRequests() {
        box.lock.lock()
        let pending = box.hung
        box.hung = []
        box.lock.unlock()
        for deliver in pending { deliver() }
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body = Self.readBody(from: request)

        Self.box.lock.lock()
        let recorded = Request(url: url, body: body, ordinal: Self.box.requests.count)
        Self.box.requests.append(recorded)
        let handler = Self.box.handler
        Self.box.lock.unlock()

        let outcome = handler?(recorded) ?? .text("ok")

        let deliver: () -> Void = { [weak self] in
            guard let self else { return }
            self.deliver(outcome, for: url)
        }

        switch outcome {
        case .hang:
            Self.box.lock.lock()
            Self.box.hung.append(deliver)
            Self.box.lock.unlock()
        default:
            deliver()
        }
    }

    override func stopLoading() {}

    private func deliver(_ outcome: Outcome, for url: URL) {
        switch outcome {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .hang:
            // A released hang answers 200 with a marker-free transcript; the
            // tests that use it only care that the segment eventually lands.
            respond(status: 200, headers: [:], body: Data(#"{"text":"released"}"#.utf8), url: url)
        case .respond(let status, let headers, let body):
            respond(status: status, headers: headers, body: body, url: url)
        }
    }

    private func respond(status: Int, headers: [String: String], body: Data, url: URL) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readBody(from request: URLRequest) -> String {
        if let data = request.httpBody {
            return String(decoding: data, as: UTF8.self)
        }
        guard let stream = request.httpBodyStream else { return "" }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let capacity = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Thread-safe recorder for the injected sleeper.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [TimeInterval] = []

    var durations: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _durations
    }

    /// Records the requested delay and returns instantly, so a 2-second
    /// `Retry-After` costs the test nothing.
    var sleeper: @Sendable (TimeInterval) async -> Void {
        { [self] seconds in
            lock.lock()
            _durations.append(seconds)
            lock.unlock()
        }
    }
}

// MARK: - Tests

final class GroqTranscriberTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func setUp() {
        super.setUp()
        SegmentStubURLProtocol.reset()
    }

    override func tearDown() {
        SegmentStubURLProtocol.releaseHungRequests()
        SegmentStubURLProtocol.reset()
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles = []
        super.tearDown()
    }

    // MARK: Helpers

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SegmentStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeTranscriber(
        recorder: SleepRecorder? = nil
    ) -> GroqTranscriber {
        GroqTranscriber(session: makeSession(), sleeper: recorder?.sleeper)
    }

    /// A fake FLAC whose bytes spell out `SEGMENT-<index>`, so the stub can tell
    /// segments apart from the multipart body alone.
    private func segmentFile(_ index: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-seg-\(index)-\(UUID().uuidString).flac")
        let marker = String(repeating: "SEGMENT-\(index) ", count: 8)
        try Data(marker.utf8).write(to: url)
        temporaryFiles.append(url)
        return url
    }

    private func marker(_ index: Int) -> String { "SEGMENT-\(index)" }

    /// The `prompt` field of a multipart body, or nil when none was sent.
    private func promptField(in body: String) -> String? {
        guard let range = body.range(of: "name=\"prompt\"\r\n\r\n") else { return nil }
        let rest = body[range.upperBound...]
        guard let end = rest.range(of: "\r\n--") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    private func enqueue(
        _ transcriber: GroqTranscriber,
        index: Int,
        url: URL,
        precedingSilence: TimeInterval = 0.7,
        vocabularyPrompt: String = ""
    ) {
        transcriber.enqueue(
            index: index,
            url: url,
            precedingSilence: precedingSilence,
            apiKey: "stub-key-not-a-real-credential",
            model: "whisper-large-v3-turbo",
            language: "en",
            vocabularyPrompt: vocabularyPrompt
        )
    }

    // MARK: Ordering

    func testSegmentsEnqueuedOutOfOrderReturnInIndexOrder() async throws {
        SegmentStubURLProtocol.reset { request in
            if request.body.contains("SEGMENT-0") { return .text("zero") }
            if request.body.contains("SEGMENT-1") { return .text("one") }
            return .text("two")
        }

        let transcriber = makeTranscriber()
        let files = try (0...2).map { try segmentFile($0) }

        enqueue(transcriber, index: 2, url: files[2], precedingSilence: 0.9)
        enqueue(transcriber, index: 0, url: files[0], precedingSilence: 0.0)
        enqueue(transcriber, index: 1, url: files[1], precedingSilence: 0.6)

        let results = await transcriber.awaitAll()

        XCTAssertEqual(results.map(\.index), [0, 1, 2])
        XCTAssertEqual(results.map(\.text), ["zero", "one", "two"])
        XCTAssertEqual(results.map(\.precedingSilence), [0.0, 0.6, 0.9])
    }

    // MARK: Retries

    func testSegmentRetriedTwiceThenSucceeds() async throws {
        SegmentStubURLProtocol.reset { request in
            let attempt = SegmentStubURLProtocol.requests(matching: "SEGMENT-0").count
            return attempt <= 2 ? .status(500) : .text("recovered")
        }

        let recorder = SleepRecorder()
        let transcriber = makeTranscriber(recorder: recorder)
        let file = try segmentFile(0)
        enqueue(transcriber, index: 0, url: file)

        let results = await transcriber.awaitAll()

        XCTAssertEqual(results.map(\.text), ["recovered"])
        XCTAssertEqual(results.map(\.attemptCount), [3])
        XCTAssertEqual(SegmentStubURLProtocol.requests(matching: "SEGMENT-0").count, 3)
        XCTAssertEqual(recorder.durations, [0.4, 1.2])
    }

    func testPermanentlyFailingSegmentYieldsNilAndNeighboursSurvive() async throws {
        SegmentStubURLProtocol.reset { request in
            request.body.contains("SEGMENT-1")
                ? .status(500)
                : .text(request.body.contains("SEGMENT-0") ? "before" : "after")
        }

        let recorder = SleepRecorder()
        let transcriber = makeTranscriber(recorder: recorder)
        let files = try (0...2).map { try segmentFile($0) }

        enqueue(transcriber, index: 0, url: files[0])
        enqueue(transcriber, index: 1, url: files[1])
        enqueue(transcriber, index: 2, url: files[2])

        let results = await transcriber.awaitAll()

        XCTAssertEqual(results.map(\.index), [0, 1, 2])
        XCTAssertEqual(results[0].text, "before")
        XCTAssertNil(results[1].text, "an exhausted segment must not fail the dictation")
        XCTAssertEqual(results[2].text, "after")
        XCTAssertEqual(results.map(\.attemptCount), [1, 3, 1])

        // Three attempts, and no more.
        XCTAssertEqual(SegmentStubURLProtocol.requests(matching: "SEGMENT-1").count, 3)

        // The whole run still stitches, with the hole made visible.
        XCTAssertEqual(
            TranscriptStitcher.stitch(results, repairSeams: false),
            "before […] after"
        )
    }

    func testPermanentErrorIsNotRetried() async throws {
        SegmentStubURLProtocol.reset { _ in .status(401) }

        let recorder = SleepRecorder()
        let transcriber = makeTranscriber(recorder: recorder)
        enqueue(transcriber, index: 0, url: try segmentFile(0))

        let results = await transcriber.awaitAll()

        XCTAssertNil(results.first?.text)
        XCTAssertEqual(results.first?.attemptCount, 1)
        XCTAssertEqual(SegmentStubURLProtocol.requests(matching: "SEGMENT-0").count, 1)
        XCTAssertEqual(recorder.durations, [], "a 401 will never become a 200")
    }

    func testRetryAfterHeaderIsHonouredWithoutSleeping() async throws {
        SegmentStubURLProtocol.reset { _ in
            let attempt = SegmentStubURLProtocol.requests(matching: "SEGMENT-0").count
            return attempt == 1
                ? .status(429, headers: ["Retry-After": "2"])
                : .text("after the wait")
        }

        let recorder = SleepRecorder()
        let transcriber = makeTranscriber(recorder: recorder)

        let started = Date()
        enqueue(transcriber, index: 0, url: try segmentFile(0))
        let results = await transcriber.awaitAll()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(results.first?.text, "after the wait")
        XCTAssertEqual(
            recorder.durations, [2.0],
            "the server's Retry-After must override the backoff schedule"
        )
        XCTAssertLessThan(elapsed, 1.5, "the delay must be observed, not actually spent")
    }

    func testRetryDelayFallsBackToScheduleWithoutRetryAfter() {
        let transient = GroqError.transient(status: 503, message: "x", retryAfter: nil)
        XCTAssertEqual(GroqTranscriber.retryDelay(for: transient, afterAttempt: 0), 0.4)
        XCTAssertEqual(GroqTranscriber.retryDelay(for: transient, afterAttempt: 1), 1.2)
        XCTAssertEqual(GroqTranscriber.retryDelay(for: transient, afterAttempt: 2), 3.6)

        let throttled = GroqError.transient(status: 429, message: "x", retryAfter: 7)
        XCTAssertEqual(GroqTranscriber.retryDelay(for: throttled, afterAttempt: 0), 7)

        XCTAssertTrue(GroqTranscriber.isRetryable(GroqError.offline))
        XCTAssertFalse(GroqTranscriber.isRetryable(GroqError.permanent(status: 401, message: "x")))
        XCTAssertFalse(GroqTranscriber.isRetryable(GroqError.fileMissing))
    }

    // MARK: Continuity prompt

    func testContinuityPromptCarriesPreviousTranscript() async throws {
        SegmentStubURLProtocol.reset { request in
            request.body.contains("SEGMENT-0")
                ? .text("the quick brown fox jumped")
                : .text("over the lazy dog")
        }

        let transcriber = makeTranscriber()

        // Segment 0 has to have *landed* before segment 1 is cut — which is what
        // happens in a real recording, where cuts are seconds apart.
        enqueue(transcriber, index: 0, url: try segmentFile(0))
        _ = await transcriber.awaitAll()

        enqueue(transcriber, index: 1, url: try segmentFile(1), vocabularyPrompt: "Avery, Groq")
        let results = await transcriber.awaitAll()

        XCTAssertEqual(results.map(\.index), [0, 1])

        let first = try XCTUnwrap(SegmentStubURLProtocol.requests(matching: marker(0)).first)
        XCTAssertNil(promptField(in: first.body), "the first segment has no context to carry")

        let second = try XCTUnwrap(SegmentStubURLProtocol.requests(matching: marker(1)).first)
        let prompt = try XCTUnwrap(promptField(in: second.body))
        XCTAssertTrue(prompt.contains("quick brown fox"), "prompt was: \(prompt)")
        XCTAssertTrue(prompt.hasPrefix("Avery, Groq"), "vocabulary leads: \(prompt)")
    }

    func testSegmentDoesNotBlockOnAnInFlightPredecessor() async throws {
        SegmentStubURLProtocol.reset { request in
            if request.body.contains("SEGMENT-0") { return .text("landed early words") }
            if request.body.contains("SEGMENT-1") { return .hang }
            return .text("third")
        }

        let transcriber = makeTranscriber()

        enqueue(transcriber, index: 0, url: try segmentFile(0))
        _ = await transcriber.awaitAll()

        // Segment 1 goes out and never answers; segment 2 must not wait for it.
        enqueue(transcriber, index: 1, url: try segmentFile(1))
        enqueue(transcriber, index: 2, url: try segmentFile(2))

        let sent = expectation(description: "segment 2 reached the wire")
        Task {
            while SegmentStubURLProtocol.requests(matching: "SEGMENT-2").isEmpty {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            sent.fulfill()
        }
        await fulfillment(of: [sent], timeout: 5)

        let third = try XCTUnwrap(SegmentStubURLProtocol.requests(matching: marker(2)).first)
        let prompt = try XCTUnwrap(promptField(in: third.body))
        XCTAssertTrue(
            prompt.contains("landed early words"),
            "segment 2 must fall back to the newest COMPLETED segment: \(prompt)"
        )

        SegmentStubURLProtocol.releaseHungRequests()
        let results = await transcriber.awaitAll()
        XCTAssertEqual(results.map(\.index), [0, 1, 2])
        XCTAssertEqual(results[2].text, "third")
    }

    // MARK: Prompt budget

    func testAssembledPromptNeverExceedsTheTokenCap() {
        let vocabulary = VocabularyRanker.select(
            from: (0..<300).map { makeTerm("Terminology\($0)") },
            targetBundleID: nil,
            now: Date(),
            reservedTokens: 0
        )
        XCTAssertGreaterThan(vocabulary.terms.count, 0)
        XCTAssertLessThan(
            vocabulary.terms.count, 300,
            "300 terms should already overflow the budget on their own"
        )

        let tail = Array(repeating: "continuation", count: 400).joined(separator: " ")
        let prompt = GroqTranscriber.assemblePrompt(
            vocabularyPrompt: vocabulary.promptString,
            continuityTail: tail
        )

        XCTAssertLessThanOrEqual(
            VocabularyRanker.estimatedTokens(in: prompt),
            VocabularyRanker.whisperPromptTokenBudget
        )
    }

    func testVocabularySurvivesTruncationInPreferenceToTheTail() {
        let vocabulary = "Avery, Groq, Whisper, Supabase, Captur"
        let tail = Array(repeating: "word", count: 500).joined(separator: " ")

        let prompt = GroqTranscriber.assemblePrompt(
            vocabularyPrompt: vocabulary,
            continuityTail: tail
        )

        XCTAssertTrue(prompt.hasPrefix(vocabulary), "prompt was: \(prompt)")
        XCTAssertLessThanOrEqual(
            VocabularyRanker.estimatedTokens(in: prompt),
            VocabularyRanker.whisperPromptTokenBudget
        )
    }

    func testTailIsCappedAtThirtyWordsAndKeepsTheWordsNearestTheCut() {
        let tail = (1...100).map { "w\($0)" }.joined(separator: " ")
        let prompt = GroqTranscriber.assemblePrompt(vocabularyPrompt: "", continuityTail: tail)

        let words = prompt.split(separator: " ").map(String.init)
        XCTAssertEqual(words.count, GroqTranscriber.continuityTailWordCount)
        XCTAssertEqual(words.last, "w100", "the words next to the cut are the useful ones")
        XCTAssertEqual(words.first, "w71")
    }

    func testEmptyVocabularyAndEmptyTailProduceNoPrompt() {
        XCTAssertEqual(
            GroqTranscriber.assemblePrompt(vocabularyPrompt: "   ", continuityTail: "\n"),
            ""
        )
    }

    func testAnOversizedVocabularyAloneIsTruncatedToTheCap() {
        let vocabulary = (0..<400).map { "Term\($0)" }.joined(separator: ", ")
        let prompt = GroqTranscriber.assemblePrompt(
            vocabularyPrompt: vocabulary,
            continuityTail: ""
        )

        XCTAssertFalse(prompt.isEmpty)
        XCTAssertTrue(vocabulary.hasPrefix(prompt), "truncation keeps the top-ranked prefix")
        XCTAssertLessThanOrEqual(
            VocabularyRanker.estimatedTokens(in: prompt),
            VocabularyRanker.whisperPromptTokenBudget
        )
    }

    // MARK: Warm-up and reset

    func testWarmConnectionNeitherThrowsNorBlocks() async throws {
        SegmentStubURLProtocol.reset { _ in .respond(status: 200, headers: [:], body: Data("{}".utf8)) }

        let transcriber = makeTranscriber()

        let started = Date()
        transcriber.warmConnection(apiKey: "stub-key-not-a-real-credential")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.5, "warm-up must be off the critical path")

        let warmed = expectation(description: "models endpoint touched")
        Task {
            while !SegmentStubURLProtocol.requests.contains(where: {
                $0.url.path.hasSuffix("/models")
            }) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            warmed.fulfill()
        }
        await fulfillment(of: [warmed], timeout: 5)

        XCTAssertTrue(SegmentStubURLProtocol.transcriptionRequests().isEmpty)
    }

    func testWarmConnectionSurvivesATransportFailure() async throws {
        SegmentStubURLProtocol.reset { _ in .failure(URLError(.notConnectedToInternet)) }

        let transcriber = makeTranscriber()
        transcriber.warmConnection(apiKey: "stub-key-not-a-real-credential")

        // Nothing to assert but survival: a dead warm-up must stay silent, and a
        // subsequent dictation must be unaffected.
        SegmentStubURLProtocol.reset { _ in .text("still works") }
        enqueue(transcriber, index: 0, url: try segmentFile(0))
        let results = await transcriber.awaitAll()
        XCTAssertEqual(results.first?.text, "still works")
    }

    func testResetDropsContinuityContextBetweenDictations() async throws {
        SegmentStubURLProtocol.reset { request in
            request.body.contains("SEGMENT-0") ? .text("first dictation words") : .text("fresh")
        }

        let transcriber = makeTranscriber()
        enqueue(transcriber, index: 0, url: try segmentFile(0))
        _ = await transcriber.awaitAll()

        transcriber.reset()

        enqueue(transcriber, index: 1, url: try segmentFile(1))
        let results = await transcriber.awaitAll()

        XCTAssertEqual(results.map(\.index), [1], "reset clears the previous run's segments")

        let request = try XCTUnwrap(SegmentStubURLProtocol.requests(matching: marker(1)).first)
        XCTAssertNil(
            promptField(in: request.body),
            "a new dictation must not inherit the previous one's words"
        )
    }

    func testAwaitAllOnAnEmptyRunReturnsNothing() async {
        let results = await makeTranscriber().awaitAll()
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: Fixtures

    private func makeTerm(_ text: String) -> VocabularyTerm {
        VocabularyTerm(
            id: UUID(),
            text: text,
            soundsLike: nil,
            isPinned: false,
            useCount: 0,
            lastUsed: nil,
            appBundleIDs: []
        )
    }
}
