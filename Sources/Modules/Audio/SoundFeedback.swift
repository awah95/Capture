import AppKit
import Foundation

// MARK: - Sounds

/// The two moments worth a sound. Both are system sounds rather than bundled assets:
/// they are already on every Mac, already short, and already the sounds the user's ear
/// reads as "the machine acknowledged something".
enum FeedbackSound: Equatable {
    case start
    case stop

    /// A file in `/System/Library/Sounds`. Two audibly different sounds, on purpose —
    /// the whole point is knowing without looking whether recording began or ended.
    var systemSoundName: String {
        switch self {
        case .start: return "Tink"
        case .stop: return "Pop"
        }
    }
}

// MARK: - Seam

/// The playback surface.
///
/// A seam because a suite that actually plays sounds beeps hundreds of times per run and
/// does it through whatever call the owner happens to be on. Nothing above this protocol
/// may touch `NSSound`.
@MainActor protocol SoundPlaying {
    /// Plays `sound` at `volume` (0…1, already clamped and already known to be > 0).
    func play(_ sound: FeedbackSound, volume: Double)
}

/// The production player.
///
/// Sounds are **cached after their first load**. An `NSSound(named:)` reads and decodes a
/// file from disk on the main thread, and the one moment this player is asked for the
/// start sound is the moment a recording is being armed — the same main thread that owes
/// the user a live microphone inside 250 ms (spec §15). Paying that cost once at the
/// first dictation is acceptable; paying it at every one is not.
@MainActor
final class SystemSoundPlayer: SoundPlaying {
    private var cache: [String: NSSound] = [:]

    func play(_ sound: FeedbackSound, volume: Double) {
        let name = sound.systemSoundName
        let loaded: NSSound?
        if let cached = cache[name] {
            loaded = cached
        } else {
            loaded = NSSound(named: name)
            if let loaded { cache[name] = loaded }
        }

        // A missing system sound is a silent no-op. A dictation must never fail, or even
        // report anything, because a decorative beep could not be found.
        guard let nsSound = loaded else { return }

        nsSound.volume = Float(volume)
        // The same instance is reused, and a start sound still ringing when the next
        // dictation begins would otherwise be ignored rather than restarted.
        if nsSound.isPlaying { nsSound.stop() }
        nsSound.play()
    }
}

// MARK: - Feedback

/// Optional start/stop sounds, spec §10.5's General section.
///
/// Off by default (`AppSettings.soundFeedback`): a dictation tool that beeps out of the
/// box beeps inside whatever meeting the user is in the first time they try it.
@MainActor
final class SoundFeedback {
    private let player: any SoundPlaying
    private let isEnabled: () -> Bool
    private let volume: () -> Double

    /// Both settings arrive as closures and are read **on every play**, so a toggle
    /// flipped in Settings applies to the next dictation rather than the next launch.
    /// The player defaults to the real one, but as `nil` rather than as
    /// `SystemSoundPlayer()`: a default argument is evaluated outside the actor, and
    /// `SystemSoundPlayer` is `@MainActor` because `NSSound` is.
    init(player: (any SoundPlaying)? = nil,
         isEnabled: @escaping () -> Bool,
         volume: @escaping () -> Double) {
        self.player = player ?? SystemSoundPlayer()
        self.isEnabled = isEnabled
        self.volume = volume
    }

    func playStart() { play(.start) }
    func playStop() { play(.stop) }

    private func play(_ sound: FeedbackSound) {
        guard isEnabled() else { return }

        let level = min(max(volume(), 0), 1)
        // Zero is *do not play*, which is not the same as playing silently: a play wakes
        // the output device for a sound nobody can hear, on the exact code path that is
        // supposed to be arming a microphone. A hand-edited plist can also hand us a
        // nonsense number, hence the clamp above rather than a precondition.
        guard level > 0 else { return }

        player.play(sound, volume: level)
    }
}
