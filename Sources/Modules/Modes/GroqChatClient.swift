import Foundation

/// The mode's LLM pass: one streaming chat completion against Groq (spec §6.4).
///
/// Streamed so the capsule can show the text arriving, but the caller inserts
/// once, on completion — a partial insertion that then gets corrected is worse
/// than a short wait.
protocol GroqChatting: AnyObject, Sendable {
    /// - Parameter onDelta: called with each content fragment as it arrives, in
    ///   order. Never called after this function has returned or thrown.
    func complete(systemMessage: String, userMessage: String, model: String,
                  temperature: Double, apiKey: String, timeout: TimeInterval,
                  onDelta: @escaping @Sendable (String) -> Void) async throws -> String
}

/// Every case means the same thing to the pipeline — insert the raw transcript
/// and say the mode was skipped — so the distinctions exist for diagnostics and
/// for the Settings warning, not for control flow.
enum GroqChatError: LocalizedError, Equatable {
    case timedOut
    case http(status: Int)
    case offline
    case decoding

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "The preview timed out. Try again."
        case .http(let status) where status == 401:
            return "Groq rejected the API key. Check it in Settings and try again."
        case .http(let status):
            return "Groq couldn't create the preview (HTTP \(status))."
        case .offline:
            return "You appear to be offline. Reconnect and try the preview again."
        case .decoding:
            return "Captur couldn't read Groq's response. Try again."
        }
    }
}

/// Forwards streamed deltas to the caller's callback, and stops forever once
/// closed.
///
/// Cancelling the `URLSession` stream is not by itself enough to keep the promise
/// that `onDelta` is never called after `complete` throws. Cancellation is
/// cooperative — it is observed at `await` points — and the parse loop can
/// already be inside a synchronous `onDelta`, repainting the capsule, at the
/// moment the clock runs out. The gate closes that window: `close()` holds the
/// lock across any in-flight callback, so once it returns no delta is in flight
/// and no further delta will ever start.
///
/// The one constraint that buys: `onDelta` must not call back into the gate.
/// Nothing in the pipeline does — it hands text to the capsule and returns.
///
/// Honest caveat: with structured cancellation working, no stubbed transport can
/// actually deliver a byte after the throw, so removing the `close()` *call
/// sites* fails no test — only `close()` itself is covered. The gate is kept
/// anyway. The protocol publishes "never called after this function returns" as
/// a contract, and resting that contract entirely on cooperative cancellation
/// behaving as documented is the assumption this codebase keeps getting burned by.
final class DeltaGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClosed = false
    private let onDelta: @Sendable (String) -> Void

    init(onDelta: @escaping @Sendable (String) -> Void) {
        self.onDelta = onDelta
    }

    func emit(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        onDelta(text)
    }

    func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
    }
}

/// Streaming chat-completion client.
///
/// Conventions match `GroqClient`: the API key is set as a header and never
/// logged (this file contains no logging at all), the transport is injected so
/// tests never touch the network, and every failure is mapped to one enum rather
/// than leaking `URLError` to callers.
final class GroqChatClient: GroqChatting {

    private static let endpoint = URL(
        string: "https://api.groq.com/openai/v1/chat/completions"
    )!

    /// Spec §6.4. Past this the user is better served by their raw words landing
    /// than by a better-formatted version of them arriving late.
    static let defaultTimeout: TimeInterval = 2.5

    private let session: URLSession

    /// The timeout clock. Injected so tests can order events causally instead of
    /// spending real seconds; the production sleeper is `Task.sleep`, which is
    /// cancellable — the client cancels it the instant the stream wins.
    private let sleeper: @Sendable (TimeInterval) async -> Void

    init(
        session: URLSession = .shared,
        sleeper: (@Sendable (TimeInterval) async -> Void)? = nil
    ) {
        self.session = session
        self.sleeper = sleeper ?? { seconds in
            // Clamped at both ends: `UInt64(_: Double)` traps on a negative, and
            // a nonsense timeout must not park a dictation for an hour.
            let clamped = min(max(seconds, 0), 60)
            try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
        }
    }

    // MARK: - GroqChatting

    func complete(
        systemMessage: String,
        userMessage: String,
        model: String,
        temperature: Double,
        apiKey: String,
        timeout: TimeInterval,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let gate = DeltaGate(onDelta: onDelta)
        // Every exit path — success, timeout, HTTP error, transport failure —
        // ends with the callback shut off, so the contract holds without each
        // branch having to remember it.
        defer { gate.close() }

        let request = try makeRequest(
            systemMessage: systemMessage,
            userMessage: userMessage,
            model: model,
            temperature: temperature,
            apiKey: apiKey,
            timeout: timeout
        )

        // Two children race: the stream, which returns the text, and the clock,
        // which returns nil. `cancelAll` on either outcome is what makes the
        // timeout a *cancellation* rather than just an early return — a stream
        // still running after the caller gave up would keep firing deltas into a
        // capsule that has moved on.
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { [session] in
                try await Self.stream(request: request, session: session, gate: gate)
            }
            group.addTask { [sleeper] in
                await sleeper(timeout)
                return nil
            }

            while let outcome = try await group.next() {
                guard let text = outcome else {
                    // The clock won. Distinguish it from the caller cancelling
                    // us, which also unblocks the sleeper but is not a timeout.
                    try Task.checkCancellation()
                    gate.close()
                    group.cancelAll()
                    throw GroqChatError.timedOut
                }
                group.cancelAll()
                return text
            }

            // Unreachable: the group has two children and both of them either
            // return a value or throw.
            throw GroqChatError.decoding
        }
    }

    // MARK: - Streaming

    private static func stream(
        request: URLRequest,
        session: URLSession,
        gate: DeltaGate
    ) async throws -> String {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw map(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GroqChatError.decoding
        }
        guard (200...299).contains(http.statusCode) else {
            // The error body is not read: nothing downstream shows it, and
            // draining a rejected stream only delays the fallback insertion.
            throw GroqChatError.http(status: http.statusCode)
        }

        let decoder = JSONDecoder()
        var accumulated = ""

        do {
            // `AsyncLineSequence` decodes UTF-8 incrementally over the byte
            // stream, so a multi-byte character split across two network chunks
            // is reassembled rather than turned into a replacement character —
            // which is exactly what per-chunk `String(data:encoding:)` would do.
            frames: for try await rawLine in bytes.lines {
                try Task.checkCancellation()

                switch parse(rawLine, decoder: decoder) {
                case .ignore:
                    continue
                case .done:
                    break frames
                case .delta(let text):
                    accumulated += text
                    gate.emit(text)
                }
            }
        } catch {
            throw map(error)
        }

        // A stream that carried no content is a failed mode pass, not an
        // instruction to insert nothing. Reporting it lets the caller fall back
        // to the raw transcript (§6.4) instead of silently swallowing the user's
        // words.
        guard !accumulated.isEmpty else {
            throw GroqChatError.decoding
        }
        return accumulated
    }

    private enum Frame {
        case ignore
        case done
        case delta(String)
    }

    /// Parses one SSE line.
    ///
    /// Everything that is not a content delta is ignored rather than fatal. A
    /// real Groq stream contains keep-alive comments, blank separator lines,
    /// frames carrying only a `role` or a `finish_reason`, and — when the
    /// connection dies mid-frame — a final line that is half-written JSON with no
    /// newline. Aborting on any of those would throw away every delta already
    /// received and cost the user their formatting for the sake of one bad line.
    private static func parse(_ rawLine: String, decoder: JSONDecoder) -> Frame {
        // Groq frames with CRLF. `AsyncLineSequence` was measured to strip the
        // carriage return itself, so this branch is currently unreachable —
        // deleting it changes no test. It stays because the terminator handling
        // is a Foundation implementation detail and one stray `\r` would turn
        // every payload into undecodable JSON, i.e. silently drop the whole
        // response. `testCRLFFramedStreamIsParsed` is the actual guarantee.
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

        // Blank = frame separator, leading colon = comment.
        guard !line.isEmpty, !line.hasPrefix(":") else { return .ignore }
        // `event:`, `id:`, `retry:` — structural, never content.
        guard line.hasPrefix("data:") else { return .ignore }

        let payload = line
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return .ignore }
        if payload == "[DONE]" { return .done }

        guard
            let chunk = try? decoder.decode(
                ChatStreamChunk.self, from: Data(payload.utf8)
            ),
            let content = chunk.choices?.first?.delta?.content,
            !content.isEmpty
        else {
            return .ignore
        }
        return .delta(content)
    }

    // MARK: - Request

    private func makeRequest(
        systemMessage: String,
        userMessage: String,
        model: String,
        temperature: Double,
        apiKey: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // A second guard beneath the logical clock: if the process is suspended
        // mid-stream and the task group never gets to run, URLSession still lets
        // go on its own.
        request.timeoutInterval = min(max(timeout, 0.5), 60)

        let body = ChatRequest(
            model: model,
            temperature: temperature,
            stream: true,
            messages: [
                // System first. A user message ahead of the mode's instructions
                // is a different prompt, and a worse one.
                ChatRequest.Message(role: "system", content: systemMessage),
                ChatRequest.Message(role: "user", content: userMessage),
            ]
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            // Unreachable for `String` payloads, but a throw beats a `try!`.
            throw GroqChatError.decoding
        }
        return request
    }

    // MARK: - Error mapping

    private static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let chat = error as? GroqChatError { return chat }
        guard let urlError = error as? URLError else { return GroqChatError.decoding }

        switch urlError.code {
        case .cancelled:
            // The caller's own cancellation. Our timeout throws `.timedOut` from
            // the group body before this can escape, so reaching here means the
            // task above us was cancelled and deserves the honest answer.
            return CancellationError()
        case .timedOut:
            return GroqChatError.timedOut
        default:
            // No connection, DNS, TLS, a stream dropped mid-response: all
            // indistinguishable to the caller, which reacts to every failure the
            // same way. `.offline` is the honest label for "the request never
            // completed, and not because the server answered".
            return GroqChatError.offline
        }
    }
}

// MARK: - Wire format

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let temperature: Double
    let stream: Bool
    let messages: [Message]
}

/// Every field optional on purpose: a frame that carries no `content` is a
/// routine part of the stream, and it must decode successfully so `parse` can
/// ignore it instead of treating it as corruption.
private struct ChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta?
    }

    let choices: [Choice]?
}
