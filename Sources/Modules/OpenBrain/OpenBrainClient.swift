import Foundation

/// T8. `OpenBrainCapturing` implementation.
///
/// POSTs a capture payload to `{config.endpoint}/capture` as JSON with the
/// `x-brain-key` auth header, and maps the response to the frozen
/// `OpenBrainError` cases. The `URLSession` is injectable so tests can drive a
/// `URLProtocol` stub and exercise the transport / error mapping offline.
struct OpenBrainClient: OpenBrainCapturing {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func capture(_ payload: OpenBrainCapturePayload, config: OpenBrainConfig) async throws -> String {
        // Empty config → not configured. The brain key is the required secret;
        // without it the request cannot be authenticated.
        guard !config.brainKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenBrainError.notConfigured
        }

        let url = config.endpoint.appendingPathComponent("capture")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.brainKey, forHTTPHeaderField: "x-brain-key")

        // The synthesized Codable conformance uses `encodeIfPresent` for the
        // optional fields, so nil fields are omitted from the body automatically.
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw Self.mapURLError(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenBrainError.invalidResponse
        }
        let status = http.statusCode

        if (200...299).contains(status) {
            // 2xx must be JSON. Anything else (e.g. a proxy's HTML success page)
            // is treated as an invalid response rather than a silent success.
            guard let object = try? JSONSerialization.jsonObject(with: data) else {
                throw OpenBrainError.invalidResponse
            }
            guard let thoughtID = Self.extractThoughtID(from: object) else {
                throw OpenBrainError.invalidResponse
            }
            return thoughtID
        }

        // Non-2xx → surface status + a bounded body snippet. We deliberately do
        // NOT decode the body: an HTML WAF block page (Cloudflare, etc.) must
        // become `.http`, never crash a JSON decoder.
        let body = String(data: data, encoding: .utf8) ?? ""
        let message = String(body.prefix(200))
        throw OpenBrainError.http(status: status, message: message)
    }

    // MARK: - ID extraction

    /// Looks for the created thought id at `id`, then `thought.id`, then `data.id`.
    /// Accepts string or numeric ids. Returns nil if none is present.
    private static func extractThoughtID(from object: Any) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        if let id = stringID(dict["id"]) { return id }
        if let thought = dict["thought"] as? [String: Any], let id = stringID(thought["id"]) { return id }
        if let data = dict["data"] as? [String: Any], let id = stringID(data["id"]) { return id }
        return nil
    }

    private static func stringID(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    // MARK: - Error mapping

    /// Connectivity-family URL errors become `.offline` so the capture stays
    /// queued. Other transport failures are also treated as offline — the caller
    /// keeps the item for a later drain rather than dropping it.
    private static func mapURLError(_ error: URLError) -> OpenBrainError {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .timedOut,
             .dataNotAllowed,
             .internationalRoamingOff:
            return .offline
        default:
            return .offline
        }
    }
}
