/// Compile-time feature gates.
///
/// Parked features stay compiled and their tests keep running, so the code cannot
/// rot silently — but they have no reachable UI surface, hotkey, or menu item.
enum FeatureFlags {
    /// Thought capture + Open Brain sync. Parked 2026-07-24 for the dictation-only
    /// pivot (design spec §13). Re-enabling is a flag flip plus a UI reattachment.
    static let thoughtCapture = false
}
