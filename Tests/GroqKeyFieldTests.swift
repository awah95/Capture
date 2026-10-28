import XCTest
@testable import Captur

// MARK: - Stub transport
//
// Its own protocol class rather than the one in GroqTranscriberTests: that stub holds a
// process-wide static box, and sharing it would couple two unrelated test classes. No
// test here may reach the network — the endpoint under test is a live, billable API.

final class KeyStubURLProtocol: URLProtocol {

    struct Recorded {
        let url: URL
        let method: String
        let authorization: String?
    }

    enum Outcome {
        case respond(status: Int, body: Data)
        case failure(URLError)
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var requests: [Recorded] = []
        var handler: (@Sendable (Recorded) -> Outcome)?
    }

    nonisolated(unsafe) private static let box = Box()

    static func reset(handler: (@Sendable (Recorded) -> Outcome)? = nil) {
        box.lock.lock()
        box.requests = []
        box.handler = handler
        box.lock.unlock()
    }

    static var requests: [Recorded] {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.requests
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let recorded = Recorded(url: url,
                                method: request.httpMethod ?? "",
                                authorization: request.value(forHTTPHeaderField: "Authorization"))

        Self.box.lock.lock()
        Self.box.requests.append(recorded)
        let handler = Self.box.handler
        Self.box.lock.unlock()

        switch handler?(recorded) ?? .respond(status: 200, body: Data(#"{"data":[]}"#.utf8)) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .respond(let status, let body):
            guard let response = HTTPURLResponse(url: url,
                                                 statusCode: status,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: [:]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@MainActor
final class RecordingGroqKeyStore: GroqKeyStoring {
    var stored: String?
    private(set) var writes: [String?] = []

    init(stored: String? = nil) { self.stored = stored }

    func groqKey() -> String? { stored }

    func setGroqKey(_ key: String?) {
        writes.append(key)
        stored = key
    }
}

// MARK: - Tests

@MainActor
final class GroqKeyFieldTests: XCTestCase {

    /// A fake key with an obvious shape. It is never sent anywhere real.
    private let fakeKey = "gsk_TESTONLY_0123456789abcdef"
    private var store: RecordingGroqKeyStore!

    override func setUp() {
        super.setUp()
        store = RecordingGroqKeyStore()
        KeyStubURLProtocol.reset()
    }

    override func tearDown() {
        KeyStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeModel() -> GroqKeyFieldModel {
        GroqKeyFieldModel(store: store, session: KeyStubURLProtocol.session())
    }

    // MARK: saving

    func testSaveWritesTheKeyToTheInjectedStore() {
        let model = makeModel()
        model.draft = fakeKey

        model.save()

        XCTAssertEqual(store.writes, [fakeKey])
        XCTAssertEqual(store.stored, fakeKey)
        XCTAssertTrue(model.hasStoredKey)
    }

    /// The single most common real-world failure: a clipboard paste carries a trailing
    /// newline, the Bearer header becomes `Bearer gsk_…\n`, and every request 401s.
    func testAWhitespacePaddedPasteIsTrimmedBeforeItIsStored() {
        let model = makeModel()
        model.draft = "  \t\(fakeKey)\n"

        model.save()

        XCTAssertEqual(store.writes, [fakeKey])
        XCTAssertEqual(store.stored, fakeKey)
    }

    func testAnEmptyFieldClearsTheStoredKeyRatherThanSavingAnEmptyString() {
        store.stored = fakeKey
        let model = makeModel()
        model.draft = ""

        model.save()

        XCTAssertEqual(store.writes, [nil], "An empty field must delete the item, not store \"\".")
        XCTAssertNil(store.stored)
        XCTAssertFalse(model.hasStoredKey)
    }

    func testAWhitespaceOnlyFieldAlsoClearsTheStoredKey() {
        store.stored = fakeKey
        let model = makeModel()
        model.draft = "   \n\t "

        model.save()

        XCTAssertEqual(store.writes, [nil])
        XCTAssertNil(store.stored)
    }

    func testSavingResetsValidationBecauseTheOldVerdictNoLongerApplies() async {
        KeyStubURLProtocol.reset { _ in .respond(status: 200, body: Data(#"{"data":[]}"#.utf8)) }
        let model = makeModel()
        model.draft = fakeKey
        model.save()
        await model.validate()
        XCTAssertEqual(model.validation, .valid)

        model.draft = "gsk_TESTONLY_different"
        model.save()

        XCTAssertEqual(model.validation, .untested)
    }

    // MARK: never echoed, never leaked

    func testTheStoredKeyIsNeverEchoedBackIntoTheField() {
        store.stored = fakeKey
        let model = makeModel()

        XCTAssertEqual(model.draft, "", "A stored key must never be re-populated into a visible field.")
        XCTAssertTrue(model.hasStoredKey, "…but the user must still be told a key is saved.")
    }

    func testSavingClearsTheDraftSoTheKeyIsNotLeftOnScreen() {
        let model = makeModel()
        model.draft = fakeKey

        model.save()

        XCTAssertEqual(model.draft, "")
    }

    func testTheKeyNeverReachesUserDefaults() async {
        KeyStubURLProtocol.reset { _ in .respond(status: 200, body: Data(#"{"data":[]}"#.utf8)) }
        let model = makeModel()
        model.draft = fakeKey
        model.save()
        await model.validate()

        let defaults = UserDefaults.standard.dictionaryRepresentation()
        for (name, value) in defaults {
            if let text = value as? String {
                XCTAssertFalse(text.contains(fakeKey), "Key leaked into UserDefaults key \(name).")
            }
        }
    }

    /// Nothing user-visible may quote the key back, including the failure text.
    func testAFailureMessageNeverContainsTheKey() async {
        KeyStubURLProtocol.reset { _ in .respond(status: 401, body: Data(#"{"error":{"message":"x"}}"#.utf8)) }
        let model = makeModel()
        model.draft = fakeKey
        model.save()
        await model.validate()

        guard case .failed(let message) = model.validation else {
            return XCTFail("Expected a failure, got \(model.validation).")
        }
        XCTAssertFalse(message.contains(fakeKey))
    }

    // MARK: validation

    func testValidationStartsUntested() {
        XCTAssertEqual(makeModel().validation, .untested)
    }

    func testValidateMapsTwoHundredToValid() async {
        KeyStubURLProtocol.reset { _ in .respond(status: 200, body: Data(#"{"data":[]}"#.utf8)) }
        let model = makeModel()
        model.draft = fakeKey

        await model.validate()

        XCTAssertEqual(model.validation, .valid)
    }

    func testValidateCallsTheModelsEndpointWithABearerHeader() async {
        KeyStubURLProtocol.reset { _ in .respond(status: 200, body: Data(#"{"data":[]}"#.utf8)) }
        let model = makeModel()
        model.draft = fakeKey

        await model.validate()

        XCTAssertEqual(KeyStubURLProtocol.requests.count, 1)
        XCTAssertEqual(KeyStubURLProtocol.requests.first?.url.absoluteString,
                       "https://api.groq.com/openai/v1/models")
        XCTAssertEqual(KeyStubURLProtocol.requests.first?.method, "GET")
        XCTAssertEqual(KeyStubURLProtocol.requests.first?.authorization, "Bearer \(fakeKey)")
    }

    func testValidateSendsTheTrimmedKeyEvenWhenThePasteHasATrailingNewline() async {
        KeyStubURLProtocol.reset { _ in .respond(status: 200, body: Data(#"{"data":[]}"#.utf8)) }
        let model = makeModel()
        model.draft = " \(fakeKey)\n"

        await model.validate()

        XCTAssertEqual(KeyStubURLProtocol.requests.first?.authorization, "Bearer \(fakeKey)")
    }

    func testValidateMapsFourOhOneToAnInvalidKeyMessage() async {
        KeyStubURLProtocol.reset { _ in .respond(status: 401, body: Data(#"{"error":{"message":"x"}}"#.utf8)) }
        let model = makeModel()
        model.draft = fakeKey

        await model.validate()

        guard case .failed(let message) = model.validation else {
            return XCTFail("Expected a failure, got \(model.validation).")
        }
        XCTAssertTrue(message.lowercased().contains("key"), "401 must name the key as the problem: \(message)")
        XCTAssertTrue(message.contains("401"))
    }

    func testValidateReportsTheHTTPStatusForOtherFailures() async {
        KeyStubURLProtocol.reset { _ in .respond(status: 503, body: Data()) }
        let model = makeModel()
        model.draft = fakeKey

        await model.validate()

        guard case .failed(let message) = model.validation else {
            return XCTFail("Expected a failure, got \(model.validation).")
        }
        XCTAssertTrue(message.contains("503"), "The HTTP failure reason must be reported: \(message)")
    }

    func testValidateReportsATransportFailure() async {
        KeyStubURLProtocol.reset { _ in .failure(URLError(.notConnectedToInternet)) }
        let model = makeModel()
        model.draft = fakeKey

        await model.validate()

        guard case .failed = model.validation else {
            return XCTFail("Expected a failure, got \(model.validation).")
        }
    }

    func testValidateFallsBackToTheStoredKeyWhenTheFieldIsEmpty() async {
        KeyStubURLProtocol.reset { _ in .respond(status: 200, body: Data(#"{"data":[]}"#.utf8)) }
        store.stored = fakeKey
        let model = makeModel()
        XCTAssertEqual(model.draft, "")

        await model.validate()

        XCTAssertEqual(KeyStubURLProtocol.requests.first?.authorization, "Bearer \(fakeKey)")
        XCTAssertEqual(model.validation, .valid)
    }

    func testValidateWithNoKeyAnywhereFailsWithoutMakingARequest() async {
        let model = makeModel()

        await model.validate()

        XCTAssertTrue(KeyStubURLProtocol.requests.isEmpty, "Never spend a request on an empty key.")
        guard case .failed = model.validation else {
            return XCTFail("Expected a failure, got \(model.validation).")
        }
    }

    func testClearingRemovesTheItemAndResetsValidation() async {
        KeyStubURLProtocol.reset { _ in .respond(status: 200, body: Data(#"{"data":[]}"#.utf8)) }
        store.stored = fakeKey
        let model = makeModel()
        await model.validate()
        XCTAssertEqual(model.validation, .valid)

        model.clear()

        XCTAssertEqual(store.writes, [nil])
        XCTAssertNil(store.stored)
        XCTAssertFalse(model.hasStoredKey)
        XCTAssertEqual(model.validation, .untested)
    }
}
