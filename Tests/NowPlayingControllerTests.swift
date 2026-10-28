import XCTest
@testable import Captur

private final class FakeMediaHelper: MediaHelperRunning {
    var results: [MediaHelperResult?] = []
    var calls: [(String, Data?)] = []
    func run(command: String, identity: Data?, permit: MediaCommandPermit?) async -> MediaHelperResult? {
        calls.append((command, identity))
        return results.isEmpty ? nil : results.removeFirst()
    }
}

@MainActor
final class NowPlayingControllerTests: XCTestCase {
    private var helper: FakeMediaHelper!
    private var sut: SystemNowPlayingController!

    override func setUp() {
        super.setUp()
        helper = FakeMediaHelper()
        sut = SystemNowPlayingController(helper: helper)
    }

    private func result(playing: Bool, media: String = "video-1", pid: Int = 300,
                        numericID: Int = 42) -> MediaHelperResult {
        let object: [String: Any] = ["bundleIdentifier": "com.google.Chrome",
            "processIdentifier": pid, "title": "Video", "playing": playing,
            "contentItemIdentifier": media, "uniqueIdentifier": numericID]
        return MediaHelperResult(status: 0, output: try! JSONSerialization.data(withJSONObject: object))
    }

    private func snapshot() async throws -> NowPlayingSnapshot {
        helper.results = [result(playing: true)]
        guard case .playback(let snapshot) = await sut.read() else {
            throw NSError(domain: "test", code: 1)
        }
        return snapshot
    }

    func testRealisticNumericIdentifierDecodesAndPreservesTypeForGuard() async throws {
        let before = try await snapshot()
        helper.results = [result(playing: false)]
        let paused = await sut.pause(before)
        XCTAssertTrue(paused)
        XCTAssertEqual(helper.calls.map(\.0), ["get", "pause"])
        let identity = try XCTUnwrap(helper.calls.last?.1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: identity) as? [String: Any])
        XCTAssertEqual(object["uniqueIdentifier"] as? Int, 42)
        XCTAssertEqual(object["contentItemIdentifier"] as? String, "video-1")
        XCTAssertNil(object["playing"], "The helper checks state separately from media identity")
    }

    func testScreenRecorderSnapshotNeverSubmitsPlaybackCommands() async throws {
        let data = Data(#"{"bundleIdentifier":"com.apple.QuickTimePlayerX","processIdentifier":301,"title":"Screen recording","playing":true}"#.utf8)
        helper.results = [MediaHelperResult(status: 0, output: data)]
        guard case .playback(let snapshot) = await sut.read() else { return XCTFail("Missing snapshot") }
        let changed = await sut.pause(snapshot)
        XCTAssertFalse(changed)
        XCTAssertEqual(helper.calls.map(\.0), ["get"])
    }

    func testCaptureGuardRejectionNeverClaimsPauseOwnership() async throws {
        let before = try await snapshot()
        // Native helper refuses a player with active input capture.
        helper.results = [MediaHelperResult(status: 1, output: Data())]
        let paused = await sut.pause(before)
        XCTAssertFalse(paused)
        XCTAssertEqual(helper.calls.map(\.0), ["get", "pause"])
    }

    func testStringIdentifierDecodes() async throws {
        let data = Data(#"{"bundleIdentifier":"com.apple.Safari","processIdentifier":301,"title":"Video","playing":true,"uniqueIdentifier":"item-1"}"#.utf8)
        helper.results = [MediaHelperResult(status: 0, output: data)]
        guard case .playback(let snapshot) = await sut.read() else { return XCTFail("Missing snapshot") }
        XCTAssertEqual(snapshot.identity.uniqueIdentifier, .string("item-1"))
    }

    func testNullMetadataIsEmptyAndCannotStartPlayback() async {
        helper.results = [MediaHelperResult(status: 0, output: Data("null\n".utf8))]
        let state = await sut.read()
        XCTAssertEqual(state, .empty)
        XCTAssertEqual(helper.calls.map(\.0), ["get"])
    }

    func testMalformedMetadataIsEmpty() async {
        helper.results = [MediaHelperResult(status: 0, output: Data("not JSON".utf8))]
        let state = await sut.read()
        XCTAssertEqual(state, .empty)
    }

    func testIncompleteIdentityIsEmpty() async {
        helper.results = [result(playing: true, pid: 0)]
        let state = await sut.read()
        XCTAssertEqual(state, .empty)
    }

    func testMissingPlaybackStateIsEmpty() async {
        let data = Data(#"{"bundleIdentifier":"com.apple.Safari","processIdentifier":301,"title":"Video"}"#.utf8)
        helper.results = [MediaHelperResult(status: 0, output: data)]
        let state = await sut.read()
        XCTAssertEqual(state, .empty)
    }

    func testFailedOrTimedOutHelperIsUnavailable() async {
        helper.results = [nil, MediaHelperResult(status: 1, output: Data())]
        let timedOut = await sut.read()
        let failed = await sut.read()
        XCTAssertEqual(timedOut, .unavailable)
        XCTAssertEqual(failed, .unavailable)
    }

    func testChangedSessionDuringPauseIsNotOwned() async throws {
        let before = try await snapshot()
        helper.results = [result(playing: false, media: "other-video")]
        let paused = await sut.pause(before)
        XCTAssertFalse(paused)
    }

    func testUnconfirmedPauseIsNotOwned() async throws {
        let before = try await snapshot()
        helper.results = [result(playing: true)]
        let paused = await sut.pause(before)
        XCTAssertFalse(paused)
    }

    func testGuardRejectionDoesNotRetryCommand() async throws {
        let before = try await snapshot()
        helper.results = [MediaHelperResult(status: 1, output: Data())]
        let paused = await sut.pause(before)
        XCTAssertFalse(paused)
        XCTAssertEqual(helper.calls.map(\.0), ["get", "pause"])
    }

    func testTimeoutAfterSubmissionDoesNotRetryCommand() async throws {
        let before = try await snapshot()
        helper.results = [nil]
        let paused = await sut.pause(before)
        XCTAssertFalse(paused)
        XCTAssertEqual(helper.calls.map(\.0), ["get", "pause"])
    }

    func testExplicitPlayRequiresPreviouslyPausedSnapshot() async throws {
        let before = try await snapshot()
        let played = await sut.play(before)
        XCTAssertFalse(played)
        XCTAssertEqual(helper.calls.map(\.0), ["get"])
    }

    func testExplicitPauseLeavesPausedSnapshotAlone() async throws {
        let before = try await snapshot()
        let paused = NowPlayingSnapshot(identity: before.identity, playing: false)
        let changed = await sut.pause(paused)
        XCTAssertFalse(changed)
        XCTAssertEqual(helper.calls.map(\.0), ["get"])
    }

    func testPlayConfirmsSameSessionAndUsesExplicitCommand() async throws {
        let before = try await snapshot()
        let paused = NowPlayingSnapshot(identity: before.identity, playing: false)
        helper.results = [result(playing: true)]
        let played = await sut.play(paused)
        XCTAssertTrue(played)
        XCTAssertEqual(helper.calls.map(\.0), ["get", "play"])
    }

    func testRevokedPermitNeverStartsHelper() async throws {
        let before = try await snapshot()
        let permit = MediaCommandPermit()
        permit.invalidate()
        let changed = await sut.pause(before, permit: permit)
        XCTAssertFalse(changed)
        XCTAssertEqual(helper.calls.map(\.0), ["get"])
    }

    func testProcessChangingDuringPlayFailsConfirmation() async throws {
        let before = try await snapshot()
        let paused = NowPlayingSnapshot(identity: before.identity, playing: false)
        helper.results = [result(playing: true, pid: 301)]
        let played = await sut.play(paused)
        XCTAssertFalse(played)
    }
}
