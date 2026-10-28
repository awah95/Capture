import XCTest
@testable import Captur

// MARK: - Double

/// Records what *would* have been played.
///
/// Nothing in this file may reach `NSSound`: a suite that beeps twice per test is
/// unusable, and a run that plays audio while the owner is on a call is worse than a
/// failing test.
@MainActor
final class FakeSoundPlayer: SoundPlaying {
    struct Play: Equatable {
        let sound: FeedbackSound
        let volume: Double
    }

    private(set) var plays: [Play] = []

    func play(_ sound: FeedbackSound, volume: Double) {
        plays.append(Play(sound: sound, volume: volume))
    }
}

// MARK: - Tests

@MainActor
final class SoundFeedbackTests: XCTestCase {

    private var player: FakeSoundPlayer!
    private var enabled = true
    private var volume = 0.5

    override func setUp() {
        super.setUp()
        player = FakeSoundPlayer()
        enabled = true
        volume = 0.5
    }

    private func makeFeedback() -> SoundFeedback {
        SoundFeedback(player: player,
                      isEnabled: { [weak self] in self?.enabled ?? false },
                      volume: { [weak self] in self?.volume ?? 0 })
    }

    // MARK: Defaults

    /// The plan: sounds are optional and **off by default**. A dictation tool that
    /// beeps at every keypress out of the box is one the user disables in the first
    /// minute, and it beeps inside whatever call they are on.
    func testSoundsAreOffByDefault() {
        let suite = "captur.sound.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.soundFeedback)
        XCTAssertEqual(settings.soundFeedbackVolume, 0.5, accuracy: 0.000_001,
                       "a stored volume of 0 would silently mean 'never play'")
    }

    // MARK: The toggle

    func testAnEnabledStartSoundPlaysAtTheConfiguredVolume() {
        let feedback = makeFeedback()
        feedback.playStart()

        XCTAssertEqual(player.plays, [.init(sound: .start, volume: 0.5)])
    }

    func testTheStopSoundIsADifferentSound() {
        let feedback = makeFeedback()
        feedback.playStop()

        XCTAssertEqual(player.plays, [.init(sound: .stop, volume: 0.5)])
        XCTAssertNotEqual(FeedbackSound.start.systemSoundName, FeedbackSound.stop.systemSoundName,
                          "start and stop must be distinguishable by ear")
    }

    func testNothingPlaysWhileTheToggleIsOff() {
        enabled = false
        volume = 1.0
        let feedback = makeFeedback()
        feedback.playStart()
        feedback.playStop()

        XCTAssertEqual(player.plays, [])
    }

    /// The toggle is read on every play, not captured once, so turning sounds off takes
    /// effect on the very next dictation rather than at the next launch.
    func testTheToggleIsReReadOnEveryPlay() {
        let feedback = makeFeedback()
        feedback.playStart()
        enabled = false
        feedback.playStop()

        XCTAssertEqual(player.plays, [.init(sound: .start, volume: 0.5)])
    }

    // MARK: Volume

    /// Zero volume must not reach the player at all. This is not the same as playing
    /// silently: a play wakes the output device, which costs a device start the user
    /// cannot hear and did not ask for (spec §15's idle budget).
    func testAVolumeOfZeroDoesNotPlayAtAll() {
        volume = 0
        let feedback = makeFeedback()
        feedback.playStart()

        XCTAssertEqual(player.plays, [], "a silent play still wakes the audio device")
    }

    /// A hand-edited plist, or a slider bug, must not hand `NSSound` a nonsense volume.
    func testAVolumeOutsideZeroToOneIsClampedRatherThanRefused() {
        volume = 4
        let feedback = makeFeedback()
        feedback.playStart()

        volume = -1
        feedback.playStop()

        XCTAssertEqual(player.plays, [.init(sound: .start, volume: 1.0)],
                       "a negative volume is 'do not play'; an over-loud one is clamped")
    }

    func testAVolumeJustAboveZeroStillPlays() {
        volume = 0.01
        let feedback = makeFeedback()
        feedback.playStart()

        XCTAssertEqual(player.plays.count, 1)
        XCTAssertEqual(player.plays.first?.volume ?? 0, 0.01, accuracy: 0.000_001)
    }
}
