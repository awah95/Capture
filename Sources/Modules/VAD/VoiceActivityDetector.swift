import Foundation

/// Auto-stop sensitivity presets for Dictation. They shift the silence interval
/// and the noise-floor margin so quiet speakers and noisy rooms both behave.
enum VADSensitivity: String, Codable, CaseIterable, Sendable, Identifiable {
    case whisper   // very quiet speech; more patient, lower speech threshold
    case normal
    case noisy     // ambient noise; needs a clearer margin above the floor

    var id: String { rawValue }
    var label: String {
        switch self {
        case .whisper: return "Whisper"
        case .normal:  return "Normal"
        case .noisy:   return "Noisy"
        }
    }
}

/// All tunable thresholds for silence auto-stop, centralised so the policy is
/// testable in isolation. Values are deliberately mode- and preset-derived rather
/// than a single hardcoded dB threshold; the detector calibrates its noise floor
/// adaptively at runtime.
struct VADConfig: Equatable, Sendable {
    /// Seconds of continuous silence after speech before auto-stopping.
    var silenceInterval: TimeInterval
    /// Ignore silence for this long at the very start (mic warm-up / lead-in).
    var warmUp: TimeInterval
    /// Require at least this much detected speech before any auto-stop is allowed.
    var minSpeech: TimeInterval
    /// How many times the adaptive noise floor a sample must reach to count as
    /// speech. Speech sits roughly 10–20 dB over room tone, so the useful range is
    /// about 2×–8× — and unlike a fixed offset this holds whether the signal arrives
    /// at 0.005 or 0.3.
    var speechRatio: Double
    /// The level below which nothing counts as speech however far above the floor it
    /// sits. Without it a silent room eventually satisfies any ratio, because the
    /// adaptive floor converges toward zero and noise is all that is left.
    var absoluteFloor: Double
    /// Where the adaptive floor starts before it has seen the room. Deliberately low:
    /// a floor that starts high suppresses the first words while it settles, and the
    /// first words are the ones users notice losing.
    var initialNoiseFloor: Double
    /// Whether auto-stop is enabled at all (Thought can effectively rely on manual
    /// stop + a long interval).
    var autoStopEnabled: Bool

    /// Dictation policy — speed-first. Short silence, brief warm-up.
    ///
    /// The thresholds are calibrated against real recordings, not derived: see
    /// `VADTests` and `Captur --probe-vad`, which replay audio the app itself saved.
    static func dictation(_ sensitivity: VADSensitivity) -> VADConfig {
        switch sensitivity {
        case .whisper:
            return VADConfig(silenceInterval: 2.0, warmUp: 0.6, minSpeech: 0.3,
                             speechRatio: 1.8, absoluteFloor: 0.0015,
                             initialNoiseFloor: 0.0015, autoStopEnabled: true)
        case .normal:
            return VADConfig(silenceInterval: 1.6, warmUp: 0.5, minSpeech: 0.4,
                             speechRatio: 2.5, absoluteFloor: 0.0025,
                             initialNoiseFloor: 0.002, autoStopEnabled: true)
        case .noisy:
            return VADConfig(silenceInterval: 1.5, warmUp: 0.5, minSpeech: 0.5,
                             speechRatio: 4.0, absoluteFloor: 0.006,
                             initialNoiseFloor: 0.004, autoStopEnabled: true)
        }
    }

    /// Thought policy — completeness-first. Long silence tolerance for reflective
    /// pauses; manual Stop stays primary.
    static func thought(_ sensitivity: VADSensitivity) -> VADConfig {
        var base = dictation(sensitivity)
        base.silenceInterval = 5.0     // 4–6s range for natural pauses
        base.warmUp = 0.8
        base.minSpeech = 0.3
        return base
    }
}

/// Pure, testable silence detector. It is fed normalized level samples (0…1) and
/// decides when a recording should auto-stop. It keeps an adaptive noise floor,
/// smoothed level, warm-up gating, and last-speech timing — no timers, no audio
/// APIs, so it can be unit-tested deterministically by pushing samples with
/// explicit timestamps.
struct VoiceActivityDetector {

    /// Smoothing time constants, in seconds.
    ///
    /// Expressed as *time* rather than as a per-sample weight because the detector is
    /// fed one sample per audio buffer, and buffer size is not a constant: the engine
    /// delivers ~64 ms and the tests 100 ms, so a fixed per-sample weight silently
    /// means two different filters.
    static let attackTimeConstant = 0.05
    /// Deliberately shorter than the attack. Pause tolerance belongs to
    /// `silenceInterval` and `minimumSilenceForCut`, which are stated in seconds and
    /// were chosen on purpose; a slow release hides extra tolerance nobody chose
    /// inside a decay curve, and every millisecond of it is added to the latency of
    /// every segment cut.
    static let releaseTimeConstant = 0.025

    let config: VADConfig

    private(set) var noiseFloor: Double = 0.002
    private(set) var smoothedLevel: Double = 0
    private(set) var hasDetectedSpeech = false
    private(set) var lastSpeechTime: TimeInterval?
    private(set) var speechAccumulated: TimeInterval = 0
    private var startTime: TimeInterval?
    private var lastSampleTime: TimeInterval?

    init(config: VADConfig) {
        self.config = config
        noiseFloor = config.initialNoiseFloor
    }

    /// The level a sample must reach to count as speech.
    ///
    /// **A ratio above the noise floor, not a fixed distance above it.** The additive
    /// rule this replaces (`noiseFloor + speechMargin`, margin 0.16) assumed speech
    /// arrives at a level it never actually reaches: measured through echo
    /// cancellation, ordinary desk-distance speech has an RMS around 0.006 and peaks
    /// near 0.07, so a 0.18 threshold could not be crossed by a human being. Loudness
    /// spans a ~40 dB range across microphones and speakers; only a ratio survives it.
    ///
    /// `absoluteFloor` stops a *silent* room from qualifying: as the adaptive floor
    /// converges toward zero, any ratio would eventually be satisfied by noise.
    var speechThreshold: Double {
        max(config.absoluteFloor, noiseFloor * config.speechRatio)
    }

    /// Feed one level sample. Returns `true` when the recording should auto-stop.
    mutating func process(level: Double, at time: TimeInterval) -> Bool {
        if startTime == nil { startTime = time }
        let elapsed = time - (startTime ?? time)
        let dt = lastSampleTime.map { max(0, time - $0) } ?? 0
        lastSampleTime = time

        // Smooth the incoming level — asymmetrically.
        //
        // Rising is damped so a single transient (a key press, a chair) cannot open
        // speech on its own. Falling is fast, because the smoother must not add its
        // own release time on top of `silenceInterval`: pause tolerance is that
        // setting's job, stated in seconds, and burying a second more of it in a
        // decay constant makes the real tolerance a number nobody chose.
        //
        // This was invisible while the threshold was 0.18. Against a threshold ~36×
        // lower, the old symmetric 0.6 decay needed nine samples rather than two to
        // fall below it, so the detector noticed speech *ending* almost a second late
        // — which delays every segment cut, and latency is the product's whole claim.
        let tau = level >= smoothedLevel ? Self.attackTimeConstant : Self.releaseTimeConstant
        // A first sample has no elapsed time to integrate over, so it is taken whole.
        let alpha = dt > 0 ? 1 - exp(-dt / tau) : 1
        smoothedLevel += (level - smoothedLevel) * alpha

        let isSpeech = smoothedLevel >= speechThreshold

        if isSpeech {
            hasDetectedSpeech = true
            lastSpeechTime = time
            speechAccumulated += dt
        } else {
            // Adapt the noise floor slowly toward quiet ambient level.
            noiseFloor = min(noiseFloor * 0.98 + smoothedLevel * 0.02, 0.5)
        }

        guard config.autoStopEnabled else { return false }
        // Never stop during warm-up, or before we've heard real speech.
        guard elapsed >= config.warmUp, hasDetectedSpeech,
              speechAccumulated >= config.minSpeech else { return false }

        // Stop once we've been silent for the configured interval since last speech.
        if let last = lastSpeechTime, (time - last) >= config.silenceInterval {
            return true
        }
        return false
    }
}
