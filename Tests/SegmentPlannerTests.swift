import XCTest
@testable import Captur

/// The segment planner is pure arithmetic over a recording's running state, so
/// every rule can be pinned exactly — no audio, no clock, no async.
final class SegmentPlannerTests: XCTestCase {

    private let planner = SegmentPlanner(config: .default)

    // MARK: - Cutting

    func test_cutsAfterLongEnoughSegmentAndLongEnoughSilence() {
        XCTAssertTrue(planner.shouldCut(currentSegmentDuration: 9.0,
                                        continuousSilenceDuration: 0.7,
                                        isSpeaking: false))
    }

    func test_doesNotCutWhenSegmentIsTooShort() {
        // A real pause, but not enough audio yet to be worth its own request —
        // Groq bills a 10s minimum per request and each seam risks a word.
        XCTAssertFalse(planner.shouldCut(currentSegmentDuration: 4.0,
                                         continuousSilenceDuration: 2.0,
                                         isSpeaking: false))
    }

    func test_doesNotCutWhenSilenceIsTooShort() {
        // Plenty of audio, but 0.3s is a breath between words, not a boundary.
        XCTAssertFalse(planner.shouldCut(currentSegmentDuration: 30.0,
                                         continuousSilenceDuration: 0.3,
                                         isSpeaking: false))
    }

    func test_neverCutsWhileSpeechIsActive() {
        // Cutting mid-word would split the utterance across two requests.
        XCTAssertFalse(planner.shouldCut(currentSegmentDuration: 30.0,
                                         continuousSilenceDuration: 0.9,
                                         isSpeaking: true))
    }

    func test_disabledPlannerNeverCuts() {
        var config = SegmentPlannerConfig.default
        config.enabled = false
        let disabled = SegmentPlanner(config: config)
        XCTAssertFalse(disabled.shouldCut(currentSegmentDuration: 60.0,
                                          continuousSilenceDuration: 5.0,
                                          isSpeaking: false))
    }

    func test_boundaryValuesAreInclusive() {
        XCTAssertTrue(planner.shouldCut(currentSegmentDuration: 8.0,
                                        continuousSilenceDuration: 0.6,
                                        isSpeaking: false))
    }

    /// One tick below either boundary must not cut — the inclusive test above
    /// would still pass if the comparisons were sloppy in the other direction.
    func test_justBelowEitherBoundaryDoesNotCut() {
        XCTAssertFalse(planner.shouldCut(currentSegmentDuration: 7.99,
                                         continuousSilenceDuration: 0.6,
                                         isSpeaking: false))
        XCTAssertFalse(planner.shouldCut(currentSegmentDuration: 8.0,
                                         continuousSilenceDuration: 0.59,
                                         isSpeaking: false))
    }

    func test_customConfigThresholdsAreHonoured() {
        var config = SegmentPlannerConfig.default
        config.minimumSegmentLength = 3.0
        config.minimumSilenceForCut = 1.5
        let eager = SegmentPlanner(config: config)

        XCTAssertTrue(eager.shouldCut(currentSegmentDuration: 3.0,
                                      continuousSilenceDuration: 1.5,
                                      isSpeaking: false))
        XCTAssertFalse(eager.shouldCut(currentSegmentDuration: 3.0,
                                       continuousSilenceDuration: 1.4,
                                       isSpeaking: false),
                       "silence threshold must come from config, not the default 0.6")
    }

    func test_zeroDurationsNeverCut() {
        // The state at the very start of a recording.
        XCTAssertFalse(planner.shouldCut(currentSegmentDuration: 0,
                                         continuousSilenceDuration: 0,
                                         isSpeaking: false))
    }

    // MARK: - Dispatch gating (anti-hallucination)

    func test_dispatchesASegmentWithRealSpeech() {
        XCTAssertTrue(planner.shouldDispatch(speechDuration: 2.4))
    }

    func test_neverDispatchesASilentSegment() {
        // Whisper invents text ("Thank you.", subtitle credits) when fed silence,
        // and that invention would land at the user's cursor.
        XCTAssertFalse(planner.shouldDispatch(speechDuration: 0.0))
    }

    func test_neverDispatchesABarelySpokenSegment() {
        XCTAssertFalse(planner.shouldDispatch(speechDuration: 0.2))
    }

    func test_dispatchBoundaryIsInclusive() {
        XCTAssertTrue(planner.shouldDispatch(speechDuration: 0.3))
        XCTAssertFalse(planner.shouldDispatch(speechDuration: 0.29))
    }

    func test_dispatchGateIsIndependentOfEnabledFlag() {
        // Turning segmentation off must not disable the hallucination guard —
        // the single whole-recording segment still has to pass it.
        var config = SegmentPlannerConfig.default
        config.enabled = false
        let disabled = SegmentPlanner(config: config)
        XCTAssertFalse(disabled.shouldDispatch(speechDuration: 0.0))
        XCTAssertTrue(disabled.shouldDispatch(speechDuration: 2.0))
    }

    func test_defaultConfigMatchesTheShippedPolicy() {
        let config = SegmentPlannerConfig.default
        XCTAssertEqual(config.minimumSilenceForCut, 0.6)
        XCTAssertEqual(config.minimumSegmentLength, 8.0)
        XCTAssertEqual(config.minimumSpeechToDispatch, 0.3)
        XCTAssertTrue(config.enabled)
    }
}
