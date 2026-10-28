import AppKit

/// Decision emitted by ``PushToTalkDetector`` for a single `flagsChanged` event.
enum PushToTalkDecision: Equatable, Sendable {
    case down   // the configured push-to-talk modifier just went down
    case up     // it just came back up
    case none   // no state change (noise, other modifier, repeat)
}

/// Pure state machine that turns a stream of modifier-flag transitions into
/// push-to-talk down/up decisions. Holds no AppKit state beyond the incoming
/// `(keyCode, flags)` pair, so it is fully unit-testable without live events.
///
/// - Right Option → keyCode 61 with `.option`.
/// - Right Command → keyCode 54 with `.command`.
/// - fnGlobe → `.function` flag transitions (keyCode is intentionally ignored,
///   since fn hardware reports inconsistent virtual keycodes).
/// Built from a `PushToTalkBinding` rather than a key, so a chord binding produces an
/// inert detector: while Carbon owns the edges the flags monitor must not also emit them,
/// or every hold would start two recordings.
extension PushToTalkDetector {
    init(binding: PushToTalkBinding) {
        self.init(key: binding.modifierKey)
    }
}

struct PushToTalkDetector {
    let key: PushToTalkKey

    /// The physical virtual keycode we require, or `nil` when the key is
    /// identified purely by its flag transition (fnGlobe / disabled).
    private let requiredKeyCode: UInt16?
    private let targetFlag: NSEvent.ModifierFlags?

    /// Whether the configured key is currently believed to be held down.
    private(set) var isDown: Bool = false

    init(key: PushToTalkKey) {
        self.key = key
        switch key {
        case .rightOption:
            requiredKeyCode = 61
            targetFlag = .option
        case .rightCommand:
            requiredKeyCode = 54
            targetFlag = .command
        case .fnGlobe:
            requiredKeyCode = nil       // identified by the .function transition alone
            targetFlag = .function
        case .disabled:
            requiredKeyCode = nil
            targetFlag = nil
        }
    }

    /// Feed one `flagsChanged` event. Returns the resulting press/release decision.
    ///
    /// A quick tap (press then immediate release) naturally yields a `.down`
    /// followed by a `.up` on successive events — no debouncing is applied, so
    /// sub-150ms taps still emit both edges (start-then-stop handled upstream).
    mutating func process(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> PushToTalkDecision {
        guard let targetFlag else { return .none }  // .disabled

        // For keycode-anchored keys (left/right variants share a flag), only the
        // matching physical key drives the machine — other keys are pure noise.
        if let requiredKeyCode, keyCode != requiredKeyCode {
            return .none
        }

        let present = flags.contains(targetFlag)
        if present {
            guard !isDown else { return .none }   // repeated-flag noise while held
            isDown = true
            return .down
        } else {
            guard isDown else { return .none }    // release with nothing held
            isDown = false
            return .up
        }
    }
}
