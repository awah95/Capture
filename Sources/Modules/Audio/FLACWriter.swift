import AVFoundation
import Foundation

/// Streams converted 16 kHz mono buffers into a FLAC file.
///
/// Lossless and roughly half the size of the equivalent WAV, so a capture can be
/// re-transcribed later without generational loss. Writes never throw: a mid-recording
/// disk error is recorded in `writeError` and the recording keeps running, because
/// losing the tail of a dictation is strictly worse than losing the file's last second.
///
/// Audio-queue confined — `write` asserts in DEBUG when called from the main thread.
final class FLACWriter {
    /// CoreAudio's FLAC encoder emits fixed 4608-frame packets. Measured on macOS 26.5:
    /// a file closed before the *first* complete packet exists is a 42-byte header stub
    /// that `AVAudioFile(forReading:)` refuses to open ('typ?'). A trailing partial
    /// packet flushes fine once at least one whole packet has been written. So any
    /// capture shorter than 288 ms at 16 kHz would otherwise land on disk unreadable;
    /// `finish()` pads such a file with silence rather than leave a corrupt one.
    static let encoderPacketFrames: AVAudioFrameCount = 4_608

    let url: URL

    private(set) var frameCount: AVAudioFramePosition = 0
    private(set) var writeError: Error?

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }

    private let sampleRate: Double
    private let format: AVAudioFormat
    private var file: AVAudioFile?

    /// The file's own processing format — `Int16`, not the `Float32` the tap delivers.
    /// Buffers are converted into this on the way in; see `init`.
    private var storageFormat: AVAudioFormat?
    /// Reused across writes so the audio queue does not allocate per buffer. Grown on
    /// demand; capture buffer sizes are stable in practice but not guaranteed.
    private var scratch: AVAudioPCMBuffer?

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        self.format = format
        sampleRate = format.sampleRate
        // `commonFormat` is the format buffers are HANDED TO the file in, and CoreAudio
        // derives the encoder's source depth from it — `AVLinearPCMBitDepthKey` alone does
        // not. With `.pcmFormatFloat32` here the key was silently ignored and every
        // capture was written as 24-bit: measured 2.00x larger than the same audio at
        // 16-bit, for a 16 kHz mono voice signal that carries nothing below the 16th bit.
        // Those bytes were paid for twice — once on disk, once on every upload to Groq.
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: Int(kAudioFormatFLAC),
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        self.file = file
        storageFormat = file.processingFormat
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        AudioQueue.assertNotMain("FLACWriter.write")
        guard writeError == nil, buffer.frameLength > 0, let file else { return }
        guard let converted = int16(from: buffer) else { return }
        do {
            try file.write(from: converted)
            frameCount += AVAudioFramePosition(buffer.frameLength)
        } catch {
            writeError = error
        }
    }

    /// Float32 → Int16, by hand.
    ///
    /// An `AVAudioConverter` would also do this, but it carries priming state and can
    /// return fewer frames than it was given, which on an audio queue turns a dropped
    /// sample into a silently shortened recording. Same rate, same channel count, no
    /// resampling: the whole operation is a clamp and a scale, so it is done directly
    /// where it can be read and tested.
    private func int16(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let storageFormat else { return nil }
        // Already Int16 (a caller that pre-converted): pass it straight through.
        if buffer.format.commonFormat == .pcmFormatInt16 { return buffer }
        guard let source = buffer.floatChannelData else { return nil }

        let frames = buffer.frameLength
        if scratch == nil || scratch!.frameCapacity < frames {
            scratch = AVAudioPCMBuffer(pcmFormat: storageFormat, frameCapacity: frames)
        }
        guard let scratch, let destination = scratch.int16ChannelData else { return nil }
        scratch.frameLength = frames

        // Clamped, not wrapped. A sample above 1.0 must land at full scale; letting it
        // overflow would turn the loudest moment of a dictation into a click.
        for index in 0..<Int(frames) {
            let sample = min(max(source[0][index], -1.0), 1.0)
            destination[0][index] = Int16(sample * 32767.0)
        }
        return scratch
    }

    /// Releases the underlying `AVAudioFile`, which flushes the encoder and finalizes
    /// the container. Idempotent; the file is also finalized if the writer is simply
    /// released.
    ///
    /// A capture too short to fill one encoder packet is padded with silence first, so
    /// the file on disk is always readable. `frameCount` keeps reporting the frames
    /// that were genuinely captured, so `duration` stays honest.
    func finish() {
        padToFirstPacketIfNeeded()
        file = nil
    }

    private func padToFirstPacketIfNeeded() {
        guard writeError == nil, let file,
              frameCount > 0, frameCount < AVAudioFramePosition(Self.encoderPacketFrames)
        else { return }

        let missing = AVAudioFrameCount(AVAudioFramePosition(Self.encoderPacketFrames) - frameCount)
        // Silence is written in the FILE's format, not the tap's — the file now processes
        // Int16, and handing it a Float32 buffer would throw rather than pad.
        guard let storageFormat,
              let silence = AVAudioPCMBuffer(pcmFormat: storageFormat, frameCapacity: missing)
        else { return }
        silence.frameLength = missing
        for channel in 0..<Int(storageFormat.channelCount) {
            silence.int16ChannelData?[channel].update(repeating: 0, count: Int(missing))
        }
        try? file.write(from: silence)
    }
}
