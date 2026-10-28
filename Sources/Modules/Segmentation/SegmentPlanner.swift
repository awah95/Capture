import Foundation

/// Thresholds governing how a live recording is chopped into transcription
/// segments. Groq's Whisper endpoint is batch-only — no streaming, no realtime —
/// so the only way to make dictation feel instant is to close a segment at a
/// natural pause and transcribe it while the user is still talking. At key-release
/// just the short tail is left on the critical path.
struct SegmentPlannerConfig: Equatable, Sendable {
    /// Continuous silence that qualifies as a real boundary rather than the gap
    /// between two words.
    var minimumSilenceForCut: TimeInterval = 0.6
    /// Don't spend a separate request on less audio than this. Groq bills a
    /// 10-second minimum per request, and every seam is a place a word can be
    /// clipped or duplicated.
    var minimumSegmentLength: TimeInterval = 8.0
    /// Speech a finished segment must contain before it is worth sending at all.
    var minimumSpeechToDispatch: TimeInterval = 0.3
    /// When false, the recording is transcribed as one whole clip.
    var enabled: Bool = true

    static let `default` = SegmentPlannerConfig()
}

/// The pure decision function at the heart of segmentation: given a recording's
/// running state, should the open segment be closed now, and is a finished
/// segment worth sending to Groq? No audio, no clock, no I/O — every rule here is
/// directly testable.
struct SegmentPlanner: Sendable {
    let config: SegmentPlannerConfig

    init(config: SegmentPlannerConfig = .default) {
        self.config = config
    }

    /// True when the currently-open segment should be closed and sent.
    ///
    /// Cut only at a genuine pause with enough audio banked: never mid-speech
    /// (that splits an utterance across two requests), never on a between-words
    /// breath, and never on a stub too short to pay for its own request.
    /// Boundaries are inclusive.
    func shouldCut(currentSegmentDuration: TimeInterval,
                   continuousSilenceDuration: TimeInterval,
                   isSpeaking: Bool) -> Bool {
        guard config.enabled else { return false }
        guard !isSpeaking else { return false }
        guard currentSegmentDuration >= config.minimumSegmentLength else { return false }
        return continuousSilenceDuration >= config.minimumSilenceForCut
    }

    /// False when a finished segment holds too little speech to be worth
    /// transcribing — the anti-hallucination guard.
    ///
    /// Fed near-silence, Whisper invents text: "Thank you.", a subtitle credit,
    /// a stray phrase. That invention would be typed straight into whatever the
    /// user has focused. Cheapest possible guard against the app's most
    /// embarrassing failure, so it applies even when segmentation is disabled.
    func shouldDispatch(speechDuration: TimeInterval) -> Bool {
        speechDuration >= config.minimumSpeechToDispatch
    }
}
