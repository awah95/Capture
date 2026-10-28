import XCTest
@testable import Captur

final class SmokeTests: XCTestCase {
    func testLegacyV1CaptureDecodesWithMacDefaults() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "createdAt": 0,
          "status": "success",
          "text": "Legacy capture"
        }
        """

        let capture = try JSONDecoder().decode(Capture.self, from: Data(json.utf8))

        XCTAssertEqual(capture.mode, .dictation)
        XCTAssertEqual(capture.source, .macApp)
        XCTAssertEqual(capture.tags, [])
        XCTAssertNil(capture.obSyncState)
    }

    func testCaptureRoundTripsOpenBrainStateAndHotkeySource() throws {
        let original = Capture(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSinceReferenceDate: 123),
            source: .hotkey,
            status: .pending,
            text: "Queue this",
            obSyncState: .queued
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Capture.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.obSyncState, .queued)
        XCTAssertEqual(decoded.source, .hotkey)
    }

    func testDefaultHotkeyBindingsRoundTrip() throws {
        let data = try JSONEncoder().encode(HotkeyBindings.default)
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: data)

        XCTAssertEqual(decoded, .default)
    }

    func testDefaultMicPolicyExcludesContinuityInputs() {
        XCTAssertTrue(MicSelectionPolicy.default.excludeContinuityInputs)
    }
}

