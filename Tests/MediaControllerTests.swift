import XCTest
@testable import Captur

@MainActor
private final class FakeMediaPlayers: MediaPlayerControlling {
    let music = MediaPlayer(bundleIdentifier: "com.apple.Music", processIdentifier: 100)
    let spotify = MediaPlayer(bundleIdentifier: "com.spotify.client", processIdentifier: 101)
    var running: [MediaPlayer] = []
    var states: [MediaPlayer: MediaPlayback] = [:]
    var pauseSucceeds = true
    var pauseChangesState = true
    var pausedTrackOverride: String?
    var calls: [String] = []
    var onPlayback: (() -> Void)?

    func runningPlayers() -> [MediaPlayer] { running }
    func playback(of player: MediaPlayer) -> MediaPlayback? {
        onPlayback?()
        return states[player]
    }
    func pause(_ player: MediaPlayer, permit: MediaCommandPermit) -> Bool {
        calls.append("pause \(player.bundleIdentifier)")
        guard pauseSucceeds else { return false }
        if pauseChangesState, let before = states[player] {
            states[player] = MediaPlayback(state: .paused, trackID: pausedTrackOverride ?? before.trackID)
        }
        return true
    }
    func play(_ player: MediaPlayer, permit: MediaCommandPermit) -> Bool {
        calls.append("play \(player.bundleIdentifier)")
        if let before = states[player] {
            states[player] = MediaPlayback(state: .playing, trackID: before.trackID)
        }
        return true
    }
    func set(_ state: MediaPlayback.State, track: String = "track-1", player: MediaPlayer? = nil) {
        states[player ?? music] = MediaPlayback(state: state, trackID: track)
    }
}

@MainActor
final class MediaControllerTests: XCTestCase {
    private var players: FakeMediaPlayers!
    private var enabled = true
    private let pauseMusic = "pause com.apple.Music"
    private let playMusic = "play com.apple.Music"

    override func setUp() {
        super.setUp()
        players = FakeMediaPlayers()
        enabled = true
        players.running = [players.music]
        players.set(.playing)
    }

    private func controller() -> MediaController {
        MediaController(players: players, isEnabled: { [weak self] in self?.enabled ?? false })
    }

    func testClosedPlayersReceiveNoCommands() async {
        players.running = []
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [])
    }

    func testPausedPlaybackIsNeverStarted() async {
        players.set(.paused)
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [])
        XCTAssertEqual(players.states[players.music]?.state, .paused)
    }

    func testStoppedPlaybackIsNeverStarted() async {
        players.set(.stopped)
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [])
        XCTAssertEqual(players.states[players.music]?.state, .stopped)
    }

    func testUnknownStateOrDeniedPermissionDoesNothing() async {
        players.states = [:]
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [])
    }

    func testPlayingTrackIsExplicitlyPausedThenPlayed() async {
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic])
        XCTAssertEqual(players.states[players.music]?.state, .paused)
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic, playMusic])
        XCTAssertEqual(players.states[players.music]?.state, .playing)
    }

    func testFailedPauseNeverSchedulesPlay() async {
        players.pauseSucceeds = false
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic])
    }

    func testUnconfirmedPauseNeverSchedulesPlay() async {
        players.pauseChangesState = false
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic])
    }

    func testTrackChangingDuringPauseNeverSchedulesPlay() async {
        players.pausedTrackOverride = "other-track"
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic])
    }

    func testDisabledSettingDoesNothing() async {
        enabled = false
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [])
    }

    func testDisablingMidCaptureStillResumesPausedTrack() async {
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        enabled = false
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic, playMusic])
    }

    func testOverlappingCapturesResumeOnlyWhenLastCaptureEnds() async {
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic])
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic, playMusic])
    }

    func testCancelResumesOnceAndExtraEndsDoNothing() async {
        let sut = controller()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidCancel()
        await sut.waitForPendingOperations()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic, playMusic])
    }

    func testRepeatedPhasesAndSubsequentDictationRemainBalanced() async {
        let sut = controller()
        sut.update(holdsMicrophone: false)
        await sut.waitForPendingOperations()
        sut.update(holdsMicrophone: true)
        await sut.waitForPendingOperations()
        sut.update(holdsMicrophone: true)
        await sut.waitForPendingOperations()
        sut.update(holdsMicrophone: false)
        await sut.waitForPendingOperations()
        sut.update(holdsMicrophone: false)
        await sut.waitForPendingOperations()
        sut.update(holdsMicrophone: true)
        await sut.waitForPendingOperations()
        sut.update(holdsMicrophone: false)
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic, playMusic, pauseMusic, playMusic])
    }

    func testClosedOrRestartedPlayerIsNotResumed() async {
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        players.running = [MediaPlayer(bundleIdentifier: "com.apple.Music", processIdentifier: 200)]
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic])
    }

    func testChangedTrackIsNotResumed() async {
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        players.set(.paused, track: "other-track")
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic])
    }

    func testUserStartedPlaybackIsNotInterruptedAtEnd() async {
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        players.set(.playing)
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic])
    }

    func testUserStoppedPlaybackIsNotResumed() async {
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        players.set(.stopped)
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic])
    }

    func testLostPermissionAtEndDoesNotPlay() async {
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        players.states = [:]
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, [pauseMusic])
    }

    func testOnlyPlayingPlayerIsPausedAndResumed() async {
        players.running = [players.music, players.spotify]
        players.set(.paused, player: players.music)
        players.set(.playing, player: players.spotify)
        let sut = controller()
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
        XCTAssertEqual(players.calls, ["pause com.spotify.client", "play com.spotify.client"])
    }
}

@MainActor
private final class FakeNowPlaying: NowPlayingControlling {
    var state: NowPlayingRead = .empty
    var commands: [String] = []
    var pauseSucceeds = true
    var playSucceeds = true
    var onRead: (() -> Void)?
    var onPause: (() -> Void)?
    var heldCommand: String?
    var waitingCommand: String?
    var commandContinuation: CheckedContinuation<Void, Never>?

    private func waitBeforeDispatch(_ command: String) async {
        guard heldCommand == command else { return }
        waitingCommand = command
        await withCheckedContinuation { commandContinuation = $0 }
        waitingCommand = nil
    }
    func releaseCommand() {
        heldCommand = nil
        commandContinuation?.resume()
        commandContinuation = nil
    }

    func read() async -> NowPlayingRead {
        let result = state
        onRead?()
        return result
    }
    func pause(_ snapshot: NowPlayingSnapshot, permit: MediaCommandPermit) async -> Bool {
        await waitBeforeDispatch("pause")
        guard permit.isValid else { return false }
        commands.append("pause")
        onPause?()
        guard pauseSucceeds else { return false }
        state = .playback(NowPlayingSnapshot(identity: snapshot.identity, playing: false))
        return true
    }
    func play(_ snapshot: NowPlayingSnapshot, permit: MediaCommandPermit) async -> Bool {
        await waitBeforeDispatch("play")
        guard permit.isValid else { return false }
        commands.append("play")
        guard playSucceeds else { return false }
        state = .playback(NowPlayingSnapshot(identity: snapshot.identity, playing: true))
        return true
    }
}

@MainActor
final class NowPlayingMediaControllerTests: XCTestCase {
    private var remote: FakeNowPlaying!
    private var fallback: FakeMediaPlayers!
    private var sut: MediaController!
    private var enabled = true

    private func snapshot(playing: Bool, bundle: String = "com.google.Chrome",
                          pid: Int32 = 300, media: String = "video-1") -> NowPlayingSnapshot {
        NowPlayingSnapshot(identity: NowPlayingIdentity(bundleIdentifier: bundle,
            processIdentifier: pid, title: "Video", artist: nil, album: nil, duration: 120,
            uniqueIdentifier: .string(media), contentItemIdentifier: .string(media)), playing: playing)
    }

    override func setUp() {
        super.setUp()
        enabled = true
        remote = FakeNowPlaying()
        remote.state = .playback(snapshot(playing: true))
        fallback = FakeMediaPlayers()
        fallback.running = [fallback.music]
        fallback.set(.playing)
        sut = MediaController(players: fallback, nowPlaying: remote,
                              isEnabled: { [weak self] in self?.enabled ?? false })
    }

    private func begin() async {
        sut.captureDidBegin()
        await sut.waitForPendingOperations()
    }
    private func end() async {
        sut.captureDidEnd()
        await sut.waitForPendingOperations()
    }

    func testChromePlaybackPausesAndResumesWithoutTouchingFallback() async {
        await begin()
        XCTAssertEqual(remote.commands, ["pause"])
        await end()
        XCTAssertEqual(remote.commands, ["pause", "play"])
        XCTAssertEqual(fallback.calls, [])
    }

    func testScreenRecordingAppsAreNeverPausedOrResumed() async {
        for bundle in ["com.apple.QuickTimePlayerX", "com.obsproject.obs-studio",
                       "com.timpler.screenstudio", "com.awah.captur", "example.unknown-recorder"] {
            remote.state = .playback(snapshot(playing: true, bundle: bundle))
            await begin()
            await end()
        }
        XCTAssertEqual(remote.commands, [])
        XCTAssertEqual(fallback.calls, [])
    }

    func testSafariPlaybackPausesAndResumes() async {
        remote.state = .playback(snapshot(playing: true, bundle: "com.apple.Safari"))
        await begin()
        await end()
        XCTAssertEqual(remote.commands, ["pause", "play"])
    }

    func testEmptySessionLeavesAllPlaybackAlone() async {
        remote.state = .empty
        await begin()
        await end()
        XCTAssertEqual(remote.commands, [])
        XCTAssertEqual(fallback.calls, [])
    }

    func testPausedSessionDoesNotStartPlayingOrUseFallback() async {
        remote.state = .playback(snapshot(playing: false))
        await begin()
        await end()
        XCTAssertEqual(remote.commands, [])
        XCTAssertEqual(fallback.calls, [])
    }

    func testUnavailableAdapterUsesVerifiedNativeFallback() async {
        remote.state = .unavailable
        await begin()
        await end()
        XCTAssertEqual(remote.commands, [])
        XCTAssertEqual(fallback.calls, ["pause com.apple.Music", "play com.apple.Music"])
    }

    func testRecoveredAdapterWithDifferentActivePlayerDoesNotResumeFallback() async {
        remote.state = .unavailable
        await begin()
        remote.state = .playback(snapshot(playing: true))
        await end()
        XCTAssertEqual(fallback.calls, ["pause com.apple.Music"])
    }

    func testRecoveredAdapterWithEmptySessionDoesNotResumeFallback() async {
        remote.state = .unavailable
        await begin()
        remote.state = .empty
        await end()
        XCTAssertEqual(fallback.calls, ["pause com.apple.Music"])
    }

    func testUnavailableAdapterDoesNotStartPausedFallback() async {
        remote.state = .unavailable
        fallback.set(.paused)
        await begin()
        await end()
        XCTAssertEqual(fallback.calls, [])
    }

    func testFailedPauseNeverSchedulesResumeOrFallback() async {
        remote.pauseSucceeds = false
        await begin()
        await end()
        XCTAssertEqual(remote.commands, ["pause"])
        XCTAssertEqual(fallback.calls, [])
    }

    func testManualResumeIsLeftAlone() async {
        await begin()
        remote.state = .playback(snapshot(playing: true))
        await end()
        XCTAssertEqual(remote.commands, ["pause"])
    }

    func testChangedTabMediaIsNotResumed() async {
        await begin()
        remote.state = .playback(snapshot(playing: false, media: "video-2"))
        await end()
        XCTAssertEqual(remote.commands, ["pause"])
    }

    func testPlayerRestartIsNotResumed() async {
        await begin()
        remote.state = .playback(snapshot(playing: false, pid: 301))
        await end()
        XCTAssertEqual(remote.commands, ["pause"])
    }

    func testAnotherPlayerTakingOverIsNotResumed() async {
        await begin()
        remote.state = .playback(snapshot(playing: false, bundle: "com.apple.Music"))
        await end()
        XCTAssertEqual(remote.commands, ["pause"])
    }

    func testClosedPlayerOrLostDetectionIsNotResumed() async {
        await begin()
        remote.state = .empty
        await end()
        XCTAssertEqual(remote.commands, ["pause"])
        XCTAssertEqual(fallback.calls, [])
    }

    func testAdapterFailureAtEndDoesNotResumeFallback() async {
        await begin()
        remote.state = .unavailable
        await end()
        XCTAssertEqual(remote.commands, ["pause"])
        XCTAssertEqual(fallback.calls, [])
    }

    func testDisabledSettingDoesNothing() async {
        enabled = false
        await begin()
        await end()
        XCTAssertEqual(remote.commands, [])
        XCTAssertEqual(fallback.calls, [])
    }

    func testDisablingAfterPauseStillResumesOwnedSession() async {
        await begin()
        enabled = false
        await end()
        XCTAssertEqual(remote.commands, ["pause", "play"])
    }

    func testOverlappingCapturesAndCancelResumeOnce() async {
        await begin()
        await begin()
        await end()
        XCTAssertEqual(remote.commands, ["pause"])
        sut.captureDidCancel()
        await sut.waitForPendingOperations()
        await end()
        XCTAssertEqual(remote.commands, ["pause", "play"])
    }

    func testCaptureEndingDuringReadNeverPauses() async {
        remote.onRead = { [weak self] in self?.sut.captureDidEnd() }
        await begin()
        await sut.waitForPendingOperations()
        XCTAssertEqual(remote.commands, [])
    }

    func testCaptureEndingWhilePauseInFlightStillResumesOwnedSession() async {
        remote.onPause = { [weak self] in self?.sut.captureDidEnd() }
        await begin()
        await sut.waitForPendingOperations()
        XCTAssertEqual(remote.commands, ["pause", "play"])
    }

    func testNewCaptureDuringResumeReadPreservesOwnershipUntilLastEnd() async {
        await begin()
        remote.onRead = { [weak self] in
            self?.remote.onRead = nil
            self?.sut.captureDidBegin()
        }
        await end()
        await sut.waitForPendingOperations()
        XCTAssertEqual(remote.commands, ["pause"])
        await end()
        XCTAssertEqual(remote.commands, ["pause", "play"])
    }

    private func waitForCommand(_ command: String) async {
        for _ in 0..<1000 {
            if remote.waitingCommand == command { return }
            await Task.yield()
        }
        XCTFail("Command did not reach pre-dispatch wait")
    }

    func testCaptureEndingBeforePauseDispatchRevokesCommand() async {
        remote.heldCommand = "pause"
        sut.captureDidBegin()
        await waitForCommand("pause")
        sut.captureDidEnd()
        remote.releaseCommand()
        await sut.waitForPendingOperations()
        XCTAssertEqual(remote.commands, [])
    }

    func testCaptureEndingDuringNativeQueryNeverPauses() async {
        remote.state = .unavailable
        fallback.onPlayback = { [weak self] in
            self?.fallback.onPlayback = nil
            self?.sut.captureDidEnd()
        }
        await begin()
        await sut.waitForPendingOperations()
        XCTAssertEqual(fallback.calls, [])
    }

    func testNewCaptureDuringNativeResumeQueryPreservesOwnership() async {
        remote.state = .unavailable
        await begin()
        fallback.onPlayback = { [weak self] in
            self?.fallback.onPlayback = nil
            self?.sut.captureDidBegin()
        }
        await end()
        XCTAssertEqual(fallback.calls, ["pause com.apple.Music"])
        await end()
        XCTAssertEqual(fallback.calls, ["pause com.apple.Music", "play com.apple.Music"])
    }

    func testNewCaptureBeforeResumeDispatchKeepsPauseOwned() async {
        await begin()
        remote.heldCommand = "play"
        sut.captureDidEnd()
        await waitForCommand("play")
        sut.captureDidBegin()
        remote.releaseCommand()
        await sut.waitForPendingOperations()
        XCTAssertEqual(remote.commands, ["pause"])
        await end()
        XCTAssertEqual(remote.commands, ["pause", "play"])
    }

    func testShortNewCaptureDuringResumeStillRestoresOnItsEnd() async {
        await begin()
        remote.heldCommand = "play"
        sut.captureDidEnd()
        await waitForCommand("play")
        sut.captureDidBegin()
        sut.captureDidEnd()
        remote.releaseCommand()
        await sut.waitForPendingOperations()
        XCTAssertEqual(remote.commands, ["pause", "play"])
    }

    func testRepeatedPhaseUpdatesRemainBalanced() async {
        sut.update(holdsMicrophone: true)
        sut.update(holdsMicrophone: true)
        await sut.waitForPendingOperations()
        sut.update(holdsMicrophone: false)
        sut.update(holdsMicrophone: false)
        await sut.waitForPendingOperations()
        XCTAssertEqual(remote.commands, ["pause", "play"])
    }
}

private final class BlockingMediaEvents: MediaPlayerEventHandling, @unchecked Sendable {
    let entered = XCTestExpectation(description: "Worker entered blocking query")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var onMain = false
    var wasOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    func runningPlayers() -> [MediaPlayer] {
        lock.lock(); onMain = Thread.isMainThread; lock.unlock()
        entered.fulfill()
        release.wait()
        return []
    }
    func playback(of player: MediaPlayer) -> MediaPlayback? { nil }
    func pause(_ player: MediaPlayer, permit: MediaCommandPermit) -> Bool { false }
    func play(_ player: MediaPlayer, permit: MediaCommandPermit) -> Bool { false }
}

@MainActor
final class MediaPlayerWorkerTests: XCTestCase {
    func testBlockingFallbackQueryLeavesMainActorResponsive() async {
        let backend = BlockingMediaEvents()
        let sut = SystemMediaPlayerController(backend: backend)
        let query = Task { await sut.runningPlayers() }
        await fulfillment(of: [backend.entered], timeout: 2)
        // This assertion runs on the main actor while the worker is still blocked.
        XCTAssertFalse(backend.wasOnMainThread)
        backend.release.signal()
        let players = await query.value
        XCTAssertEqual(players, [])
    }

    func testPermitRevocationRemovesHelperDispatchFile() {
        let permit = MediaCommandPermit()
        XCTAssertTrue(permit.isValid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: permit.fileURL.path))
        permit.invalidate()
        XCTAssertFalse(permit.isValid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: permit.fileURL.path))
        permit.invalidate()
    }
}
