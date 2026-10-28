import XCTest
@testable import Captur

// MARK: - Test scaffolding

/// A one-shot async gate.
///
/// The chat client's failure modes are all about *ordering* — did the timeout
/// fire after the request went out, did a delta arrive after the throw — and
/// ordering asserted with a sleep is ordering asserted with a coin toss. Every
/// test here sequences events through a gate instead.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        guard !isOpen else { lock.unlock(); return }
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    /// Suspends until `open()`, or force-opens after `deadline` seconds.
    ///
    /// The deadline is not a timing assertion — it is there so that a broken
    /// implementation that never produces the awaited event fails the test
    /// instead of wedging the whole run. Every waiter is released and the
    /// assertions then report honestly.
    func wait(deadline: TimeInterval = 10) async {
        let watchdog = Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            open()
        }
        defer { watchdog.cancel() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// Records the deltas the client forwards, with an optional hook so a test can
/// react to the first one.
final class DeltaRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private let onEach: (@Sendable (String) -> Void)?

    init(onEach: (@Sendable (String) -> Void)? = nil) {
        self.onEach = onEach
    }

    var deltas: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var callback: @Sendable (String) -> Void {
        { [self] delta in
            lock.lock()
            stored.append(delta)
            lock.unlock()
            onEach?(delta)
        }
    }
}

/// A `URLProtocol` stub that answers with scripted SSE bytes.
///
/// Two capabilities the existing stubs do not have and these tests need:
/// **chunk gating**, because URLSession is free to coalesce chunks handed to it
/// back to back and the only way to force a real byte-stream boundary is to stop
/// writing until the client has consumed what it has; and a **`stopLoading`
/// count**, because "the timeout cancelled the request" is a claim about the
/// transport, not about the caller giving up.
final class SSEStubURLProtocol: URLProtocol {

    struct Request {
        let url: URL
        let body: String
        let authorization: String?
        let accept: String?
    }

    enum Outcome {
        case stream(status: Int, headers: [String: String], chunks: [Data], gateAfter: Int?)
        case failure(URLError)
        /// Accepts the request and never answers — not even a response header.
        case hang
        /// A response that is not an `HTTPURLResponse`.
        case nonHTTP

        static func sse(_ text: String, status: Int = 200) -> Outcome {
            .stream(
                status: status,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [Data(text.utf8)],
                gateAfter: nil
            )
        }

        /// Delivers `chunks` up to `gateAfter`, then waits for `release()`.
        static func gated(_ chunks: [Data], after gateAfter: Int) -> Outcome {
            .stream(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: chunks,
                gateAfter: gateAfter
            )
        }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var requests: [Request] = []
        var handler: (@Sendable (Request) -> Outcome)?
        var pending: [() -> Void] = []
        var stopLoadingCount = 0
        var onStopLoading: (@Sendable () -> Void)?
    }

    nonisolated(unsafe) private static let box = Box()

    static func reset(handler: (@Sendable (Request) -> Outcome)? = nil) {
        box.lock.lock()
        box.requests = []
        box.pending = []
        box.stopLoadingCount = 0
        box.onStopLoading = nil
        box.handler = handler
        box.lock.unlock()
    }

    static var requests: [Request] {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.requests
    }

    static var stopLoadingCount: Int {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.stopLoadingCount
    }

    static func onStopLoading(_ hook: @escaping @Sendable () -> Void) {
        box.lock.lock()
        box.onStopLoading = hook
        box.lock.unlock()
    }

    /// Delivers whatever a gated stream still owes, and finishes it.
    static func release() {
        box.lock.lock()
        let pending = box.pending
        box.pending = []
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

        let recorded = Request(
            url: url,
            body: Self.readBody(from: request),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            accept: request.value(forHTTPHeaderField: "Accept")
        )

        Self.box.lock.lock()
        Self.box.requests.append(recorded)
        let handler = Self.box.handler
        Self.box.lock.unlock()

        switch handler?(recorded) ?? .sse("data: [DONE]\n\n") {
        case .hang:
            break

        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)

        case .nonHTTP:
            let response = URLResponse(
                url: url,
                mimeType: "text/plain",
                expectedContentLength: -1,
                textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)

        case .stream(let status, let headers, let chunks, let gateAfter):
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

            let delivered = gateAfter ?? chunks.count
            for chunk in chunks.prefix(delivered) {
                client?.urlProtocol(self, didLoad: chunk)
            }

            let remaining = Array(chunks.dropFirst(delivered))
            // `self` is captured strongly on purpose: a released gate must
            // genuinely attempt delivery, so that a test asserting "no delta
            // arrived" cannot pass merely because the stub was deallocated.
            let finish: () -> Void = {
                for chunk in remaining {
                    self.client?.urlProtocol(self, didLoad: chunk)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            }

            if gateAfter == nil {
                finish()
            } else {
                Self.box.lock.lock()
                Self.box.pending.append(finish)
                Self.box.lock.unlock()
            }
        }
    }

    override func stopLoading() {
        Self.box.lock.lock()
        Self.box.stopLoadingCount += 1
        let hook = Self.box.onStopLoading
        Self.box.lock.unlock()
        hook?()
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

/// One `data:` frame carrying a content delta. The fixtures are plain text, so
/// hand-assembling the JSON keeps the expected bytes readable. Free-standing
/// rather than a test method, because the stub handlers that build fixtures are
/// `@Sendable` closures and must not capture the test case.
func sseFrame(_ content: String) -> String {
    #"data: {"choices":[{"index":0,"delta":{"content":"\#(content)"}}]}"# + "\n\n"
}

// MARK: - Tests

final class GroqChatClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SSEStubURLProtocol.reset()
    }

    override func tearDown() {
        SSEStubURLProtocol.release()
        SSEStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Helpers

    /// A sleeper that never returns on its own. The client cancels it the moment
    /// the stream wins, so the duration only has to outlive the test; it is
    /// `Task.sleep` rather than a bare continuation precisely so cancellation
    /// can reach it.
    private static let neverSleeper: @Sendable (TimeInterval) async -> Void = { _ in
        try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
    }

    private func makeClient(
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = GroqChatClientTests.neverSleeper
    ) -> GroqChatClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SSEStubURLProtocol.self]
        return GroqChatClient(
            session: URLSession(configuration: configuration),
            sleeper: sleeper
        )
    }

    private func complete(
        _ client: GroqChatClient,
        recorder: DeltaRecorder = DeltaRecorder(),
        timeout: TimeInterval = 30
    ) async throws -> String {
        try await client.complete(
            systemMessage: "SYSTEM",
            userMessage: "USER",
            model: "openai/gpt-oss-20b",
            temperature: 0.2,
            apiKey: "test-key",
            timeout: timeout,
            onDelta: recorder.callback
        )
    }

    // MARK: Streaming

    func testStreamedDeltasAccumulateInOrder() async throws {
        SSEStubURLProtocol.reset { _ in
            .sse(sseFrame("Hello") + sseFrame(", world") + sseFrame("!") + "data: [DONE]\n\n")
        }
        let recorder = DeltaRecorder()

        let text = try await complete(makeClient(), recorder: recorder)

        XCTAssertEqual(text, "Hello, world!")
        XCTAssertEqual(recorder.deltas, ["Hello", ", world", "!"])
    }

    /// Every one of these appears in a real Groq stream. A parser that treats any
    /// of them as fatal throws away the deltas it already has, and the pipeline
    /// then inserts the raw transcript for no reason.
    func testMalformedLinesAreSkippedRatherThanAbortingTheStream() async throws {
        let payload = ": keep-alive comment\n"
            + "\n"
            + "event: ping\n"
            + #"data: {"choices":[]}"# + "\n\n"
            + #"data: {"choices":[{"delta":{}}]}"# + "\n\n"
            + #"data: {"choices":[{"delta":{"role":"assistant"}}]}"# + "\n\n"
            + "data: not json at all\n\n"
            + "data: \n\n"
            + sseFrame("survivor")
            + #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\n"
            + "data: [DONE]\n\n"
        SSEStubURLProtocol.reset { _ in .sse(payload) }
        let recorder = DeltaRecorder()

        let text = try await complete(makeClient(), recorder: recorder)

        XCTAssertEqual(text, "survivor")
        XCTAssertEqual(recorder.deltas, ["survivor"])
    }

    /// A stream cut mid-frame ends with a line that has no newline and no closing
    /// brace. It is unparseable, and it must not cost the caller the deltas that
    /// arrived before it.
    func testTruncatedFinalLineIsSkipped() async throws {
        SSEStubURLProtocol.reset { _ in
            .sse(sseFrame("kept") + #"data: {"choices":[{"delta":{"content":"lo"#)
        }

        let text = try await complete(makeClient())

        XCTAssertEqual(text, "kept")
    }

    /// A multi-byte character split across two `didLoad` calls must not be
    /// corrupted, and neither must the `data:` line it sits inside. The gate
    /// forces a genuine boundary: the second chunk is not written until the first
    /// delta has already been handed to the caller.
    func testMultiByteCharacterSplitAcrossChunksIsNotCorrupted() async throws {
        let head = Data(sseFrame("A").utf8) + Data(#"data: {"choices":[{"delta":{"content":"caf"#.utf8)
        let accented = Array("é".utf8)
        XCTAssertEqual(accented.count, 2)

        let firstDelta = AsyncGate()
        SSEStubURLProtocol.reset { _ in
            .gated(
                [
                    head + Data([accented[0]]),
                    Data([accented[1]]) + Data(#""}}]}"# .utf8) + Data("\n\ndata: [DONE]\n\n".utf8),
                ],
                after: 1
            )
        }
        let recorder = DeltaRecorder(onEach: { _ in firstDelta.open() })

        let client = makeClient()
        let task = Task { try await self.complete(client, recorder: recorder) }
        await firstDelta.wait()
        SSEStubURLProtocol.release()

        let text = try await task.value
        XCTAssertEqual(text, "Acafé")
        XCTAssertEqual(recorder.deltas, ["A", "café"])
    }

    /// Groq frames its stream with CRLF. Nothing downstream may depend on the
    /// line terminator, so a CRLF stream has to yield the same text as an LF one.
    func testCRLFFramedStreamIsParsed() async throws {
        let payload = (sseFrame("crlf") + "data: [DONE]\n\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        SSEStubURLProtocol.reset { _ in .sse(payload) }

        let text = try await complete(makeClient())

        XCTAssertEqual(text, "crlf")
    }

    /// `[DONE]` ends the stream. A stray frame after it — a duplicated tail, a
    /// proxy replaying bytes — is not content the user dictated.
    func testContentAfterDoneIsIgnored() async throws {
        SSEStubURLProtocol.reset { _ in
            .sse(sseFrame("kept") + "data: [DONE]\n\n" + sseFrame("ghost"))
        }
        let recorder = DeltaRecorder()

        let text = try await complete(makeClient(), recorder: recorder)

        XCTAssertEqual(text, "kept")
        XCTAssertEqual(recorder.deltas, ["kept"])
    }

    /// A stream that carried no content at all is a failed mode pass, not an
    /// instruction to insert nothing. Reporting it as an error is what lets the
    /// pipeline fall back to the raw transcript (§6.4).
    func testStreamWithNoContentMapsToDecoding() async throws {
        SSEStubURLProtocol.reset { _ in .sse("data: [DONE]\n\n") }

        do {
            _ = try await complete(makeClient())
            XCTFail("expected a decoding failure")
        } catch let error as GroqChatError {
            XCTAssertEqual(error, .decoding)
        }
    }

    // MARK: Timeout

    /// Stopping the wait is not the same as stopping the request. A timeout that
    /// leaves the stream running fires `onDelta` after the caller has already
    /// given up and moved on.
    func testTimeoutThrowsTimedOutAndCancelsTheRequest() async throws {
        let requestArrived = AsyncGate()
        SSEStubURLProtocol.reset { _ in
            requestArrived.open()
            return .hang
        }
        let cancelled = expectation(description: "transport cancelled")
        SSEStubURLProtocol.onStopLoading { cancelled.fulfill() }
        let recorder = DeltaRecorder()

        // The clock fires only once the request has reached the transport, so
        // asserting on the cancellation cannot race the request going out.
        let client = makeClient(sleeper: { _ in await requestArrived.wait() })

        do {
            _ = try await complete(client, recorder: recorder)
            XCTFail("expected a timeout")
        } catch let error as GroqChatError {
            XCTAssertEqual(error, .timedOut)
        }

        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertGreaterThan(SSEStubURLProtocol.stopLoadingCount, 0)
        XCTAssertEqual(recorder.deltas, [])
    }

    /// The stream is one delta in and still open when the clock runs out.
    /// Everything the server sends afterwards must be dropped.
    func testNoDeltaArrivesAfterTheTimeoutThrows() async throws {
        let firstDelta = AsyncGate()
        SSEStubURLProtocol.reset { _ in
            .gated(
                [
                    Data(sseFrame("early").utf8),
                    Data((sseFrame("late") + "data: [DONE]\n\n").utf8),
                ],
                after: 1
            )
        }
        let recorder = DeltaRecorder(onEach: { _ in firstDelta.open() })

        let client = makeClient(sleeper: { _ in await firstDelta.wait() })

        do {
            _ = try await complete(client, recorder: recorder)
            XCTFail("expected a timeout")
        } catch let error as GroqChatError {
            XCTAssertEqual(error, .timedOut)
        }

        // The throw has already happened. Hand the stub its remaining bytes and
        // confirm none of them reach the caller.
        SSEStubURLProtocol.release()
        XCTAssertEqual(recorder.deltas, ["early"])
    }

    func testDefaultTimeoutMatchesTheSpec() {
        XCTAssertEqual(GroqChatClient.defaultTimeout, 2.5)
    }

    /// The gate is the half of the timeout guarantee that cancellation cannot
    /// provide: cancellation is observed at `await` points, and the parse loop
    /// can already be inside a synchronous `onDelta` when the clock runs out.
    func testDeltaGateStopsForwardingOnceClosed() {
        let recorder = DeltaRecorder()
        let gate = DeltaGate(onDelta: recorder.callback)

        gate.emit("before")
        gate.close()
        gate.emit("after")
        gate.emit("also after")

        XCTAssertEqual(recorder.deltas, ["before"])
    }

    // MARK: Failures

    func test401ThrowsHTTPStatus() async throws {
        SSEStubURLProtocol.reset { _ in
            .stream(
                status: 401,
                headers: [:],
                chunks: [Data(#"{"error":{"message":"Invalid API Key"}}"#.utf8)],
                gateAfter: nil
            )
        }

        do {
            _ = try await complete(makeClient())
            XCTFail("expected an HTTP failure")
        } catch let error as GroqChatError {
            XCTAssertEqual(error, .http(status: 401))
        }
    }

    func test500ThrowsHTTPStatus() async throws {
        SSEStubURLProtocol.reset { _ in
            .stream(status: 500, headers: [:], chunks: [], gateAfter: nil)
        }

        do {
            _ = try await complete(makeClient())
            XCTFail("expected an HTTP failure")
        } catch let error as GroqChatError {
            XCTAssertEqual(error, .http(status: 500))
        }
    }

    func testConnectivityFailureMapsToOffline() async throws {
        SSEStubURLProtocol.reset { _ in .failure(URLError(.notConnectedToInternet)) }

        do {
            _ = try await complete(makeClient())
            XCTFail("expected offline")
        } catch let error as GroqChatError {
            XCTAssertEqual(error, .offline)
        }
    }

    func testTransportTimeoutMapsToTimedOut() async throws {
        SSEStubURLProtocol.reset { _ in .failure(URLError(.timedOut)) }

        do {
            _ = try await complete(makeClient())
            XCTFail("expected a timeout")
        } catch let error as GroqChatError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testNonHTTPResponseMapsToDecoding() async throws {
        SSEStubURLProtocol.reset { _ in .nonHTTP }

        do {
            _ = try await complete(makeClient())
            XCTFail("expected a decoding failure")
        } catch let error as GroqChatError {
            XCTAssertEqual(error, .decoding)
        }
    }

    // MARK: Request

    func testRequestCarriesTheModelTemperatureStreamFlagAndMessages() async throws {
        SSEStubURLProtocol.reset { _ in .sse(sseFrame("ok") + "data: [DONE]\n\n") }

        _ = try await complete(makeClient())

        let request = try XCTUnwrap(SSEStubURLProtocol.requests.first)
        XCTAssertEqual(request.url.path, "/openai/v1/chat/completions")
        XCTAssertEqual(request.authorization, "Bearer test-key")
        XCTAssertEqual(request.accept, "text/event-stream")
        XCTAssertTrue(request.body.contains(#""model":"openai\/gpt-oss-20b""#)
            || request.body.contains(#""model":"openai/gpt-oss-20b""#))
        XCTAssertTrue(request.body.contains(#""stream":true"#))
        XCTAssertTrue(request.body.contains("0.2"))
        XCTAssertTrue(request.body.contains(#""role":"system""#))
        XCTAssertTrue(request.body.contains("SYSTEM"))
        XCTAssertTrue(request.body.contains(#""role":"user""#))
        XCTAssertTrue(request.body.contains("USER"))
    }

    /// The system message goes first. A user message ahead of the mode's
    /// instructions is a different prompt, and a worse one.
    func testSystemMessagePrecedesTheUserMessage() async throws {
        SSEStubURLProtocol.reset { _ in .sse(sseFrame("ok") + "data: [DONE]\n\n") }

        _ = try await complete(makeClient())

        let body = try XCTUnwrap(SSEStubURLProtocol.requests.first?.body)
        let system = try XCTUnwrap(body.range(of: #""role":"system""#))
        let user = try XCTUnwrap(body.range(of: #""role":"user""#))
        XCTAssertTrue(system.lowerBound < user.lowerBound)
    }
}
