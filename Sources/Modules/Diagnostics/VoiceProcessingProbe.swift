import AVFoundation
import Foundation

/// A throwaway-shaped but permanent instrument: it runs the voice-processing capture path
/// with **no** interpretation layer in between and prints what the hardware actually hands
/// over, channel by channel.
///
/// It exists because the dead-microphone bug was diagnosed wrongly twice by reading code,
/// and correctly once by measuring. The AEC-produces-silence bug is the same shape: with
/// `voiceProcessing: true` the tap is handed a 44100 Hz **9-channel** format and every
/// converted buffer is silent. Two hypotheses explain that equally well from the source —
///
///   H1  channel 0 of the 9-channel layout is not the microphone, so the converter is
///       faithfully downmixing silence
///   H2  channel 0 *is* the microphone, but `AVAudioConverter` cannot downmix a 9-channel
///       layout it has no channel map for, and emits silence
///
/// — and they need opposite fixes. This probe reports the **raw tap buffer** per channel
/// next to the **converted** buffer, which separates them in a single run.
///
/// Not part of the app's product surface: reachable only via `Captur --probe-vp`.
enum VoiceProcessingProbe {

    struct Experiment {
        let name: String
        let voiceProcessing: Bool
        /// When false the tap is installed with `format: nil` (the node's own format)
        /// rather than the format read back from the node.
        let tapWithObservedFormat: Bool
        /// Pull channel 0 into a single-channel buffer and convert *that*, instead of
        /// asking `AVAudioConverter` to downmix the multi-channel layout itself.
        var extractChannelZero: Bool = false
    }

    static let experiments: [Experiment] = [
        Experiment(name: "A · AEC off, tap observed format (known-good baseline)",
                   voiceProcessing: false, tapWithObservedFormat: true),
        Experiment(name: "B · AEC on, tap observed format (the failing configuration)",
                   voiceProcessing: true, tapWithObservedFormat: true),
        Experiment(name: "C · AEC on, tap format: nil",
                   voiceProcessing: true, tapWithObservedFormat: false),
        Experiment(name: "D · AEC on, channel 0 extracted to mono before conversion",
                   voiceProcessing: true, tapWithObservedFormat: true, extractChannelZero: true)
    ]

    static func run(seconds: Double) async {
        print("=== Captur voice-processing probe ===")
        print("Speak continuously for the whole run — every experiment needs real signal,")
        print("and a silent room makes every hypothesis look identical.")
        print("")

        for experiment in experiments {
            await runOne(experiment, seconds: seconds)
            print("")
        }

        print("=== how to read this ===")
        print("raw ch0 hot + converted silent   → the converter cannot downmix the layout (H2)")
        print("raw ch0 silent + some ch_n hot   → channel 0 is not the microphone (H1)")
        print("every raw channel silent         → the VP unit is delivering nothing at all")
    }

    private static func runOne(_ experiment: Experiment, seconds: Double) async {
        print("--- \(experiment.name) ---")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        var voiceProcessingActive = false
        if experiment.voiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingActive = inputNode.isVoiceProcessingEnabled
            } catch {
                print("  setVoiceProcessingEnabled(true) threw: \(error.localizedDescription)")
            }
        }

        let observedFormat = inputNode.outputFormat(forBus: 0)
        let inputFormat = inputNode.inputFormat(forBus: 0)
        print("  voiceProcessingEnabled: \(voiceProcessingActive)")
        print("  outputFormat(bus 0): \(describe(observedFormat))")
        print("  inputFormat(bus 0):  \(describe(inputFormat))")
        print("  channel layout: \(describeLayout(observedFormat))")

        guard observedFormat.sampleRate > 0, observedFormat.channelCount > 0 else {
            print("  UNUSABLE FORMAT — skipping")
            teardown(engine, inputNode, voiceProcessingActive)
            return
        }

        let stats = ChannelStats(channelCount: Int(observedFormat.channelCount))
        let convertedStats = ChannelStats(channelCount: 1)

        // Experiment D converts a single-channel buffer, so its converter must be built
        // from a mono source format at the hardware rate rather than the 9-channel one.
        let monoSourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: observedFormat.sampleRate,
                                             channels: 1,
                                             interleaved: false)
        let converterInput = experiment.extractChannelZero
            ? (monoSourceFormat ?? observedFormat)
            : observedFormat

        // The converter is built from the observed format exactly as the real engine
        // builds it, so a failure here is the app's failure and not the probe's.
        var converter: AudioFormatConverter?
        do {
            converter = try AudioFormatConverter(inputFormat: converterInput)
        } catch {
            print("  AudioFormatConverter init failed: \(error.localizedDescription)")
        }

        let structure = BufferStructure()
        let tapFormat: AVAudioFormat? = experiment.tapWithObservedFormat ? observedFormat : nil
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, _ in
            structure.recordOnce(buffer)
            stats.consume(buffer)
            guard let converter else { return }

            let source = experiment.extractChannelZero
                ? channelZero(of: buffer, as: monoSourceFormat)
                : buffer
            guard let source else {
                convertedStats.noteDroppedConversion()
                return
            }
            if let converted = try? converter.convert(source) {
                convertedStats.consume(converted)
            } else {
                convertedStats.noteDroppedConversion()
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            print("  engine.start() threw: \(error.localizedDescription)")
            teardown(engine, inputNode, voiceProcessingActive)
            return
        }

        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        inputNode.removeTap(onBus: 0)
        engine.stop()

        // Nine channels reporting byte-identical peak and RMS is either nine duplicated
        // channels or one channel read nine times through aliased pointers. Those mean
        // very different things, so the buffer's actual memory layout gets printed
        // rather than inferred.
        print("  \(structure.summary())")

        let raw = stats.snapshot()
        print("  raw buffers: \(raw.buffers)   frames: \(raw.frames)")
        if raw.buffers == 0 {
            print("  NO BUFFERS — the tap never fired")
        }
        for (index, channel) in raw.channels.enumerated() {
            let marker = channel.peak > 0.0005 ? "  ← SIGNAL" : ""
            print(String(format: "    ch%d  peak %.5f  rms %.5f%@",
                         index, channel.peak, channel.rms, marker))
        }

        let converted = convertedStats.snapshot()
        print("  converted buffers: \(converted.buffers)"
              + "  (dropped: \(convertedStats.droppedConversions))")
        if let mono = converted.channels.first {
            print(String(format: "    mono peak %.5f  rms %.5f", mono.peak, mono.rms))
        }

        teardown(engine, inputNode, voiceProcessingActive)
    }

    private static func teardown(_ engine: AVAudioEngine,
                                 _ inputNode: AVAudioInputNode,
                                 _ voiceProcessingActive: Bool) {
        if voiceProcessingActive {
            try? inputNode.setVoiceProcessingEnabled(false)
        }
        engine.stop()
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, "
            + "\(format.isInterleaved ? "interleaved" : "deinterleaved"), "
            + "commonFormat=\(format.commonFormat.rawValue)"
    }

    private static func describeLayout(_ format: AVAudioFormat) -> String {
        guard let layout = format.channelLayout else { return "(none)" }
        let tag = layout.layoutTag
        return String(format: "tag 0x%08X (%u channels)", tag, tag & 0xFFFF)
    }
}

/// Copies channel 0 of a multi-channel buffer into its own single-channel buffer, so the
/// converter is asked to resample one real channel instead of to downmix a layout it has
/// no mixing matrix for.
private func channelZero(of buffer: AVAudioPCMBuffer,
                         as format: AVAudioFormat?) -> AVAudioPCMBuffer? {
    guard let format,
          let source = buffer.floatChannelData?[0],
          let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
          let destination = output.floatChannelData?[0] else { return nil }

    let frames = Int(buffer.frameLength)
    if buffer.format.isInterleaved {
        let stride = Int(buffer.format.channelCount)
        for frame in 0..<frames { destination[frame] = source[frame * stride] }
    } else {
        destination.update(from: source, count: frames)
    }
    output.frameLength = buffer.frameLength
    return output
}

/// Records the memory layout of the first buffer seen: how many discrete buffers the
/// underlying `AudioBufferList` really carries, and whether the per-channel pointers
/// AVFoundation hands out are distinct addresses or aliases of one block.
private final class BufferStructure: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: String?

    func recordOnce(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard recorded == nil else { return }

        let list = buffer.audioBufferList.pointee
        let declaredChannels = Int(buffer.format.channelCount)
        var addresses: [UInt] = []
        if let data = buffer.floatChannelData {
            for channel in 0..<declaredChannels {
                addresses.append(UInt(bitPattern: data[channel]))
            }
        }
        let distinct = Set(addresses).count
        let firstBufferBytes = list.mBuffers.mDataByteSize
        recorded = "AudioBufferList: mNumberBuffers=\(list.mNumberBuffers)"
            + "  mBuffers[0].mNumberChannels=\(list.mBuffers.mNumberChannels)"
            + "  mDataByteSize=\(firstBufferBytes)"
            + "  distinct channel pointers=\(distinct)/\(declaredChannels)"
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return recorded ?? "AudioBufferList: (no buffer observed)"
    }
}

/// Per-channel peak and RMS over a whole run. Lock-guarded because tap callbacks arrive
/// on the audio thread and the summary is read from the main actor.
private final class ChannelStats: @unchecked Sendable {
    struct Channel { var peak: Double = 0; var rms: Double = 0 }
    struct Snapshot { let buffers: Int; let frames: Int; let channels: [Channel] }

    private let lock = NSLock()
    private let channelCount: Int
    private var buffers = 0
    private var frames = 0
    private var peaks: [Double]
    private var sumsOfSquares: [Double]
    private(set) var droppedConversions = 0

    init(channelCount: Int) {
        self.channelCount = channelCount
        peaks = Array(repeating: 0, count: channelCount)
        sumsOfSquares = Array(repeating: 0, count: channelCount)
    }

    func noteDroppedConversion() {
        lock.lock()
        droppedConversions += 1
        lock.unlock()
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let channels = min(channelCount, Int(buffer.format.channelCount))

        var localPeaks = Array(repeating: Double(0), count: channelCount)
        var localSquares = Array(repeating: Double(0), count: channelCount)

        if buffer.format.isInterleaved {
            // Interleaved float32: one block, samples strided by channel count.
            guard let base = buffer.floatChannelData?[0] else { return }
            let stride = Int(buffer.format.channelCount)
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let sample = Double(abs(base[frame * stride + channel]))
                    if sample > localPeaks[channel] { localPeaks[channel] = sample }
                    localSquares[channel] += sample * sample
                }
            }
        } else {
            guard let data = buffer.floatChannelData else { return }
            for channel in 0..<channels {
                let pointer = data[channel]
                for frame in 0..<frameCount {
                    let sample = Double(abs(pointer[frame]))
                    if sample > localPeaks[channel] { localPeaks[channel] = sample }
                    localSquares[channel] += sample * sample
                }
            }
        }

        lock.lock()
        buffers += 1
        frames += frameCount
        for channel in 0..<channelCount {
            peaks[channel] = max(peaks[channel], localPeaks[channel])
            sumsOfSquares[channel] += localSquares[channel]
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let channels = (0..<channelCount).map { index -> Channel in
            let rms = frames > 0 ? (sumsOfSquares[index] / Double(frames)).squareRoot() : 0
            return Channel(peak: peaks[index], rms: rms)
        }
        return Snapshot(buffers: buffers, frames: frames, channels: channels)
    }
}
