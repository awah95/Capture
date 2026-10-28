import Foundation

/// Turns push-to-talk down/up edges into start/stop decisions, including the
/// tap-to-latch discrimination from spec §4.1.
///
/// One physical key has to mean two things: held, it records while held; tapped, it
/// starts a recording that keeps running after the key comes back up. The only thing
/// separating them is how long the key was down, so the rule lives here as a pure
/// state machine over supplied timestamps rather than inside an event handler where
/// it could only be exercised by hand.
struct PushToTalkLatch {

    /// A release inside this window was a tap, not a hold. Long enough that a
    /// deliberate short phrase is not mistaken for a tap, short enough that a tap
    /// never feels like it needs holding.
    static let tapThreshold: TimeInterval = 0.35

    /// What the trigger path should do with the edge it just received.
    enum Decision: Equatable, Sendable {
        case none
        /// Start recording. `latched` is not yet known at key-down; it is decided on
        /// release.
        case start
        case stop
    }

    private enum State: Equatable {
        case idle
        /// The key is physically down; recording started at `since`.
        case held(since: TimeInterval)
        /// The key is up but the recording continues until the next tap.
        case latched
    }

    private var state: State = .idle

    /// True while a recording started by this key is still running.
    var isActive: Bool { state != .idle }

    init() {}

    /// The push-to-talk key went down at `time` (a monotonic clock, not wall time).
    mutating func down(at time: TimeInterval) -> Decision {
        switch state {
        case .idle:
            state = .held(since: time)
            return .start
        case .latched:
            // Tapping again is how a latched recording ends.
            state = .idle
            return .stop
        case .held:
            // Flag noise while the key is already down; the detector filters most of
            // this out, but a second down without an up must never restart a capture.
            return .none
        }
    }

    /// The push-to-talk key came back up at `time`.
    mutating func up(at time: TimeInterval) -> Decision {
        guard case .held(let since) = state else { return .none }
        if time - since < Self.tapThreshold {
            state = .latched
            return .none
        }
        state = .idle
        return .stop
    }

    /// The recording ended by some other route — a toggle hotkey, Esc, the menu bar,
    /// or the microphone disappearing. The key's own state has to follow, or the next
    /// tap would try to stop a recording that is already over.
    mutating func reset() {
        state = .idle
    }
}
