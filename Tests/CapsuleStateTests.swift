import XCTest
import AppKit
@testable import Captur

/// Spec §9. The capsule's content is a pure function of the pipeline phase plus the
/// transient notices layered over it, so every rule in the table below is tested
/// without a window, a run loop, or a screen.
@MainActor
final class CapsuleStateTests: XCTestCase {

    // MARK: - Test doubles

    /// A one-shot scheduler with a hand-cranked clock. Nothing in the presenter
    /// polls, so a fake that only fires what was explicitly scheduled is a complete
    /// substitute for `DispatchQueue.main.asyncAfter`.
    @MainActor
    final class FakeCapsuleScheduler: CapsuleScheduling {

        @MainActor
        final class Token: CapsuleScheduledWork {
            var isCancelled = false
            func cancel() { isCancelled = true }
        }

        private struct Pending {
            let fireAt: TimeInterval
            let token: Token
            let work: () -> Void
        }

        private(set) var now: TimeInterval = 0
        private var pending: [Pending] = []

        var pendingCount: Int { pending.filter { !$0.token.isCancelled }.count }

        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> any CapsuleScheduledWork {
            let token = Token()
            pending.append(Pending(fireAt: now + delay, token: token, work: work))
            return token
        }

        /// Advances the clock and fires everything that came due, oldest first.
        func advance(_ interval: TimeInterval) {
            now += interval
            while true {
                pending.removeAll { $0.token.isCancelled }
                guard let index = pending
                    .enumerated()
                    .filter({ $0.element.fireAt <= now })
                    .min(by: { $0.element.fireAt < $1.element.fireAt })?
                    .offset
                else { return }
                let due = pending.remove(at: index)
                due.work()
            }
        }
    }

    private func makePresenter() -> (CapsulePresenter, FakeCapsuleScheduler) {
        let scheduler = FakeCapsuleScheduler()
        return (CapsulePresenter(scheduler: scheduler), scheduler)
    }

    // MARK: - Recording

    func testRecordingShowsWaveformPulsingDotAndListeningStatus() {
        let content = CapsuleState.content(
            for: .recording(elapsed: 0, modeName: "Verbatim"), elapsed: 0)
        XCTAssertTrue(content.showsWaveform)
        XCTAssertTrue(content.waveformIsLive, "the recording waveform is the live one")
        XCTAssertTrue(content.showsPulsingDot)
        XCTAssertEqual(content.primaryText, "Listening")
        XCTAssertNil(content.symbolName)
        XCTAssertEqual(content.tint, .danger, "the recording dot is red")
        XCTAssertNil(content.autoDismissAfter, "a recording ends when the user ends it")
        XCTAssertGreaterThan(content.targetWidth, CapsuleState.collapsedWidth)
    }

    func testElapsedJoinsTheListeningStatusAfterTenSeconds() {
        func text(at seconds: TimeInterval) -> String? {
            CapsuleState.content(
                for: .recording(elapsed: seconds, modeName: "Verbatim"), elapsed: seconds).primaryText
        }
        XCTAssertEqual(text(at: 0), "Listening")
        XCTAssertEqual(text(at: 9), "Listening")
        XCTAssertEqual(text(at: 9.99), "Listening")
        XCTAssertEqual(text(at: 10), "Listening · 0:10")
        XCTAssertEqual(text(at: 42), "Listening · 0:42")
        XCTAssertEqual(text(at: 65), "Listening · 1:05")
        XCTAssertEqual(text(at: 600), "Listening · 10:00")
    }

    func testElapsedTextWidensTheCapsuleBeyondListening() {
        let listening = CapsuleState.content(
            for: .recording(elapsed: 0, modeName: "Verbatim"), elapsed: 0)
        let withElapsed = CapsuleState.content(
            for: .recording(elapsed: 30, modeName: "Verbatim"), elapsed: 30)
        XCTAssertGreaterThan(listening.targetWidth, CapsuleState.collapsedWidth)
        XCTAssertGreaterThan(withElapsed.targetWidth, listening.targetWidth)
        XCTAssertLessThanOrEqual(withElapsed.targetWidth, CapsuleState.maximumWidth)
    }

    // MARK: - Arming

    func testArmingShowsADotWithoutAWaveformOrPulse() {
        let content = CapsuleState.content(for: .arming, elapsed: 0)
        XCTAssertFalse(content.showsWaveform, "there is nothing to draw until the tap is live")
        XCTAssertFalse(content.showsPulsingDot, "the dot only breathes while recording")
        XCTAssertEqual(content.symbolName, "circle.fill")
        XCTAssertEqual(content.tint, .danger)
        XCTAssertEqual(content.primaryText, "Starting…")
        XCTAssertGreaterThanOrEqual(content.targetWidth, CapsuleState.collapsedWidth)
    }

    // MARK: - Transcribing / refining

    func testTranscribingFreezesTheWaveformAndShimmersWithoutDismissing() {
        let content = CapsuleState.content(for: .transcribing, elapsed: 0)
        XCTAssertTrue(content.showsWaveform)
        XCTAssertFalse(content.waveformIsLive,
                       "a frozen waveform must not keep a 30 fps timeline alive")
        XCTAssertTrue(content.showsShimmer)
        XCTAssertFalse(content.showsPulsingDot)
        XCTAssertEqual(content.primaryText, "Transcribing…")
        XCTAssertNil(content.autoDismissAfter, "it stays up until transcription finishes")
    }

    func testRefiningNamesTheModeAndShimmers() {
        let content = CapsuleState.content(for: .refining(modeName: "Email"), elapsed: 0)
        XCTAssertEqual(content.primaryText, "Email")
        XCTAssertNotNil(content.symbolName)
        XCTAssertTrue(content.showsShimmer)
        XCTAssertEqual(content.tint, .accent)
        XCTAssertFalse(content.showsWaveform)
        XCTAssertNil(content.autoDismissAfter)
    }

    // MARK: - Success

    func testSuccessRendersWordsAndWordsPerMinute() {
        let content = CapsuleState.content(for: .success(words: 142, wpm: 118), elapsed: 0)
        XCTAssertEqual(content.primaryText, "142 words · 118 wpm")
        XCTAssertEqual(content.tint, .success)
        XCTAssertEqual(content.autoDismissAfter, 1.2)
        XCTAssertEqual(content.symbolName, "checkmark.circle.fill")
        XCTAssertFalse(content.showsWaveform)
        XCTAssertFalse(content.showsPulsingDot)
    }

    func testSuccessUsesTheSingularForOneWord() {
        let content = CapsuleState.content(for: .success(words: 1, wpm: 60), elapsed: 0)
        XCTAssertEqual(content.primaryText, "1 word · 60 wpm")
    }

    // MARK: - Error

    func testRetryableErrorSaysAudioIsSavedAndOffersCommandR() {
        let content = CapsuleState.content(
            for: .error(message: "Groq is unreachable", retryable: true), elapsed: 0)
        XCTAssertNotNil(content.primaryText)
        XCTAssertTrue(content.primaryText?.contains("audio saved") == true,
                      "the user must be told nothing was lost: \(content.primaryText ?? "nil")")
        XCTAssertTrue(content.primaryText?.contains("⌘R") == true)
        XCTAssertTrue(content.primaryText?.contains("Groq is unreachable") == true)
        XCTAssertEqual(content.tint, .danger)
        XCTAssertEqual(content.autoDismissAfter, 4)
    }

    func testAnErrorThatAlreadyMentionsSavedAudioDoesNotRepeatItself() {
        // The pipeline's own message already ends with "— audio saved."
        let content = CapsuleState.content(
            for: .error(message: DictationPipeline.transcriptionFailedMessage, retryable: true),
            elapsed: 0)
        let text = content.primaryText ?? ""
        let occurrences = text.lowercased().components(separatedBy: "audio saved").count - 1
        XCTAssertEqual(occurrences, 1, "got: \(text)")
    }

    func testNonRetryableErrorOffersNoRetryAndClaimsNoSavedAudio() {
        let content = CapsuleState.content(
            for: .error(message: "Recording failed: the microphone was refused", retryable: false),
            elapsed: 0)
        XCTAssertFalse(content.primaryText?.contains("⌘R") == true)
        XCTAssertFalse(content.primaryText?.lowercased().contains("audio saved") == true,
                       "there is no audio to retry, so promising a saved file would be a lie")
        XCTAssertEqual(content.tint, .danger)
        XCTAssertEqual(content.autoDismissAfter, 4)
    }

    // MARK: - Width and truncation

    func testWidthNeverExceedsTheMaximumForAnyPhase() {
        let phases: [PipelinePhase] = [
            .idle,
            .arming,
            .recording(elapsed: 0, modeName: "Verbatim"),
            .recording(elapsed: 99_999, modeName: "Verbatim"),
            .transcribing,
            .refining(modeName: String(repeating: "Correspondence ", count: 40)),
            .success(words: 999_999, wpm: 999_999),
            .error(message: String(repeating: "something went wrong ", count: 60), retryable: true)
        ]
        for phase in phases {
            let content = CapsuleState.content(for: phase, elapsed: 120)
            XCTAssertLessThanOrEqual(content.targetWidth, CapsuleState.maximumWidth, "\(phase)")
            XCTAssertGreaterThanOrEqual(content.targetWidth, CapsuleState.collapsedWidth, "\(phase)")
        }
    }

    func testLongErrorTextIsMiddleTruncatedAndNeverClipped() {
        let message = "The transcription service returned an unexpected response after "
            + "several retries and the network looked unhealthy throughout"
        let content = CapsuleState.content(for: .error(message: message, retryable: true), elapsed: 0)
        let text = content.primaryText ?? ""

        XCTAssertEqual(content.targetWidth, CapsuleState.maximumWidth)
        XCTAssertTrue(text.contains("…"), "long text must be elided, not cut: \(text)")
        XCTAssertTrue(text.hasPrefix("The transcription"), "the head of the reason survives: \(text)")
        XCTAssertTrue(text.hasSuffix("⌘R to retry"), "the retry affordance survives: \(text)")

        // Never clipped: the string that reaches the view already fits the box.
        let available = CapsuleState.textWidth(
            inCapsuleWidth: content.targetWidth, showsWaveform: false)
        XCTAssertLessThanOrEqual(CapsuleState.measure(text), available)
    }

    func testShortTextIsNotTruncated() {
        let content = CapsuleState.content(for: .success(words: 142, wpm: 118), elapsed: 0)
        XCTAssertFalse(content.primaryText?.contains("…") == true)
    }

    func testTruncationKeepsBothEnds() {
        let text = "alpha bravo charlie delta echo foxtrot golf hotel india juliett"
        let truncated = CapsuleState.truncated(text, toWidth: 120)
        XCTAssertNotEqual(truncated, text)
        XCTAssertTrue(truncated.contains("…"))
        XCTAssertTrue(text.hasPrefix(truncated.components(separatedBy: "…")[0]))
        XCTAssertTrue(text.hasSuffix(truncated.components(separatedBy: "…")[1]))
        XCTAssertLessThanOrEqual(CapsuleState.measure(truncated), 120)
    }

    func testMoonshineLiveTranscriptKeepsTheNewestWordsAndRecordingDot() {
        let text = "alpha bravo charlie delta echo foxtrot golf hotel india newest words"
        let content = CapsuleState.content(forLiveTranscript: text)

        XCTAssertTrue(content.showsPulsingDot)
        XCTAssertFalse(content.showsWaveform)
        XCTAssertEqual(content.tint, .danger)
        XCTAssertTrue(try XCTUnwrap(content.primaryText).hasSuffix("newest words"))
        XCTAssertLessThanOrEqual(content.targetWidth, CapsuleState.maximumWidth)
    }

    func testLiveTranscriptOverridesRecordingAndClearsWhenRecordingEnds() {
        let (presenter, _) = makePresenter()
        presenter.update(phase: .recording(elapsed: 0, modeName: "Verbatim"))
        presenter.update(liveTranscript: "This is arriving live")

        XCTAssertEqual(presenter.content.primaryText, "This is arriving live")
        XCTAssertTrue(presenter.content.showsPulsingDot)
        XCTAssertFalse(presenter.content.showsWaveform)

        presenter.update(phase: .transcribing)
        XCTAssertNil(presenter.liveTranscript)
        XCTAssertEqual(presenter.content.primaryText, "Transcribing…")
    }

    // MARK: - Notices layered over the phase

    func testModeSwitchedNoticeDismissesAtOnePointFourSecondsBackToRecordingContent() {
        let (presenter, clock) = makePresenter()
        presenter.update(phase: .recording(elapsed: 0, modeName: "Verbatim"))
        let recordingContent = presenter.content
        XCTAssertTrue(recordingContent.showsWaveform)

        // Switching mode mid-recording republishes .recording with a new mode name.
        presenter.update(phase: .recording(elapsed: 0, modeName: "Email"))
        XCTAssertEqual(presenter.content.primaryText, "Email")
        XCTAssertEqual(presenter.content.tint, .accent)
        XCTAssertEqual(presenter.content.autoDismissAfter, 1.4)
        XCTAssertFalse(presenter.content.showsWaveform, "the notice replaces the waveform")

        // The elapsed second ticking must not cut the notice short.
        clock.advance(1.0)
        presenter.update(phase: .recording(elapsed: 1, modeName: "Email"))
        XCTAssertEqual(presenter.content.primaryText, "Email", "still showing at 1.0 s")

        clock.advance(0.41)
        XCTAssertEqual(presenter.content, recordingContent,
                       "at 1.4 s the capsule collapses back to the recording content")
        XCTAssertTrue(presenter.isVisible)
    }

    func testWarningNoticeDismissesAtTwoAndAHalfSeconds() {
        let (presenter, clock) = makePresenter()
        presenter.update(phase: .recording(elapsed: 0, modeName: "Verbatim"))
        presenter.present(notice: .warning(text: "Fell back to the default input"))
        XCTAssertEqual(presenter.content.tint, .warning)
        XCTAssertEqual(presenter.content.autoDismissAfter, 2.5)
        XCTAssertEqual(presenter.content.primaryText, "Fell back to the default input")

        clock.advance(2.49)
        XCTAssertEqual(presenter.content.primaryText, "Fell back to the default input")
        clock.advance(0.02)
        XCTAssertTrue(presenter.content.showsWaveform, "back to the recording content")
    }

    func testAPhaseChangeCancelsAPendingNotice() {
        let (presenter, _) = makePresenter()
        presenter.update(phase: .recording(elapsed: 0, modeName: "Verbatim"))
        presenter.present(notice: .warning(text: "Microphone changed"))
        XCTAssertEqual(presenter.content.tint, .warning)
        presenter.update(phase: .transcribing)
        XCTAssertTrue(presenter.content.showsWaveform)
        XCTAssertFalse(presenter.content.waveformIsLive)
    }

    // MARK: - Visibility and auto-dismiss

    func testIdleHidesTheCapsule() {
        let (presenter, _) = makePresenter()
        presenter.update(phase: .recording(elapsed: 0, modeName: "Verbatim"))
        XCTAssertTrue(presenter.isVisible)
        presenter.update(phase: .idle)
        XCTAssertFalse(presenter.isVisible)
    }

    func testSuccessHidesAfterOnePointTwoSeconds() {
        let (presenter, clock) = makePresenter()
        presenter.update(phase: .success(words: 12, wpm: 90))
        XCTAssertTrue(presenter.isVisible)
        clock.advance(1.19)
        XCTAssertTrue(presenter.isVisible)
        clock.advance(0.02)
        XCTAssertFalse(presenter.isVisible)
    }

    func testErrorHidesAfterFourSeconds() {
        let (presenter, clock) = makePresenter()
        presenter.update(phase: .error(message: "Groq is unreachable", retryable: true))
        XCTAssertTrue(presenter.isVisible)
        clock.advance(3.99)
        XCTAssertTrue(presenter.isVisible)
        clock.advance(0.02)
        XCTAssertFalse(presenter.isVisible)
    }

    func testRecordingNeverAutoDismisses() {
        let (presenter, clock) = makePresenter()
        presenter.update(phase: .recording(elapsed: 0, modeName: "Verbatim"))
        clock.advance(600)
        XCTAssertTrue(presenter.isVisible)
    }

    func testANewCaptureReopensACapsuleThatAlreadyDismissedItself() {
        let (presenter, clock) = makePresenter()
        presenter.update(phase: .success(words: 3, wpm: 80))
        clock.advance(2)
        XCTAssertFalse(presenter.isVisible)
        presenter.update(phase: .arming)
        XCTAssertTrue(presenter.isVisible)
    }

    // MARK: - The transient ⌘R offer

    func testOnlyARetryableErrorOffersCommandR() {
        let (presenter, clock) = makePresenter()
        presenter.update(phase: .error(message: "Groq is unreachable", retryable: true))
        XCTAssertTrue(presenter.offersRetry)

        presenter.update(phase: .error(message: "Recording failed", retryable: false))
        XCTAssertFalse(presenter.offersRetry)

        presenter.update(phase: .error(message: "Groq is unreachable", retryable: true))
        XCTAssertTrue(presenter.offersRetry)
        // The offer must die with the capsule, or ⌘R stays stolen from every app.
        clock.advance(4.01)
        XCTAssertFalse(presenter.offersRetry)
    }

    func testDismissingTheCapsuleRevokesTheRetryOffer() {
        let (presenter, _) = makePresenter()
        presenter.update(phase: .error(message: "Groq is unreachable", retryable: true))
        presenter.dismiss()
        XCTAssertFalse(presenter.isVisible)
        XCTAssertFalse(presenter.offersRetry)
    }

    func testTheRetryComboIsCommandR() {
        XCTAssertEqual(CapsuleState.retryCombo.keyCode, 15)          // kVK_ANSI_R
        XCTAssertEqual(CapsuleState.retryCombo.carbonModifiers, 0x0100) // cmdKey
    }

    // MARK: - Waveform maths

    func testBarsLerpTowardTheirTargetAtThirtyFivePercentPerFrame() {
        let source = WaveformLevelSource()
        for _ in 0..<WaveformLevelSource.barCount { source.push(1.0) }
        XCTAssertEqual(source.displayed.allSatisfy { $0 == 0 }, true, "nothing moves until a frame")

        source.advance()
        let first = source.displayed[0]
        XCTAssertEqual(first, source.targets[0] * 0.35, accuracy: 0.0001)

        source.advance()
        XCTAssertEqual(source.displayed[0],
                       first + (source.targets[0] - first) * 0.35,
                       accuracy: 0.0001)
    }

    func testAdvancingTwiceForTheSameFrameDateIsIdempotent() {
        let source = WaveformLevelSource()
        for _ in 0..<WaveformLevelSource.barCount { source.push(1.0) }
        let date = Date()
        source.advance(to: date)
        let once = source.displayed
        source.advance(to: date)
        XCTAssertEqual(source.displayed, once)
    }

    func testTheBufferKeepsExactlyTwentyBarsAndRollsOldestOut() {
        let source = WaveformLevelSource()
        XCTAssertEqual(source.targets.count, 20)
        for _ in 0..<200 { source.push(0.5) }
        XCTAssertEqual(source.targets.count, 20)
        XCTAssertEqual(source.displayed.count, 20)
    }

    func testAQuietMicrophoneStillShowsMovement() {
        var normalizer = WaveformNormalizer()
        var values: [Double] = []
        for index in 0..<400 {
            let level = index % 2 == 0 ? 0.004 : 0.02   // a whisper
            values.append(normalizer.normalize(level))
        }
        let tail = values.suffix(40)
        let span = (tail.max() ?? 0) - (tail.min() ?? 0)
        XCTAssertGreaterThan(span, 0.3, "a quiet mic must not read as a flat line")
    }

    func testALoudMicrophoneDoesNotClipFlat() {
        var normalizer = WaveformNormalizer()
        var values: [Double] = []
        for index in 0..<400 {
            let level = index % 2 == 0 ? 0.45 : 0.95    // shouting
            values.append(normalizer.normalize(level))
        }
        let tail = Array(values.suffix(40))
        XCTAssertTrue(tail.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertTrue(tail.contains { $0 < 0.9 }, "a loud mic must not pin every bar to the ceiling")
    }

    func testResetClearsTheWaveformBetweenCaptures() {
        let source = WaveformLevelSource()
        for _ in 0..<40 { source.push(0.9) }
        for _ in 0..<20 { source.advance() }
        XCTAssertTrue(source.displayed.contains { $0 > 0.1 })
        source.reset()
        XCTAssertTrue(source.displayed.allSatisfy { $0 == 0 })
        XCTAssertTrue(source.targets.allSatisfy { $0 == 0 })
    }

    // MARK: - Geometry

    func testTheCapsuleGeometryMatchesTheSpec() {
        XCTAssertEqual(CapsuleState.collapsedWidth, 132)
        XCTAssertEqual(CapsuleState.maximumWidth, 340)
        XCTAssertEqual(CapsuleState.height, 30)
        XCTAssertEqual(CapsuleState.cornerRadius, 15)
        XCTAssertEqual(CapsuleState.horizontalPadding, 12)
        XCTAssertEqual(WaveformLevelSource.barCount, 20)
    }

    func testACollapsedWaveformCapsuleIsExactlyTheCollapsedWidth() {
        XCTAssertEqual(CapsuleState.width(forPrimaryText: nil, showsWaveform: true),
                       CapsuleState.collapsedWidth)
        XCTAssertEqual(CapsuleState.width(forPrimaryText: nil, showsWaveform: false),
                       CapsuleState.collapsedWidth)
    }

    // MARK: - Resting position

    private let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testWithNoStoredPositionTheCapsuleRestsBottomCentre() {
        let origin = CapsuleController.origin(width: CapsuleState.collapsedWidth,
                                              screenFrame: screenFrame,
                                              storedCentreOffset: nil)
        XCTAssertEqual(origin.x, screenFrame.midX - CapsuleState.collapsedWidth / 2)
        XCTAssertEqual(origin.y, CapsuleController.bottomInset)
    }

    func testDefaultPositionUsesTheVisibleWorkspaceAboveTheDock() {
        let visible = CGRect(x: 0, y: 80, width: 1512, height: 878)
        let origin = CapsuleController.origin(
            width: CapsuleState.collapsedWidth,
            screenFrame: screenFrame,
            visibleFrame: visible,
            storedCentreOffset: nil)

        XCTAssertEqual(origin.x, visible.midX - CapsuleState.collapsedWidth / 2)
        XCTAssertEqual(origin.y, visible.minY + CapsuleController.bottomInset)
    }

    func testAStaleSavedPositionIsClampedInsideTheVisibleWorkspace() {
        let visible = CGRect(x: 0, y: 80, width: 1512, height: 878)
        let origin = CapsuleController.origin(
            width: CapsuleState.collapsedWidth,
            screenFrame: screenFrame,
            visibleFrame: visible,
            storedCentreOffset: CGPoint(x: -500, y: -500))

        XCTAssertEqual(origin.x, visible.minX + CapsuleController.edgeInset)
        XCTAssertEqual(origin.y, visible.minY + CapsuleController.minimumBottomClearance)
    }

    func testFocusedSurfaceChoosesTheDisplayContainingMostOfIt() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1512, height: 982),
            CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        ]
        let window = CGRect(x: 1400, y: 100, width: 800, height: 700)

        XCTAssertEqual(CapsuleController.bestDisplayIndex(
            for: window, displayFrames: displays), 1)
    }

    /// The drift regression: a remembered position is a *centre*, so the capsule stays
    /// where it was put no matter how wide the current state is. Storing the left edge
    /// instead would move the capsule left by half of every width change — which the
    /// error capsule (340 pt) does to the recording capsule (96 pt) without the user
    /// touching anything.
    func testARememberedPositionIsIndependentOfTheCapsuleWidth() {
        let centre = CGPoint(x: 700, y: 120)
        let narrow = CapsuleController.origin(width: CapsuleState.collapsedWidth,
                                              screenFrame: screenFrame,
                                              storedCentreOffset: centre)
        let wide = CapsuleController.origin(width: CapsuleState.maximumWidth,
                                            screenFrame: screenFrame,
                                            storedCentreOffset: centre)

        XCTAssertEqual(narrow.x + CapsuleState.collapsedWidth / 2, 700)
        XCTAssertEqual(wide.x + CapsuleState.maximumWidth / 2, 700)
        XCTAssertEqual(narrow.y, 120)
        XCTAssertEqual(wide.y, 120)
    }

    func testARememberedPositionIsRelativeToItsOwnScreensOrigin() {
        let secondScreen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let origin = CapsuleController.origin(width: CapsuleState.collapsedWidth,
                                              screenFrame: secondScreen,
                                              storedCentreOffset: CGPoint(x: 700, y: 120))
        XCTAssertEqual(origin.x + CapsuleState.collapsedWidth / 2, 1512 + 700)
        XCTAssertEqual(origin.y, 120)
    }
}
