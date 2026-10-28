import Foundation

/// The one serial queue that owns every per-buffer audio operation: tap delivery,
/// format conversion, level computation and file writing.
///
/// The capture path deliberately never touches the main actor per buffer. At a 1024
/// frame buffer size the tap fires 20–50 times a second, and the main actor is busy
/// laying out a 30 fps waveform — a single SwiftUI stall there would drop audio.
/// Only the throttled meter level (~30 Hz) and the active-device-change notification
/// are hopped to main, and both are explicit.
enum AudioQueue {
    static let queue = DispatchQueue(label: "com.awah.captur.audio", qos: .userInitiated)

    /// Debug-only confinement guard. Traps in DEBUG when audio-path work has leaked
    /// onto the main thread; compiled away entirely in release, so a mistake can never
    /// take down a shipping build mid-dictation.
    static func assertNotMain(_ context: String) {
        #if DEBUG
        if Thread.isMainThread {
            assertionFailure("\(context) ran on the main thread; it must stay on AudioQueue.")
        }
        #endif
    }
}
