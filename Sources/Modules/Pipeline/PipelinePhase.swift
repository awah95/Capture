import Foundation

/// What the app is doing right now, as one value.
///
/// The HUD, the menu-bar icon and the Esc binding all read this instead of
/// reconstructing state from a handful of booleans, so there is exactly one place
/// where "recording" can be true and exactly one definition of what follows it.
enum PipelinePhase: Equatable, Sendable {
    case idle
    /// The microphone has been asked for but has not delivered a buffer yet.
    /// Distinct from `recording` because the first word is only safe once the tap
    /// is live, and the user is entitled to see the difference.
    case arming
    case recording(elapsed: TimeInterval, modeName: String)
    case transcribing
    /// The mode's LLM pass. Unreachable until modes are wired (Task 16); v1 inserts
    /// the stitched transcript directly.
    case refining(modeName: String)
    case success(words: Int, wpm: Int)
    /// `retryable` means the audio is still on disk and re-running transcription
    /// could plausibly succeed — a network failure, not a denied permission.
    case error(message: String, retryable: Bool)
}

extension PipelinePhase {

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// True while a capture owns the microphone or the transcription pipeline.
    ///
    /// A second trigger is rejected on `arming`/`recording` but deliberately *not*
    /// on `transcribing`: spec §4.1 lets a new recording start while the previous
    /// one is still being transcribed, and the two pipeline independently.
    var holdsMicrophone: Bool {
        switch self {
        case .arming, .recording: return true
        case .idle, .transcribing, .refining, .success, .error: return false
        }
    }
}

/// How a capture was started.
///
/// The pipeline keeps this so the trigger path can tell a held key (which ends on
/// release) from a latched recording (which ends on the next trigger). Nothing
/// downstream of insertion cares.
enum CaptureTrigger: Equatable, Sendable {
    /// Held modifier. Ends when the key comes back up, unless the release lands
    /// inside the tap window and latches instead.
    case pushToTalk
    /// A latched recording started by a hotkey combo or by tapping the
    /// push-to-talk key.
    case toggle
    case menuBar
}
