import AVFoundation
import Foundation

/// Converts hardware capture buffers to the canonical 16 kHz mono float32 format.
///
/// The conversion happens here, inside the tap callback, and **never** by asking
/// AVAudioEngine to negotiate it. Wiring a mixer into the render graph to do the same
/// job is what silently produced zero frames on a voice-processing IO unit.
///
/// One instance per capture session: `AVAudioConverter` carries resampler state, so
/// reusing it across buffers is what keeps consecutive taps continuous.
///
/// Some hardware configurations hand over a channel layout `AVAudioConverter` cannot mix
/// — most notably a voice-processing IO unit, which reports 44100 Hz / 9 channels tagged
/// `kAudioChannelLayoutTag_DiscreteInOrder`. Asked to downmix that, the converter returns
/// `.haveData` and full-length buffers of pure zeros: no error, just silence. Handling
/// that belongs here, because this type's contract is "turn whatever the hardware hands
/// us into 16 kHz mono" — not at the call site, which should not have to know what a
/// channel layout tag is.
final class AudioFormatConverter {
    /// Whisper-class transcription wants 16 kHz mono; everything downstream assumes it.
    static let targetSampleRate: Double = 16_000

    /// The format every converter instance produces. Exposed so callers that need to
    /// open a file before the first buffer arrives (the FLAC writer) do not have to
    /// guess it.
    static let canonicalOutputFormat: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )

    let outputFormat: AVAudioFormat

    private let converter: AVAudioConverter
    private let rateRatio: Double

    /// The single-channel format channel 0 is copied into before conversion, at the
    /// source's own sample rate. Nil when the source needs no extraction.
    private let extractionFormat: AVAudioFormat?

    /// Reused across every callback. Conversion runs per buffer on the audio queue, where
    /// an allocation is a latency risk, so the scratch buffer is allocated once and only
    /// reallocated if a larger buffer ever arrives.
    private var scratch: AVAudioPCMBuffer?

    /// Whether channel 0 must be pulled out of the source buffer before conversion,
    /// because `AVAudioConverter` cannot meaningfully mix the source's channel layout.
    ///
    /// The rule is about *meaning*, not channel count. When CoreAudio knows what the
    /// channels are — mono, or a standard stereo pair — it is left to handle them, so a
    /// real stereo microphone keeps whatever its own conversion decides to keep. When it
    /// does not know what they mean, asking it to mix them is not a meaningful request:
    /// a discrete layout is a bag of unlabelled channels, and CoreAudio answers with
    /// silence rather than an error. And on a genuine multi-channel audio interface,
    /// taking input 1 is more correct than averaging one live microphone with several
    /// dead inputs.
    ///
    /// Measured caveat on the standard-stereo carve-out: `AVAudioConverter` does not in
    /// fact mix a stereo pair, it takes channel 0 and drops channel 1 — see
    /// `test_stereoToMonoKeepsChannelZeroAndDropsChannelOne`. The carve-out is therefore
    /// a no-op today and is kept for intent, not for effect.
    static func requiresChannelExtraction(_ format: AVAudioFormat) -> Bool {
        // Extraction reads samples through `floatChannelData`, so a non-float source
        // cannot take this path at all. No tap format in practice is anything else, and
        // letting `AVAudioConverter` try is strictly better than refusing to convert.
        guard format.commonFormat == .pcmFormatFloat32 else { return false }
        guard format.channelCount > 1 else { return false }
        guard format.channelCount == 2 else { return true }

        // Exactly two channels: an absent layout means an ordinary stereo pair.
        guard let layout = format.channelLayout else { return false }

        // Both tags carry the channel count in their low 16 bits — CoreAudio writes them
        // as `kAudioChannelLayoutTag_DiscreteInOrder | channelCount`. Comparing the whole
        // tag would therefore only ever match a zero-channel layout, so both checks mask
        // the count off first.
        let tag = layout.layoutTag & 0xFFFF_0000
        return tag == kAudioChannelLayoutTag_DiscreteInOrder || tag == kAudioChannelLayoutTag_Unknown
    }

    init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioEngineError.engineStartFailed(
                "The input format is unusable (\(inputFormat.sampleRate) Hz, "
                    + "\(inputFormat.channelCount) ch)."
            )
        }
        guard let output = Self.canonicalOutputFormat else {
            throw AudioEngineError.engineStartFailed(
                "Could not build the 16 kHz mono capture format."
            )
        }
        // When channel 0 is going to be extracted, the converter's source is that mono
        // channel at the hardware rate — not the layout the hardware reported. Building it
        // from the multi-channel format instead is what silently produced zeros.
        let extraction: AVAudioFormat?
        if Self.requiresChannelExtraction(inputFormat) {
            guard let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw AudioEngineError.engineStartFailed(
                    "Could not build a \(Int(inputFormat.sampleRate)) Hz mono extraction format."
                )
            }
            extraction = mono
        } else {
            extraction = nil
        }

        let converterSource = extraction ?? inputFormat
        guard let converter = AVAudioConverter(from: converterSource, to: output) else {
            throw AudioEngineError.engineStartFailed(
                "No converter exists from \(converterSource) to 16 kHz mono."
            )
        }

        outputFormat = output
        extractionFormat = extraction
        self.converter = converter
        rateRatio = Self.targetSampleRate / inputFormat.sampleRate
    }

    /// Converts one capture buffer. Returns nil for an empty input or when the
    /// converter produced no frames yet (a resampler may need priming).
    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }

        let source: AVAudioPCMBuffer
        if extractionFormat == nil {
            source = buffer
        } else if let extracted = channelZero(of: buffer) {
            source = extracted
        } else {
            return nil
        }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * rateRatio) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw AudioEngineError.engineStartFailed(
                "Could not allocate a \(capacity) frame conversion buffer."
            )
        }

        // Standard single-shot input block: hand the converter this buffer exactly
        // once, then report starvation so it flushes what it has instead of blocking.
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }

        if let conversionError { throw conversionError }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return output.frameLength > 0 ? output : nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Copies channel 0 of `buffer` into the reusable mono scratch buffer.
    ///
    /// Channel 0 is the microphone on the layouts this path exists for: the
    /// voice-processing unit duplicates the mic across all nine of its discrete channels,
    /// and on a multi-channel interface channel 0 is input 1.
    private func channelZero(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let extractionFormat,
              let source = buffer.floatChannelData?[0] else { return nil }

        let frames = buffer.frameLength
        let destinationBuffer: AVAudioPCMBuffer
        if let scratch, scratch.frameCapacity >= frames {
            destinationBuffer = scratch
        } else {
            guard let grown = AVAudioPCMBuffer(
                pcmFormat: extractionFormat,
                frameCapacity: frames
            ) else { return nil }
            scratch = grown
            destinationBuffer = grown
        }

        guard let destination = destinationBuffer.floatChannelData?[0] else { return nil }

        let frameCount = Int(frames)
        if buffer.format.isInterleaved {
            // One block, samples strided by the channel count; channel 0 is every
            // `stride`-th sample from the start.
            let stride = Int(buffer.format.channelCount)
            for frame in 0..<frameCount {
                destination[frame] = source[frame * stride]
            }
        } else {
            // Deinterleaved: channel 0 is already its own contiguous block.
            destination.update(from: source, count: frameCount)
        }

        destinationBuffer.frameLength = frames
        return destinationBuffer
    }
}
