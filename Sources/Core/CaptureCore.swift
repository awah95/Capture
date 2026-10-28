import Foundation

// Platform-agnostic capture vocabulary shared by the iPhone app, the Watch app,
// and the extensions. Pure Foundation — no UIKit/SwiftUI — so it compiles on
// watchOS too.

/// What a capture is *for*. Dictation is speed-first and feeds the clipboard /
/// keyboard; Thought is preservation-first and lands in a durable inbox without
/// ever touching the clipboard automatically.
enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case dictation
    case thought
}

/// Where a capture was started from. Persisted for filtering and diagnostics.
enum CaptureSource: String, Codable, Sendable {
    case iPhoneApp
    case backTap
    case siri
    case controlCenter
    case lockScreen
    case appleWatch
    case importedAudio
    case macApp
    case hotkey
    case palette
}

/// Durable-delivery state of a capture's audio. iPhone-origin captures are
/// `.local`; Watch-origin captures walk queued → sending → received as
/// `WCSession.transferFile` carries them across, and are only cleared on the
/// Watch after `.received`.
enum TransferState: String, Codable, Sendable {
    case local        // audio is already on this device (iPhone-origin, or a received Watch file)
    case queued       // Watch: recorded, waiting to transfer
    case sending      // Watch: transfer in flight
    case received     // iPhone: durably received and moved into permanent storage
    case failed       // transfer failed; audio retained for retry
}

/// Lifecycle of a single capture.
enum CaptureStatus: String, Codable, Sendable {
    case recording      // mic is live
    case pending        // recorded, waiting to transcribe (e.g. offline / queued)
    case transcribing   // upload in flight
    case success        // final Groq transcript in hand
    case failed         // transcription failed (retryable)

    /// Terminal states are safe to prune; everything else is still in-flight and
    /// must never be pruned (its audio may still be needed).
    var isTerminal: Bool { self == .success || self == .failed }
}

