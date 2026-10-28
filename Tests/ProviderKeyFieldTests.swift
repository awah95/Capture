import XCTest
@testable import Captur

@MainActor
final class ProviderKeyFieldTests: XCTestCase {
    func testOpenRouterKeyIsTrimmedStoredAndNeverReadBackIntoTheField() {
        var stored: String?
        var writes: [String?] = []
        let model = ProviderKeyFieldModel(
            provider: .openRouter,
            read: { stored },
            write: { value in stored = value; writes.append(value) },
            session: KeyStubURLProtocol.session())

        model.draft = "  sk-or-secret  "
        model.save()

        XCTAssertEqual(stored, "sk-or-secret")
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.hasStoredKey)
    }

    func testOpenRouterValidationUsesTheAuthenticatedKeyEndpointAndBearerKey() async {
        KeyStubURLProtocol.reset { _ in
            .respond(status: 200, body: Data(#"{"data":{"label":"test"}}"#.utf8))
        }
        let model = ProviderKeyFieldModel(
            provider: .openRouter,
            read: { "sk-or-stored" },
            write: { _ in },
            session: KeyStubURLProtocol.session())

        await model.validate()

        XCTAssertEqual(model.validation, .valid)
        let request = KeyStubURLProtocol.requests.first
        XCTAssertEqual(request?.url.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(request?.authorization, "Bearer sk-or-stored")
    }
}
