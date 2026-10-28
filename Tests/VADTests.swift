import XCTest
@testable import Captur

/// The silence detector is pure, so its policy can be driven deterministically by
/// feeding level samples with explicit timestamps — no audio hardware needed.
final class VADTests: XCTestCase {

    /// Level samples at a fixed cadence over [from, to].
    private func samples(level: Double, from: Double, to: Double, dt: Double = 0.05) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        var t = from
        while t <= to + 1e-9 { out.append((level, t)); t += dt }
        return out
    }

    /// Returns the time of the first auto-stop, or nil if it never stops.
    private func firstStop(_ d: inout VoiceActivityDetector, _ levels: [(Double, Double)]) -> Double? {
        for (lvl, t) in levels where d.process(level: lvl, at: t) { return t }
        return nil
    }

    func testDoesNotStopDuringContinuousSpeech() {
        var d = VoiceActivityDetector(config: .dictation(.normal))
        XCTAssertNil(firstStop(&d, samples(level: 0.6, from: 0, to: 3.0)))
    }

    func testDoesNotStopWithoutAnySpeech() {
        var d = VoiceActivityDetector(config: .dictation(.normal))
        // Pure silence from the start must not auto-stop (nothing was captured yet).
        XCTAssertNil(firstStop(&d, samples(level: 0.0, from: 0, to: 5.0)))
    }

    func testStopsAfterSustainedSilenceFollowingSpeech() {
        var d = VoiceActivityDetector(config: .dictation(.normal))
        var seq = samples(level: 0.6, from: 0, to: 1.0)
        seq += samples(level: 0.0, from: 1.05, to: 5.0)
        let stop = firstStop(&d, seq)
        XCTAssertNotNil(stop)
        XCTAssertGreaterThan(stop ?? 0, 1.0, "must not stop until after the speech + a silent gap")
    }

    func testThoughtToleratesLongerPausesThanDictation() {
        var seq = samples(level: 0.6, from: 0, to: 1.0)
        seq += samples(level: 0.0, from: 1.05, to: 4.0) // ~3s of silence

        var thought = VoiceActivityDetector(config: .thought(.normal))
        XCTAssertNil(firstStop(&thought, seq), "Thought needs ~5s of silence, not 3s")

        var dictation = VoiceActivityDetector(config: .dictation(.normal))
        XCTAssertNotNil(firstStop(&dictation, seq), "Dictation stops after ~1.6s of silence")
    }

    func testAutoStopDisabledNeverStops() {
        var cfg = VADConfig.dictation(.normal)
        cfg.autoStopEnabled = false
        var d = VoiceActivityDetector(config: cfg)
        var seq = samples(level: 0.6, from: 0, to: 1.0)
        seq += samples(level: 0.0, from: 1.05, to: 6.0)
        XCTAssertNil(firstStop(&d, seq))
    }

    func testWhisperDetectsQuietSpeechButNoisyIgnoresIt() {
        // 0.004 is quiet-but-real: measured desk speech runs 0.005–0.024 RMS and room
        // tone 0.0005–0.003, so this sits deliberately between them. The level this
        // test used to pass in — 0.16 — is not a level a microphone produces.
        var seq = samples(level: 0.004, from: 0, to: 1.6)
        seq += samples(level: 0.0, from: 1.65, to: 6.0)

        var whisper = VoiceActivityDetector(config: .dictation(.whisper))
        XCTAssertNotNil(firstStop(&whisper, seq), "Whisper preset should hear quiet speech, then stop")

        var noisy = VoiceActivityDetector(config: .dictation(.noisy))
        XCTAssertNil(firstStop(&noisy, seq), "Noisy preset treats quiet input as ambient and won't run forever off it")
    }

    // MARK: - Calibration against real recordings

    /// The bug this pins, in one line.
    ///
    /// A 5.7 s dictation that Groq transcribed as "Hello, how are you? How are things
    /// going?" was reported by the app as "No speech was heard" and never sent. Its
    /// per-buffer RMS peaked at 0.024; the threshold was a fixed `noiseFloor + 0.16`,
    /// so no human being could cross it. The levels below are that recording's.
    func testSpeechAtRealMeasuredLevelsIsHeard() {
        var vad = VoiceActivityDetector(config: .dictation(.normal))
        var time = 0.0
        // ~1 s of room tone, then ~2 s of speech at the levels the file actually holds.
        for _ in 0..<30 { _ = vad.process(level: 0.0015, at: time); time += 1.0 / 30 }
        for _ in 0..<60 { _ = vad.process(level: 0.012, at: time); time += 1.0 / 30 }

        XCTAssertGreaterThan(vad.speechAccumulated, 0.4,
                             "Speech at the level a microphone really produces must register")
        XCTAssertTrue(SegmentPlanner().shouldDispatch(speechDuration: vad.speechAccumulated),
                      "…and must clear the dispatch gate, or the dictation is silently discarded")
    }

    /// The other half: the anti-hallucination guard has to survive the recalibration.
    /// Fed near-silence, Whisper invents text and types it at the user's cursor.
    func testRoomToneAtRealMeasuredLevelsIsNotHeard() {
        var vad = VoiceActivityDetector(config: .dictation(.normal))
        var time = 0.0
        for index in 0..<180 {
            // Real room tone wanders; it does not sit on one value.
            _ = vad.process(level: index.isMultiple(of: 3) ? 0.0022 : 0.0008, at: time)
            time += 1.0 / 30
        }

        XCTAssertEqual(vad.speechAccumulated, 0, accuracy: 0.001)
        XCTAssertFalse(SegmentPlanner().shouldDispatch(speechDuration: vad.speechAccumulated))
    }

    /// Why a ratio rather than an offset: the bar has to move with the room.
    ///
    /// The same 0.006 signal is speech in a quiet room and ambient in a noisy one. A
    /// fixed offset cannot express that — it is either too high for the quiet room or
    /// too low for the noisy one, and the old 0.16 offset was too high for both.
    func testTheSameLevelIsSpeechInAQuietRoomAndAmbientInANoisyOne() {
        func speechHeard(afterAmbient ambient: Double) -> TimeInterval {
            var vad = VoiceActivityDetector(config: .dictation(.normal))
            var time = 0.0
            for _ in 0..<150 { _ = vad.process(level: ambient, at: time); time += 1.0 / 30 }
            let baseline = vad.speechAccumulated
            for _ in 0..<60 { _ = vad.process(level: 0.006, at: time); time += 1.0 / 30 }
            return vad.speechAccumulated - baseline
        }

        XCTAssertGreaterThan(speechHeard(afterAmbient: 0.001), 1.0,
                             "In a quiet room, 0.006 is somebody talking")
        XCTAssertEqual(speechHeard(afterAmbient: 0.004), 0, accuracy: 0.001,
                       "In a noisy room, the same 0.006 is the room")
    }

    /// …but not all the way down. A floor converging toward zero would otherwise let
    /// any ratio be satisfied by noise in a genuinely silent room.
    func testDigitalSilenceNeverQualifiesHoweverLowTheFloorFalls() {
        var vad = VoiceActivityDetector(config: .dictation(.normal))
        var time = 0.0
        for _ in 0..<600 { _ = vad.process(level: 0, at: time); time += 1.0 / 30 }

        XCTAssertGreaterThanOrEqual(vad.speechThreshold, VADConfig.dictation(.normal).absoluteFloor)
        XCTAssertEqual(vad.speechAccumulated, 0, accuracy: 0.001)
    }

    func testConfigPresetsAreOrdered() {
        // Thought always tolerates at least as long a pause as Dictation.
        for s in VADSensitivity.allCases {
            XCTAssertGreaterThan(VADConfig.thought(s).silenceInterval,
                                 VADConfig.dictation(s).silenceInterval)
        }
    }

    func testThoughtSurvivesFiveSecondMidSpeechPauseButDictationStops() {
        // Speech, then a ~5s mid-utterance pause (never reaching Thought's 5.0s
        // silenceInterval before speech resumes), then speech continues.
        var seq = samples(level: 0.6, from: 0, to: 1.0)
        seq += samples(level: 0.0, from: 1.05, to: 5.95)   // gap from last speech tops out at 4.95s
        seq += samples(level: 0.6, from: 6.0, to: 7.0)

        var thought = VoiceActivityDetector(config: .thought(.normal))
        XCTAssertNil(firstStop(&thought, seq), "Thought must ride out a 5s mid-speech pause without auto-stopping")

        var dictation = VoiceActivityDetector(config: .dictation(.normal))
        XCTAssertNotNil(firstStop(&dictation, seq), "Dictation (normal) auto-stops well before a 5s pause ends")
    }
}
