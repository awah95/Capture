import XCTest
@testable import Captur

final class OpenBrainTests: XCTestCase {

    // MARK: - Test doubles

    /// A `URLProtocol` stub that returns a canned response (or fails with a canned
    /// error) and records the request that was sent, including its body.
    final class StubURLProtocol: URLProtocol {
        struct Response { let status: Int; let headers: [String: String]; let body: Data }

        static var response: Response?
        static var failure: Error?
        static var lastRequest: URLRequest?
        static var lastBody: Data?

        static func reset() {
            response = nil
            failure = nil
            lastRequest = nil
            lastBody = nil
        }

        static func session() -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubURLProtocol.self]
            return URLSession(configuration: config)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            StubURLProtocol.lastRequest = request
            StubURLProtocol.lastBody = StubURLProtocol.bodyData(from: request)

            if let failure = StubURLProtocol.failure {
                client?.urlProtocol(self, didFailWithError: failure)
                return
            }

            let stub = StubURLProtocol.response ?? Response(status: 200, headers: [:], body: Data())
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// URLSession often delivers a request's body via `httpBodyStream` rather
        /// than `httpBody` inside a `URLProtocol`, so read whichever is present.
        static func bodyData(from request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    /// A mutable, thread-safe clock for driving the queue's backoff schedule.
    final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        var current: Date {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    actor BlockingDrainSend {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var resultContinuation: CheckedContinuation<Bool, Never>?

        func send() async -> Bool {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            return await withCheckedContinuation { resultContinuation = $0 }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func finish(_ result: Bool) {
            resultContinuation?.resume(returning: result)
            resultContinuation = nil
        }
    }

    actor AttemptRecorder {
        private(set) var ids: [UUID] = []
        func record(_ id: UUID) { ids.append(id) }
    }

    private let config = OpenBrainConfig(
        endpoint: URL(string: "https://example.invalid")!,
        brainKey: "fake-test-key")

    private func makePayload() -> OpenBrainCapturePayload {
        OpenBrainCapturePayload(
            content: "hello brain",
            type: "thought",
            source_type: "quickcapture-mac",
            metadata: nil)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ob-queue-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Client: success

    func testSuccessfulCapturePostsCorrectRequestAndParsesID() async throws {
        StubURLProtocol.response = .init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"message":"Thought captured","thought":{"id":"thought-42"}}"#.utf8))

        let client = OpenBrainClient(session: StubURLProtocol.session())
        let id = try await client.capture(makePayload(), config: config)

        XCTAssertEqual(id, "thought-42")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/capture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-brain-key"), "fake-test-key")

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["content"] as? String, "hello brain")
        XCTAssertEqual(json["type"] as? String, "thought")
        XCTAssertEqual(json["source_type"] as? String, "quickcapture-mac")
        // Nil fields are omitted from the encoded body.
        XCTAssertNil(json["metadata"])
    }

    func testTopLevelIDIsParsed() async throws {
        StubURLProtocol.response = .init(
            status: 201,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"id":"top-level-id"}"#.utf8))

        let client = OpenBrainClient(session: StubURLProtocol.session())
        let id = try await client.capture(makePayload(), config: config)
        XCTAssertEqual(id, "top-level-id")
    }

    func testSuccessWithoutIDIsInvalidResponse() async throws {
        StubURLProtocol.response = .init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"message":"ok"}"#.utf8))

        let client = OpenBrainClient(session: StubURLProtocol.session())
        await XCTAssertThrowsErrorAsync(
            try await client.capture(makePayload(), config: config)
        ) { error in
            XCTAssertEqual(error as? OpenBrainError, .invalidResponse)
        }
    }

    func testSuccessNonJSONIsInvalidResponse() async {
        StubURLProtocol.response = .init(
            status: 200,
            headers: ["Content-Type": "text/plain"],
            body: Data("not json at all".utf8))

        let client = OpenBrainClient(session: StubURLProtocol.session())
        await XCTAssertThrowsErrorAsync(try await client.capture(makePayload(), config: config)) { error in
            XCTAssertEqual(error as? OpenBrainError, .invalidResponse)
        }
    }

    // MARK: - Client: errors

    func test401ReturnsHTTPError() async {
        StubURLProtocol.response = .init(
            status: 401,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"unauthorized"}"#.utf8))

        let client = OpenBrainClient(session: StubURLProtocol.session())
        await XCTAssertThrowsErrorAsync(try await client.capture(makePayload(), config: config)) { error in
            guard case let .http(status, message)? = error as? OpenBrainError else {
                return XCTFail("Expected .http, got \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertTrue(message.contains("unauthorized"))
        }
    }

    func testHTMLWAFBodySurfacesAsHTTPWithSnippet() async {
        let html = "<html><head><title>Attention Required! | Cloudflare</title></head>"
            + "<body>Sorry, you have been blocked</body></html>"
        StubURLProtocol.response = .init(
            status: 403,
            headers: ["Content-Type": "text/html"],
            body: Data(html.utf8))

        let client = OpenBrainClient(session: StubURLProtocol.session())
        await XCTAssertThrowsErrorAsync(try await client.capture(makePayload(), config: config)) { error in
            guard case let .http(status, message)? = error as? OpenBrainError else {
                return XCTFail("Expected .http, got \(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertTrue(message.contains("Cloudflare"))
            XCTAssertLessThanOrEqual(message.count, 200)
        }
    }

    func testLongErrorBodyIsTruncatedTo200Chars() async {
        let long = String(repeating: "x", count: 500)
        StubURLProtocol.response = .init(status: 500, headers: [:], body: Data(long.utf8))

        let client = OpenBrainClient(session: StubURLProtocol.session())
        await XCTAssertThrowsErrorAsync(try await client.capture(makePayload(), config: config)) { error in
            guard case let .http(_, message)? = error as? OpenBrainError else {
                return XCTFail("Expected .http, got \(error)")
            }
            XCTAssertEqual(message.count, 200)
        }
    }

    func testOfflineURLErrorMapsToOffline() async {
        StubURLProtocol.failure = URLError(.notConnectedToInternet)

        let client = OpenBrainClient(session: StubURLProtocol.session())
        await XCTAssertThrowsErrorAsync(try await client.capture(makePayload(), config: config)) { error in
            XCTAssertEqual(error as? OpenBrainError, .offline)
        }
    }

    func testEmptyKeyIsNotConfigured() async {
        let emptyConfig = OpenBrainConfig(endpoint: URL(string: "https://example.invalid")!, brainKey: "  ")
        let client = OpenBrainClient(session: StubURLProtocol.session())
        await XCTAssertThrowsErrorAsync(try await client.capture(makePayload(), config: emptyConfig)) { error in
            XCTAssertEqual(error as? OpenBrainError, .notConfigured)
        }
        XCTAssertNil(StubURLProtocol.lastRequest, "No request should be sent when not configured")
    }

    // MARK: - Queue: drain

    func testEnqueueAndDrainSuccessRemoves() async throws {
        let dir = try tempDir()
        let queue = OpenBrainSyncQueue(directory: dir)
        let id1 = UUID(), id2 = UUID()
        await queue.enqueue(id1)
        await queue.enqueue(id2)

        var sent: [UUID] = []
        await queue.drain { id in sent.append(id); return true }

        XCTAssertEqual(sent, [id1, id2])
        let pending = await queue.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testDrainFailureRetainsOrderAndStops() async throws {
        let dir = try tempDir()
        let queue = OpenBrainSyncQueue(directory: dir)
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        await queue.enqueue(id1)
        await queue.enqueue(id2)
        await queue.enqueue(id3)

        var attempted: [UUID] = []
        // Succeed on the first, fail on the second — must stop before the third.
        await queue.drain { id in
            attempted.append(id)
            return id == id1
        }

        XCTAssertEqual(attempted, [id1, id2], "Drain must stop at the first failure")
        let pending = await queue.pending()
        XCTAssertEqual(pending, [id2, id3], "Failed + untried ids remain in FIFO order")
    }

    func testConcurrentDrainReturnsWhileFirstSendIsSuspended() async throws {
        let queue = OpenBrainSyncQueue(directory: try tempDir())
        let id1 = UUID(), id2 = UUID()
        await queue.enqueue(id1)
        await queue.enqueue(id2)
        let blocker = BlockingDrainSend()
        let secondAttempts = AttemptRecorder()

        let firstDrain = Task {
            await queue.drain { _ in await blocker.send() }
        }
        await blocker.waitUntilStarted()

        await queue.drain { id in
            await secondAttempts.record(id)
            return true
        }

        await blocker.finish(false)
        await firstDrain.value

        let attempts = await secondAttempts.ids
        let pending = await queue.pending()
        XCTAssertEqual(attempts, [])
        XCTAssertEqual(pending, [id1, id2])
    }

    func testEnqueueDeduplicatesIDs() async throws {
        let queue = OpenBrainSyncQueue(directory: try tempDir())
        let id = UUID()
        await queue.enqueue(id)
        await queue.enqueue(id)
        let pending = await queue.pending()
        XCTAssertEqual(pending, [id])
    }

    func testBackoffScheduleRespectedViaInjectedClock() async throws {
        let dir = try tempDir()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let clock = MutableClock(start)
        let queue = OpenBrainSyncQueue(directory: dir, now: { clock.current })
        await queue.enqueue(UUID())

        // First failure → wait 30s.
        await queue.drain { _ in false }
        var next = await queue.nextAttempt()
        XCTAssertEqual(next, start.addingTimeInterval(30))

        // Before nextAttemptAt, drain is a no-op (send is never invoked).
        clock.current = start.addingTimeInterval(29)
        var called = false
        await queue.drain { _ in called = true; return false }
        XCTAssertFalse(called, "Drain must be a no-op before nextAttemptAt")

        // At/after the deadline it retries; a second failure doubles to 60s.
        clock.current = start.addingTimeInterval(30)
        await queue.drain { _ in false }
        next = await queue.nextAttempt()
        XCTAssertEqual(next, clock.current.addingTimeInterval(60))

        // Third failure doubles to 120s.
        clock.current = clock.current.addingTimeInterval(60)
        await queue.drain { _ in false }
        next = await queue.nextAttempt()
        XCTAssertEqual(next, clock.current.addingTimeInterval(120))
    }

    func testBackoffDoublesAndCapsAtTenMinutes() async throws {
        let dir = try tempDir()
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 0))
        let queue = OpenBrainSyncQueue(directory: dir, now: { clock.current })
        await queue.enqueue(UUID())

        // Fail repeatedly, each time jumping the clock to the scheduled deadline
        // so the next attempt runs, and record the gap between deadlines.
        var gaps: [TimeInterval] = []
        var previous = clock.current
        for _ in 0..<8 {
            await queue.drain { _ in false }
            let scheduled = await queue.nextAttempt()
            let next = try XCTUnwrap(scheduled)
            gaps.append(next.timeIntervalSince(previous))
            clock.current = next
            previous = next
        }

        // 30 → 60 → 120 → 240 → 480, then capped at 600 (10 minutes).
        XCTAssertEqual(gaps, [30, 60, 120, 240, 480, 600, 600, 600])
    }

    func testSuccessfulSendResetsBackoff() async throws {
        let dir = try tempDir()
        let start = Date(timeIntervalSinceReferenceDate: 5000)
        let clock = MutableClock(start)
        let queue = OpenBrainSyncQueue(directory: dir, now: { clock.current })
        let id1 = UUID(), id2 = UUID()
        await queue.enqueue(id1)
        await queue.enqueue(id2)

        // Fail once → backoff engaged.
        await queue.drain { _ in false }
        let engaged = await queue.nextAttempt()
        XCTAssertNotNil(engaged)

        // After the wait, succeed on id1 then fail on id2 → nextAttempt uses the
        // reset floor (30s), proving a success reset the backoff.
        clock.current = start.addingTimeInterval(30)
        await queue.drain { id in id == id1 }
        let scheduled = await queue.nextAttempt()
        let next = try XCTUnwrap(scheduled)
        XCTAssertEqual(next, clock.current.addingTimeInterval(30))
    }

    // MARK: - Queue: durability

    func testCorruptQueueFileBacksUpAndStartsEmpty() async throws {
        let dir = try tempDir()
        let fileURL = dir.appendingPathComponent("ob-queue.json")
        try Data("{ this is not valid json ]".utf8).write(to: fileURL)

        let queue = OpenBrainSyncQueue(directory: dir)
        let pending = await queue.pending()
        XCTAssertTrue(pending.isEmpty, "Corrupt queue starts empty")

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(
            contents.contains { $0.contains("corrupt") },
            "The corrupt file must be backed up alongside, not lost. Found: \(contents)")
    }

    func testPersistenceAcrossInstances() async throws {
        let dir = try tempDir()
        let id1 = UUID(), id2 = UUID()

        let first = OpenBrainSyncQueue(directory: dir)
        await first.enqueue(id1)
        await first.enqueue(id2)

        // A fresh instance over the same directory reloads the pending list.
        let second = OpenBrainSyncQueue(directory: dir)
        let pending = await second.pending()
        XCTAssertEqual(pending, [id1, id2])
    }
}

// MARK: - Async throwing assertion helper

extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: String = "Expected an error to be thrown",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ handler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail(message, file: file, line: line)
        } catch {
            handler(error)
        }
    }
}
