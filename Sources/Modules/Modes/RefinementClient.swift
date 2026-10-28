import Foundation

/// The service that transforms a transcript after speech-to-text has finished.
/// This is deliberately independent of `TranscriptionProvider`: audio and text
/// can take different routes, and a local transcription must not imply local
/// refinement.
enum RefinementProviderID: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case groq
    case openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        }
    }

    var defaultTimeout: TimeInterval {
        switch self {
        case .groq: return 2.5
        case .openRouter: return 8
        }
    }
}

/// A portable user preference. Each provider adapter translates this into its
/// own wire format, and the editor limits the choices for known models.
enum ReasoningEffort: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case providerDefault
    case none
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providerDefault: return "Model default"
        case .none: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// The small, curated catalog Captur can explain without a network request.
/// Custom model ids remain supported; this catalog only supplies safe defaults
/// and capability-aware controls.
struct RefinementModelPreset: Identifiable, Equatable, Sendable {
    let provider: RefinementProviderID
    let id: String
    let title: String
    let supportedReasoning: [ReasoningEffort]
    /// Only used for clearly labelled estimates when a provider returns tokens
    /// but no billed amount. OpenRouter's response cost always wins.
    let inputUSDPerMillion: Decimal?
    let outputUSDPerMillion: Decimal?

    init(provider: RefinementProviderID,
         id: String,
         title: String,
         supportedReasoning: [ReasoningEffort],
         inputUSDPerMillion: Decimal? = nil,
         outputUSDPerMillion: Decimal? = nil) {
        self.provider = provider
        self.id = id
        self.title = title
        self.supportedReasoning = supportedReasoning
        self.inputUSDPerMillion = inputUSDPerMillion
        self.outputUSDPerMillion = outputUSDPerMillion
    }

    static let all: [RefinementModelPreset] = [
        .init(provider: .groq,
              id: "openai/gpt-oss-20b",
              title: "GPT-OSS 20B",
              supportedReasoning: [.providerDefault, .low, .medium, .high],
              inputUSDPerMillion: 0.075,
              outputUSDPerMillion: 0.30),
        .init(provider: .groq,
              id: "openai/gpt-oss-120b",
              title: "GPT-OSS 120B",
              supportedReasoning: [.providerDefault, .low, .medium, .high],
              inputUSDPerMillion: 0.15,
              outputUSDPerMillion: 0.60),
        .init(provider: .openRouter,
              id: "google/gemini-3.8-flash",
              title: "Gemini 3.8 Flash",
              supportedReasoning: [.providerDefault, .low, .medium, .high]),
        .init(provider: .openRouter,
              id: "openai/gpt-oss-20b",
              title: "GPT-OSS 20B",
              supportedReasoning: [.providerDefault, .low, .medium, .high]),
        .init(provider: .openRouter,
              id: "openai/gpt-oss-120b",
              title: "GPT-OSS 120B",
              supportedReasoning: [.providerDefault, .low, .medium, .high]),
        .init(provider: .openRouter,
              id: "z-ai/glm-5.3-flash",
              title: "GLM 5.3 Flash",
              supportedReasoning: [.providerDefault]),
    ]

    static func presets(for provider: RefinementProviderID) -> [Self] {
        all.filter { $0.provider == provider }
    }

    static func preset(provider: RefinementProviderID, modelID: String) -> Self? {
        all.first { $0.provider == provider && $0.id == modelID }
    }

    static func defaultPreset(for provider: RefinementProviderID) -> Self {
        presets(for: provider)[0]
    }

    static func estimatedCost(
        provider: RefinementProviderID,
        modelID: String,
        promptTokens: Int?,
        completionTokens: Int?
    ) -> Decimal? {
        guard let preset = preset(provider: provider, modelID: modelID),
              let inputRate = preset.inputUSDPerMillion,
              let outputRate = preset.outputUSDPerMillion,
              let promptTokens,
              let completionTokens else { return nil }
        let million = Decimal(1_000_000)
        return Decimal(promptTokens) * inputRate / million
            + Decimal(completionTokens) * outputRate / million
    }
}

enum RefinementCostKind: String, Codable, Sendable {
    /// Reported by the provider for this exact generation.
    case billed
    /// Calculated from a local price table.
    case estimated
    /// The request may have run, but no trustworthy amount was available.
    case unknown
    /// On-device work with no provider charge. Resource use is tracked separately.
    case noCharge
}

struct RefinementUsage: Equatable, Sendable {
    var promptTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
    var cachedTokens: Int?
    var costUSD: Decimal?
    var costKind: RefinementCostKind
}

struct RefinementResult: Equatable, Sendable {
    var text: String
    var provider: RefinementProviderID
    var requestedModelID: String
    var actualModelID: String?
    var generationID: String?
    var usage: RefinementUsage?
}

protocol RefinementCompleting: AnyObject, Sendable {
    func complete(
        systemMessage: String,
        userMessage: String,
        provider: RefinementProviderID,
        model: String,
        reasoning: ReasoningEffort,
        temperature: Double,
        apiKey: String,
        timeout: TimeInterval,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> RefinementResult
}

enum RefinementError: LocalizedError, Equatable {
    case missingAPIKey(RefinementProviderID)
    case timedOut(RefinementProviderID)
    case http(provider: RefinementProviderID, status: Int)
    case offline(RefinementProviderID)
    case decoding(RefinementProviderID)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Add your \(provider.title) API key in Settings and try again."
        case .timedOut:
            return "The model timed out. Try again."
        case .http(let provider, 401):
            return "\(provider.title) rejected the API key. Check it in Settings."
        case .http(let provider, let status):
            return "\(provider.title) couldn't complete the request (HTTP \(status))."
        case .offline:
            return "You appear to be offline. Reconnect and try again."
        case .decoding(let provider):
            return "Captur couldn't read \(provider.title)'s response. Try again."
        }
    }
}

/// One OpenAI-compatible streaming transport with provider-specific request
/// translation. Endpoints, credentials, timeouts and wire parameters remain
/// explicit; "custom model" never means "arbitrary URL".
final class ProviderRefinementClient: RefinementCompleting {
    private let session: URLSession
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let endpoints: [RefinementProviderID: URL]

    init(
        session: URLSession = .shared,
        endpoints: [RefinementProviderID: URL] = [
            .groq: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            .openRouter: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        ],
        sleeper: (@Sendable (TimeInterval) async -> Void)? = nil
    ) {
        self.session = session
        self.endpoints = endpoints
        self.sleeper = sleeper ?? { seconds in
            let clamped = min(max(seconds, 0), 60)
            try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
        }
    }

    func complete(
        systemMessage: String,
        userMessage: String,
        provider: RefinementProviderID,
        model: String,
        reasoning: ReasoningEffort,
        temperature: Double,
        apiKey: String,
        timeout: TimeInterval,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> RefinementResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw RefinementError.missingAPIKey(provider) }
        guard let endpoint = endpoints[provider] else { throw RefinementError.decoding(provider) }

        let gate = DeltaGate(onDelta: onDelta)
        defer { gate.close() }
        let request = try makeRequest(
            endpoint: endpoint,
            provider: provider,
            systemMessage: systemMessage,
            userMessage: userMessage,
            model: model,
            reasoning: reasoning,
            temperature: temperature,
            apiKey: trimmedKey,
            timeout: timeout)

        return try await withThrowingTaskGroup(of: RefinementResult?.self) { group in
            group.addTask { [session] in
                try await Self.stream(
                    request: request,
                    session: session,
                    provider: provider,
                    requestedModel: model,
                    gate: gate)
            }
            group.addTask { [sleeper] in
                await sleeper(timeout)
                return nil
            }

            while let outcome = try await group.next() {
                guard let result = outcome else {
                    try Task.checkCancellation()
                    gate.close()
                    group.cancelAll()
                    throw RefinementError.timedOut(provider)
                }
                group.cancelAll()
                return result
            }
            throw RefinementError.decoding(provider)
        }
    }

    private static func stream(
        request: URLRequest,
        session: URLSession,
        provider: RefinementProviderID,
        requestedModel: String,
        gate: DeltaGate
    ) async throws -> RefinementResult {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw map(error, provider: provider)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RefinementError.decoding(provider)
        }
        guard (200...299).contains(http.statusCode) else {
            throw RefinementError.http(provider: provider, status: http.statusCode)
        }

        let decoder = JSONDecoder()
        var text = ""
        var actualModel: String?
        var generationID: String?
        var usage: RefinementUsage?

        do {
            frames: for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                guard !line.isEmpty, !line.hasPrefix(":"), line.hasPrefix("data:") else {
                    continue
                }
                let payload = line.dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty else { continue }
                if payload == "[DONE]" { break frames }
                guard let chunk = try? decoder.decode(
                    ProviderChatStreamChunk.self, from: Data(payload.utf8)
                ) else { continue }

                if let id = chunk.id { generationID = id }
                if let model = chunk.model { actualModel = model }
                if let wireUsage = chunk.usage {
                    let estimatedCost = RefinementModelPreset.estimatedCost(
                        provider: provider,
                        modelID: actualModel ?? requestedModel,
                        promptTokens: wireUsage.promptTokens,
                        completionTokens: wireUsage.completionTokens)
                    let cost = wireUsage.cost ?? estimatedCost
                    usage = RefinementUsage(
                        promptTokens: wireUsage.promptTokens,
                        completionTokens: wireUsage.completionTokens,
                        reasoningTokens: wireUsage.completionTokenDetails?.reasoningTokens,
                        cachedTokens: wireUsage.promptTokenDetails?.cachedTokens,
                        costUSD: cost,
                        costKind: wireUsage.cost != nil
                            ? .billed : (estimatedCost != nil ? .estimated : .unknown))
                }
                if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                    text += delta
                    gate.emit(delta)
                }
            }
        } catch {
            throw map(error, provider: provider)
        }

        guard !text.isEmpty else { throw RefinementError.decoding(provider) }
        return RefinementResult(
            text: text,
            provider: provider,
            requestedModelID: requestedModel,
            actualModelID: actualModel,
            generationID: generationID,
            usage: usage)
    }

    private func makeRequest(
        endpoint: URL,
        provider: RefinementProviderID,
        systemMessage: String,
        userMessage: String,
        model: String,
        reasoning: ReasoningEffort,
        temperature: Double,
        apiKey: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if provider == .openRouter {
            request.setValue("Captur", forHTTPHeaderField: "X-Title")
        }
        request.timeoutInterval = min(max(timeout, 0.5), 60)

        let effort = reasoning == .providerDefault ? nil : reasoning.rawValue
        let body = ProviderChatRequest(
            model: model,
            temperature: temperature,
            stream: true,
            messages: [
                .init(role: "system", content: systemMessage),
                .init(role: "user", content: userMessage),
            ],
            reasoningEffort: provider == .groq ? effort : nil,
            reasoning: provider == .openRouter && effort != nil
                ? .init(effort: effort!) : nil)
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw RefinementError.decoding(provider)
        }
        return request
    }

    private static func map(_ error: Error, provider: RefinementProviderID) -> Error {
        if error is CancellationError { return error }
        if let refinement = error as? RefinementError { return refinement }
        guard let urlError = error as? URLError else {
            return RefinementError.decoding(provider)
        }
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .timedOut: return RefinementError.timedOut(provider)
        default: return RefinementError.offline(provider)
        }
    }
}

private struct ProviderChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct Reasoning: Encodable { let effort: String }

    let model: String
    let temperature: Double
    let stream: Bool
    let messages: [Message]
    let reasoningEffort: String?
    let reasoning: Reasoning?

    enum CodingKeys: String, CodingKey {
        case model, temperature, stream, messages, reasoning
        case reasoningEffort = "reasoning_effort"
    }
}

private struct ProviderChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
    }
    struct Usage: Decodable {
        struct CompletionDetails: Decodable {
            let reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }
        struct PromptDetails: Decodable {
            let cachedTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
        }
        let promptTokens: Int?
        let completionTokens: Int?
        let completionTokenDetails: CompletionDetails?
        let promptTokenDetails: PromptDetails?
        let cost: Decimal?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case completionTokenDetails = "completion_tokens_details"
            case promptTokenDetails = "prompt_tokens_details"
            case cost
        }
    }

    let id: String?
    let model: String?
    let choices: [Choice]?
    let usage: Usage?
}
