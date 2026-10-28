import XCTest
@testable import Captur

final class StubURLProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: URLError?
    }

    nonisolated(unsafe) static var stub = Stub()

    /// The multipart body of the most recent request, decoded as UTF-8. The
    /// fixtures are ASCII, so the headers inside it are directly assertable.
    nonisolated(unsafe) static var lastBody = ""

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastBody = Self.readBody(from: request)

        if let error = Self.stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: Self.stub.headers
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Self.stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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

final class GroqTransportTests: XCTestCase {
    private func makeClient() -> GroqClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return GroqClient(
            session: URLSession(configuration: configuration)
        )
    }

    private func audioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 2_048).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testSuccessReturnsText() async throws {
        StubURLProtocol.stub = .init(
            statusCode: 200,
            body: #"{"text":"hello world"}"#.data(using: .utf8)!
        )

        let text = try await makeClient().transcribeAudio(
            fileURL: try audioFile(),
            apiKey: "test-key",
            prompt: nil
        )

        XCTAssertEqual(text, "hello world")
    }

    func test401IsPermanentAndNotRetried() async throws {
        StubURLProtocol.stub = .init(
            statusCode: 401,
            body: #"{"error":{"message":"Invalid API Key"}}"#
                .data(using: .utf8)!
        )

        do {
            _ = try await makeClient().transcribeAudio(
                fileURL: try audioFile(),
                apiKey: "bad-test-key",
                prompt: nil
            )
            XCTFail("expected permanent failure")
        } catch let GroqError.permanent(status, _) {
            XCTAssertEqual(status, 401)
        }
    }

    func test429SurfacesTransientWithRetryAfter() async throws {
        StubURLProtocol.stub = .init(
            statusCode: 429,
            headers: ["Retry-After": "3"],
            body: #"{"error":{"message":"slow down"}}"#
                .data(using: .utf8)!
        )

        do {
            _ = try await makeClient().transcribeAudio(
                fileURL: try audioFile(),
                apiKey: "test-key",
                prompt: nil
            )
            XCTFail("expected transient failure")
        } catch let GroqError.transient(
            status,
            _,
            retryAfter
        ) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(retryAfter, 3)
        }
    }

    func test5xxIsTransient() async throws {
        StubURLProtocol.stub = .init(
            statusCode: 503,
            body: Data()
        )

        do {
            _ = try await makeClient().transcribeAudio(
                fileURL: try audioFile(),
                apiKey: "test-key",
                prompt: nil
            )
            XCTFail("expected transient failure")
        } catch let GroqError.transient(status, _, _) {
            XCTAssertEqual(status, 503)
        }
    }

    func testConnectivityFailureMapsToOffline() async throws {
        StubURLProtocol.stub = .init(
            error: URLError(.notConnectedToInternet)
        )

        do {
            _ = try await makeClient().transcribeAudio(
                fileURL: try audioFile(),
                apiKey: "test-key",
                prompt: nil
            )
            XCTFail("expected offline")
        } catch GroqError.offline {
            // Expected.
        }
    }

    func testMalformedSuccessBodyMapsToDecoding() async throws {
        StubURLProtocol.stub = .init(
            statusCode: 200,
            body: Data("not json at all".utf8)
        )

        do {
            _ = try await makeClient().transcribeAudio(
                fileURL: try audioFile(),
                apiKey: "test-key",
                prompt: nil
            )
            XCTFail("expected decoding failure")
        } catch GroqError.decoding {
            // Expected.
        }
    }

    func testCancellationMapsToCancelled() async throws {
        StubURLProtocol.stub = .init(
            error: URLError(.cancelled)
        )

        do {
            _ = try await makeClient().transcribeAudio(
                fileURL: try audioFile(),
                apiKey: "test-key",
                prompt: nil
            )
            XCTFail("expected cancelled")
        } catch GroqError.cancelled {
            // Expected.
        }
    }

    func testMissingFileIsReported() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "does-not-exist-\(UUID().uuidString).m4a"
            )

        do {
            _ = try await makeClient().transcribeAudio(
                fileURL: missing,
                apiKey: "test-key",
                prompt: nil
            )
            XCTFail("expected fileMissing")
        } catch GroqError.fileMissing {
            // Expected.
        }
    }

    func testMultipartBodyTempFilesAreCleanedUp() async throws {
        StubURLProtocol.stub = .init(
            statusCode: 200,
            body: #"{"text":"ok"}"#.data(using: .utf8)!
        )

        _ = try await makeClient().transcribeAudio(
            fileURL: try audioFile(),
            apiKey: "test-key",
            prompt: "hint"
        )

        // The temp directory is shared with every other suite in this process,
        // and a body file legitimately exists for the lifetime of its upload.
        // Poll instead of sampling once, so a concurrent segment upload from
        // GroqTranscriberTests cannot masquerade as a leak: a genuinely leaked
        // file never disappears, so it still fails.
        var leftovers = Self.uploadBodyLeftovers()
        let deadline = Date().addingTimeInterval(3)
        while !leftovers.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            leftovers = Self.uploadBodyLeftovers()
        }

        XCTAssertTrue(
            leftovers.isEmpty,
            "multipart body temp files must be cleaned up; leftovers: \(leftovers)"
        )
    }

    private static func uploadBodyLeftovers() -> [String] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        return (contents ?? [])
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("groq-upload-") }
    }

    // MARK: - Upload metadata

    /// Writes an audio fixture with the given extension and uploads it.
    private func upload(extension ext: String) async throws -> String {
        StubURLProtocol.stub = .init(
            statusCode: 200,
            body: Data(#"{"text":"ok"}"#.utf8)
        )
        StubURLProtocol.lastBody = ""

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-\(UUID().uuidString).\(ext)")
        try Data("AUDIOBYTES".utf8).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }

        _ = try await makeClient().transcribeAudio(
            fileURL: url,
            apiKey: "test-key",
            prompt: nil
        )
        return StubURLProtocol.lastBody
    }

    /// The recorder writes native FLAC. Labelling it `capture.m4a` / `audio/m4a`
    /// is a lie Groq is entitled to act on.
    func testFLACUploadDeclaresFLACFilenameAndContentType() async throws {
        let body = try await upload(extension: "flac")

        XCTAssertTrue(
            body.contains(#"filename="capture.flac""#),
            "body was: \(body.prefix(400))"
        )
        XCTAssertTrue(
            body.contains("Content-Type: audio/flac"),
            "body was: \(body.prefix(400))"
        )
        XCTAssertFalse(body.contains("audio/m4a"))
    }

    func testM4AUploadStillDeclaresM4A() async throws {
        let body = try await upload(extension: "m4a")

        XCTAssertTrue(body.contains(#"filename="capture.m4a""#))
        XCTAssertTrue(body.contains("Content-Type: audio/m4a"))
    }

    func testUnknownExtensionFallsBackToOpaqueBytes() async throws {
        let body = try await upload(extension: "xyz")

        XCTAssertTrue(body.contains(#"filename="capture.xyz""#))
        XCTAssertTrue(body.contains("Content-Type: application/octet-stream"))
    }

    func testUploadPartMapsEveryDocumentedFormat() {
        let expected: [String: String] = [
            "flac": "audio/flac",
            "m4a": "audio/m4a",
            "mp3": "audio/mpeg",
            "wav": "audio/wav",
            "ogg": "audio/ogg",
            "webm": "audio/webm",
        ]

        for (ext, contentType) in expected {
            let part = GroqClient.uploadPart(
                for: URL(fileURLWithPath: "/tmp/clip.\(ext)")
            )
            XCTAssertEqual(part.contentType, contentType, "for .\(ext)")
            XCTAssertEqual(part.filename, "capture.\(ext)")
        }
    }

    func testUploadPartIsCaseInsensitiveAndSanitisesTheName() {
        let upper = GroqClient.uploadPart(for: URL(fileURLWithPath: "/tmp/clip.FLAC"))
        XCTAssertEqual(upper.contentType, "audio/flac")
        XCTAssertEqual(upper.filename, "capture.flac")

        // A filename can never break out of the Content-Disposition header.
        let hostile = GroqClient.uploadPart(
            for: URL(fileURLWithPath: #"/tmp/clip.a"b"#)
        )
        XCTAssertFalse(hostile.filename.contains("\""))

        let bare = GroqClient.uploadPart(for: URL(fileURLWithPath: "/tmp/clip"))
        XCTAssertEqual(bare.filename, "capture")
        XCTAssertEqual(bare.contentType, "application/octet-stream")
    }

    func testModelAndLanguageAreSentWhenGiven() async throws {
        StubURLProtocol.stub = .init(
            statusCode: 200,
            body: Data(#"{"text":"ok"}"#.utf8)
        )
        StubURLProtocol.lastBody = ""

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-\(UUID().uuidString).flac")
        try Data("AUDIOBYTES".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        _ = try await makeClient().transcribe(
            fileURL: url,
            apiKey: "test-key",
            prompt: nil,
            maxRetries: 0,
            model: "whisper-large-v3",
            language: "en"
        )

        let body = StubURLProtocol.lastBody
        XCTAssertTrue(body.contains("whisper-large-v3"))
        XCTAssertTrue(body.contains(#"name="language""#))
    }

    func testLanguageIsOmittedWhenNotGiven() async throws {
        let body = try await upload(extension: "flac")
        XCTAssertFalse(body.contains(#"name="language""#))
        XCTAssertTrue(body.contains(GroqClient.defaultModel))
    }
}
