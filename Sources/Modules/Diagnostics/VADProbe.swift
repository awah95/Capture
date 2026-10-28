import AVFoundation
import Foundation

/// Replays a recorded FLAC through the **real** `VoiceActivityDetector` and prints
/// what it decides, second by second.
///
/// It exists because a recording that contained obvious speech — Groq transcribed it
/// as "Hello, how are you?" — was reported by the app as "No speech was heard". Two
/// explanations read identically in source: the audio never reached the detector, or
/// the detector was fed real speech and called it silence. Only replaying the file the
/// app itself saved separates them, and the file is the converted 16 kHz mono signal
/// the detector actually sees, so nothing is being approximated.
///
/// The dispatch verdict at the end is the same call `DictationPipeline` makes: a
/// segment whose speech duration is below `minimumSpeechToDispatch` is never sent to
/// Groq at all.
enum VADProbe {

    static func run(path: String, sensitivity: VADSensitivity = .normal) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let file = try? AVAudioFile(forReading: url) else {
            print("cannot open: \(url.path)")
            return
        }

        let format = file.processingFormat
        print("--- file ---")
        print("  \(url.lastPathComponent)")
        print("  \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(file.length) frames "
              + "(\(String(format: "%.2f", Double(file.length) / format.sampleRate)) s)")
        print("")

        // The engine hands the recorder ~64 ms of converted audio at a time. The exact
        // size shifts the RMS smoothing slightly and nothing else.
        let chunk: AVAudioFrameCount = 1024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }

        let config = VADConfig.dictation(sensitivity)
        var vad = VoiceActivityDetector(config: config)

        print("--- config (\(sensitivity.rawValue)) ---")
        print("  speechRatio \(config.speechRatio)×   absoluteFloor \(fmt(config.absoluteFloor))"
              + "   minSpeech \(config.minSpeech) s")
        print("")
        print("--- per second: level avg/peak, floor, threshold, speech frames ---")

        var frames: AVAudioFramePosition = 0
        var second = 0
        var levels: [Double] = []
        var speechChunks = 0
        var totalChunks = 0
        var globalPeak = 0.0

        while true {
            buffer.frameLength = 0
            guard (try? file.read(into: buffer, frameCount: chunk)) != nil,
                  buffer.frameLength > 0
            else { break }

            let level = bufferLevel(buffer)
            levels.append(level)
            globalPeak = max(globalPeak, level)
            totalChunks += 1

            let before = vad.speechAccumulated
            frames += AVAudioFramePosition(buffer.frameLength)
            let now = Double(frames) / format.sampleRate
            _ = vad.process(level: level, at: now)
            if vad.speechAccumulated > before { speechChunks += 1 }

            if Int(now) > second {
                report(second: second, levels: levels, vad: vad, config: config)
                levels.removeAll(keepingCapacity: true)
                second = Int(now)
            }
        }
        if !levels.isEmpty { report(second: second, levels: levels, vad: vad, config: config) }

        let planner = SegmentPlanner()
        let dispatches = planner.shouldDispatch(speechDuration: vad.speechAccumulated)

        print("")
        print("--- verdict ---")
        print("  peak level             \(fmt(globalPeak))")
        print("  final noise floor      \(fmt(vad.noiseFloor))")
        print("  speech threshold       \(fmt(vad.speechThreshold))")
        print("  chunks over threshold  \(speechChunks) / \(totalChunks)")
        print("  speechAccumulated      \(String(format: "%.2f", vad.speechAccumulated)) s")
        print("")
        print(dispatches
              ? "  DISPATCH — this audio would be sent to Groq."
              : "  DROPPED  — the app reports \"No speech was heard\" and never calls Groq.")
    }

    private static func report(second: Int,
                               levels: [Double],
                               vad: VoiceActivityDetector,
                               config: VADConfig) {
        guard !levels.isEmpty else { return }
        let avg = levels.reduce(0, +) / Double(levels.count)
        let peak = levels.max() ?? 0
        print("  t=\(second)s  avg \(fmt(avg))  peak \(fmt(peak))"
              + "  floor \(fmt(vad.noiseFloor))  thr \(fmt(vad.speechThreshold))"
              + "  speech \(String(format: "%.2f", vad.speechAccumulated))s")
    }

    /// The same arithmetic `SegmentRecorder.level(of:)` performs.
    private static func bufferLevel(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        return normalizedRMS(samples: UnsafeBufferPointer(start: channel,
                                                          count: Int(buffer.frameLength)))
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
