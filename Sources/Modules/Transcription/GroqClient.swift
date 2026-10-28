import Foundation

struct GroqClient: Sendable {
    private static let endpoint = URL(
        string: "https://api.groq.com/openai/v1/audio/transcriptions"
    )!
    /// The model used unless a caller names another one.
    static let defaultModel = "whisper-large-v3-turbo"
    private static let chunkSize = 64 * 1024

    /// Groq's documented upload formats, mapped to the MIME type the multipart
    /// part must declare. Anything else is sent as opaque bytes and left for the
    /// server to sniff or reject — better than mislabelling it.
    /// Every extension the uploader can label correctly. Exposed so instruments can accept
    /// exactly what the client accepts: `--probe-latency` used to filter arguments on
    /// `.flac` alone and silently fall back to the newest saved capture when handed
    /// anything else — while printing the fallback's name as though it were the file
    /// requested. That made an A/B of two encodings impossible to run and easy to
    /// misread, which is the one measurement the encoding decision needs.
    static var supportedAudioExtensions: [String] { Array(contentTypesByExtension.keys) }

    private static let contentTypesByExtension: [String: String] = [
        "flac": "audio/flac",
        "m4a": "audio/m4a",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "webm": "audio/webm",
    ]

    /// The `filename` and `Content-Type` the file part should carry.
    ///
    /// Both are derived from the file actually being uploaded. Declaring a fixed
    /// `capture.m4a` / `audio/m4a` for every upload is a lie the moment the
    /// recorder writes anything else — the app records native FLAC — and Groq
    /// dispatches its decoder on what the part claims to be.
    ///
    /// The name is rebuilt from the extension rather than passed through, so a
    /// quote or newline in a temp filename can never break out of the header.
    static func uploadPart(for fileURL: URL) -> (filename: String, contentType: String) {
        let ext = fileURL.pathExtension.lowercased()
        guard let contentType = contentTypesByExtension[ext] else {
            return (
                filename: ext.isEmpty ? "capture" : "capture.\(sanitized(ext))",
                contentType: "application/octet-stream"
            )
        }
        return (filename: "capture.\(ext)", contentType: contentType)
    }

    private static func sanitized(_ ext: String) -> String {
        let allowed = ext.filter { $0.isLetter || $0.isNumber }
        return allowed.isEmpty ? "bin" : allowed
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(
        fileURL: URL,
        apiKey: String,
        prompt: String?,
        maxRetries: Int = 0,
        model: String = GroqClient.defaultModel,
        language: String? = nil
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GroqError.fileMissing
        }

        let retryCount = max(0, maxRetries)
        var lastTransient: GroqError?

        for attempt in 0...retryCount {
            do {
                try Task.checkCancellation()
            } catch {
                throw GroqError.cancelled
            }

            do {
                return try await performRequest(
                    fileURL: fileURL,
                    apiKey: apiKey,
                    prompt: prompt,
                    model: model,
                    language: language
                )
            } catch let error as GroqError {
                switch error {
                case .transient, .offline:
                    lastTransient = error
                default:
                    throw error
                }

                if attempt == retryCount {
                    break
                }

                let base = 0.8
                let backoff = base * pow(2.0, Double(attempt))
                let jitter = 0.05 * Double(attempt + 1)
                let delay = backoff + jitter

                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                } catch {
                    throw GroqError.cancelled
                }
            }
        }

        if let lastTransient {
            switch lastTransient {
            case .offline:
                throw GroqError.offline
            case .transient(let status, let message, let retryAfter):
                if status == 0 {
                    throw GroqError.offline
                }
                throw GroqError.transient(
                    status: status,
                    message: message,
                    retryAfter: retryAfter
                )
            default:
                throw lastTransient
            }
        }

        throw GroqError.transient(
            status: 0,
            message: "Unknown transcription failure.",
            retryAfter: nil
        )
    }

    private func performRequest(
        fileURL: URL,
        apiKey: String,
        prompt: String?,
        model: String,
        language: String?
    ) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyURL = try makeMultipartBodyFile(
            fileURL: fileURL,
            boundary: boundary,
            prompt: prompt,
            model: model,
            language: language
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(
                for: request,
                fromFile: bodyURL
            )
        } catch let error as URLError {
            throw Self.mapURLError(error)
        } catch is CancellationError {
            throw GroqError.cancelled
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqError.transient(
                status: 0,
                message: "Missing or invalid HTTP response.",
                retryAfter: nil
            )
        }

        let status = httpResponse.statusCode
        if (200...299).contains(status) {
            do {
                return try JSONDecoder()
                    .decode(TranscriptionResponse.self, from: data)
                    .text
            } catch {
                throw GroqError.decoding(
                    "Could not decode transcription response: \(error.localizedDescription)"
                )
            }
        }

        let message = Self.extractErrorMessage(from: data)
            ?? HTTPURLResponse.localizedString(forStatusCode: status)

        if Self.isTransientStatus(status) {
            throw GroqError.transient(
                status: status,
                message: message,
                retryAfter: Self.retryAfterSeconds(from: httpResponse)
            )
        }

        throw GroqError.permanent(status: status, message: message)
    }

    private func makeMultipartBodyFile(
        fileURL: URL,
        boundary: String,
        prompt: String?,
        model: String,
        language: String?
    ) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("groq-upload-\(UUID().uuidString).body")

        FileManager.default.createFile(
            atPath: tempURL.path,
            contents: nil
        )
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        guard let output = FileHandle(forWritingAtPath: tempURL.path) else {
            throw GroqError.decoding(
                "Could not create temporary upload body."
            )
        }
        defer { try? output.close() }

        let newline = "\r\n"
        let dashes = "--"

        func fieldPart(name: String, value: String) -> String {
            "\(dashes)\(boundary)\(newline)"
                + "Content-Disposition: form-data; name=\"\(name)\""
                + "\(newline)\(newline)\(value)\(newline)"
        }

        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var prefix = ""
        prefix += fieldPart(
            name: "model",
            value: resolvedModel.isEmpty ? Self.defaultModel : resolvedModel
        )
        prefix += fieldPart(name: "response_format", value: "json")
        prefix += fieldPart(name: "temperature", value: "0")
        if let language,
           !language.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            prefix += fieldPart(name: "language", value: language)
        }
        if let prompt,
           !prompt.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            prefix += fieldPart(name: "prompt", value: prompt)
        }

        let part = Self.uploadPart(for: fileURL)
        prefix += "\(dashes)\(boundary)\(newline)"
        prefix += "Content-Disposition: form-data; name=\"file\"; "
            + "filename=\"\(part.filename)\"\(newline)"
        prefix += "Content-Type: \(part.contentType)\(newline)\(newline)"

        guard let prefixData = prefix.data(using: .utf8) else {
            throw GroqError.decoding(
                "Failed to encode multipart prefix."
            )
        }
        output.write(prefixData)

        guard let input = FileHandle(forReadingAtPath: fileURL.path) else {
            throw GroqError.fileMissing
        }
        defer { try? input.close() }

        while true {
            let chunk = input.readData(ofLength: Self.chunkSize)
            if chunk.isEmpty {
                break
            }
            output.write(chunk)
        }

        let suffix = "\(newline)\(dashes)\(boundary)\(dashes)\(newline)"
        guard let suffixData = suffix.data(using: .utf8) else {
            throw GroqError.decoding(
                "Failed to encode multipart suffix."
            )
        }
        output.write(suffixData)

        completed = true
        return tempURL
    }

    private static func isTransientStatus(_ status: Int) -> Bool {
        switch status {
        case 408, 409, 425, 429, 500...599:
            return true
        default:
            return false
        }
    }

    private static func retryAfterSeconds(
        from response: HTTPURLResponse
    ) -> TimeInterval? {
        guard
            let raw = response.value(
                forHTTPHeaderField: "Retry-After"
            ),
            let seconds = TimeInterval(
                raw.trimmingCharacters(in: .whitespaces)
            ),
            seconds >= 0
        else {
            return nil
        }
        return min(seconds, 120)
    }

    private static func mapURLError(_ error: URLError) -> GroqError {
        if error.code == .cancelled {
            return .cancelled
        }
        return .transient(
            status: 0,
            message: error.localizedDescription,
            retryAfter: nil
        )
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        try? JSONDecoder()
            .decode(GroqErrorEnvelope.self, from: data)
            .error.message
    }
}

extension GroqClient: GroqTransporting {
    func transcribeAudio(
        fileURL: URL,
        apiKey: String,
        prompt: String?
    ) async throws -> String {
        try await transcribe(
            fileURL: fileURL,
            apiKey: apiKey,
            prompt: prompt,
            maxRetries: 0
        )
    }
}

private struct TranscriptionResponse: Codable, Sendable {
    let text: String
}

private struct GroqErrorEnvelope: Codable, Sendable {
    struct APIError: Codable, Sendable {
        let message: String
        let type: String?
        let code: String?
    }

    let error: APIError
}

enum GroqError: LocalizedError, Sendable {
    case offline
    case transient(
        status: Int,
        message: String,
        retryAfter: TimeInterval?
    )
    case permanent(status: Int, message: String)
    case decoding(String)
    case cancelled
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .offline:
            return "You appear to be offline. The capture will be queued "
                + "and uploaded when a connection is available."
        case .transient(let status, let message, _):
            if status == 0 {
                return "A temporary network problem occurred: \(message)"
            }
            return "A temporary server error occurred "
                + "(HTTP \(status)): \(message)"
        case .permanent(let status, let message):
            if status == 401 {
                return "Authentication failed (HTTP 401). "
                    + "Please check your Groq API key. \(message)"
            }
            return "The request failed (HTTP \(status)): \(message)"
        case .decoding(let detail):
            return "Could not read the server's response: \(detail)"
        case .cancelled:
            return "The transcription was cancelled."
        case .fileMissing:
            return "The audio file could not be found or read."
        }
    }
}
