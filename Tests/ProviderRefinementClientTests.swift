import XCTest
@testable import Captur

final class ProviderRefinementClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SSEStubURLProtocol.reset()
    }

    override func tearDown() {
        SSEStubURLProtocol.release()
        SSEStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> ProviderRefinementClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SSEStubURLProtocol.self]
        return ProviderRefinementClient(
            session: URLSession(configuration: configuration),
            endpoints: [
                .groq: URL(string: "https://groq.test/chat")!,
                .openRouter: URL(string: "https://openrouter.test/chat")!,
            ],
            sleeper: { _ in
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            })
    }

    func testOpenRouterUsesNestedReasoningAndReturnsBilledUsage() async throws {
        SSEStubURLProtocol.reset { _ in
            .sse(
                sseFrame("Hello")
                + #"data: {"id":"gen-1","model":"google/gemini-3.8-flash","choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"completion_tokens_details":{"reasoning_tokens":7},"prompt_tokens_details":{"cached_tokens":11},"cost":0.00125}}"#
                + "\n\ndata: [DONE]\n\n")
        }

        let result = try await makeClient().complete(
            systemMessage: "Edit only.",
            userMessage: "hello",
            provider: .openRouter,
            model: "google/gemini-3.8-flash",
            reasoning: .low,
            temperature: 0,
            apiKey: "sk-or-test",
            timeout: 30,
            onDelta: { _ in })

        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(result.provider, .openRouter)
        XCTAssertEqual(result.actualModelID, "google/gemini-3.8-flash")
        XCTAssertEqual(result.generationID, "gen-1")
        XCTAssertEqual(result.usage?.promptTokens, 100)
        XCTAssertEqual(result.usage?.completionTokens, 20)
        XCTAssertEqual(result.usage?.reasoningTokens, 7)
        XCTAssertEqual(result.usage?.cachedTokens, 11)
        XCTAssertEqual(result.usage?.costUSD, Decimal(string: "0.00125"))
        XCTAssertEqual(result.usage?.costKind, .billed)

        let request = try XCTUnwrap(SSEStubURLProtocol.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://openrouter.test/chat")
        XCTAssertEqual(request.authorization, "Bearer sk-or-test")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["model"] as? String, "google/gemini-3.8-flash")
    }

    func testGroqUsesReasoningEffortAndEstimatesKnownModelCost() async throws {
        SSEStubURLProtocol.reset { _ in
            .sse(
                sseFrame("Hi")
                + #"data: {"id":"groq-1","model":"openai/gpt-oss-20b","choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20}}"#
                + "\n\ndata: [DONE]\n\n")
        }

        let result = try await makeClient().complete(
            systemMessage: "Edit only.",
            userMessage: "hi",
            provider: .groq,
            model: "openai/gpt-oss-20b",
            reasoning: .high,
            temperature: 0,
            apiKey: "gsk-test",
            timeout: 30,
            onDelta: { _ in })

        XCTAssertEqual(result.usage?.costKind, .estimated)
        XCTAssertEqual(result.usage?.costUSD, Decimal(string: "0.0000135"))
        let request = try XCTUnwrap(SSEStubURLProtocol.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://groq.test/chat")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        XCTAssertNil(body["reasoning"])
    }

    func testProviderDefaultOmitsProviderSpecificReasoningFields() async throws {
        SSEStubURLProtocol.reset { _ in .sse(sseFrame("Hi") + "data: [DONE]\n\n") }

        _ = try await makeClient().complete(
            systemMessage: "Edit.", userMessage: "hi", provider: .openRouter,
            model: "custom/model", reasoning: .providerDefault, temperature: 0,
            apiKey: "key", timeout: 30, onDelta: { _ in })

        let request = try XCTUnwrap(SSEStubURLProtocol.requests.first)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
        XCTAssertNil(body["reasoning"])
        XCTAssertNil(body["reasoning_effort"])
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        do {
            _ = try await makeClient().complete(
                systemMessage: "Edit.", userMessage: "hi", provider: .openRouter,
                model: "custom/model", reasoning: .low, temperature: 0,
                apiKey: "  ", timeout: 30, onDelta: { _ in })
            XCTFail("expected missing key")
        } catch {
            XCTAssertEqual(error as? RefinementError, .missingAPIKey(.openRouter))
        }
        XCTAssertTrue(SSEStubURLProtocol.requests.isEmpty)
    }
}
