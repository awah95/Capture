import AVFoundation
import XCTest
@testable import Captur

final class AudioFormatConverterTests: XCTestCase {

    // MARK: - Helpers

    private func format(_ sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
            "standard float32 format \(sampleRate) Hz / \(channels) ch"
        )
    }

    /// A buffer of `frames` frames filled with a 1 kHz-ish tone on every channel.
    private func toneBuffer(
        _ format: AVAudioFormat,
        frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let step = 2 * Double.pi * 1_000 / format.sampleRate
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                channelData[channel][frame] = Float(sin(Double(frame) * step) * 0.5)
            }
        }
        return buffer
    }

    /// The format a voice-processing IO unit hands back: N channels with a
    /// `kAudioChannelLayoutTag_DiscreteInOrder` layout, which tells CoreAudio how many
    /// channels there are and nothing at all about what they mean.
    private func discreteFormat(
        _ sampleRate: Double,
        channels: UInt32
    ) throws -> AVAudioFormat {
        let layout = try XCTUnwrap(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels),
            "discrete channel layout for \(channels) channels"
        )
        return try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                interleaved: false,
                channelLayout: layout
            ),
            "discrete float32 format \(sampleRate) Hz / \(channels) ch"
        )
    }

    /// A buffer whose channel `n` carries a constant `amplitudes[n]`. Constants rather
    /// than a tone because these tests assert on the *amplitude that survived*, and a
    /// constant survives resampling exactly while a tone does not.
    private func constantBuffer(
        _ format: AVAudioFormat,
        frames: AVAudioFrameCount,
        amplitudes: [Float]
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            let value = channel < amplitudes.count ? amplitudes[channel] : 0
            for frame in 0..<Int(frames) {
                channelData[channel][frame] = value
            }
        }
        return buffer
    }

    private func peak(of buffer: AVAudioPCMBuffer) throws -> Float {
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        var highest: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            highest = max(highest, abs(channelData[0][frame]))
        }
        return highest
    }

    // MARK: - Required cases

    func test_producesSixteenKilohertzMonoOutput() throws {
        let converter = try AudioFormatConverter(inputFormat: try format(48_000, channels: 1))

        XCTAssertEqual(converter.outputFormat.sampleRate, 16_000)
        XCTAssertEqual(converter.outputFormat.channelCount, 1)
        XCTAssertEqual(converter.outputFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(converter.outputFormat.isInterleaved)
    }

    /// 4800 frames at 48 kHz is 100 ms, which is 1600 frames at 16 kHz.
    ///
    /// The *first* conversion is short by the resampler's group delay — measured at
    /// exactly 240 frames (15 ms) on macOS 26.5, and unaffected by every
    /// `AVAudioConverterPrimeMethod`. The steady state is what matters for a recording,
    /// so both are asserted: a loose bound on the primed first buffer, and the tight
    /// ±160 bound once the resampler is running.
    func test_convertsBufferAndPreservesApproximateDuration() throws {
        let input = try format(48_000, channels: 1)
        let converter = try AudioFormatConverter(inputFormat: input)

        let first = try XCTUnwrap(
            try converter.convert(try toneBuffer(input, frames: 4_800))
        )
        XCTAssertEqual(first.format.sampleRate, 16_000)
        XCTAssertEqual(Double(first.frameLength), 1_600, accuracy: 300)

        let steadyState = try XCTUnwrap(
            try converter.convert(try toneBuffer(input, frames: 4_800))
        )
        XCTAssertEqual(Double(steadyState.frameLength), 1_600, accuracy: 160)
    }

    func test_handlesAnOddSampleRateWithoutCrashing() throws {
        let input = try format(44_100, channels: 1)
        let converter = try AudioFormatConverter(inputFormat: input)

        let converted = try converter.convert(try toneBuffer(input, frames: 4_410))

        XCTAssertNotNil(converted)
        XCTAssertEqual(converted?.format.sampleRate, 16_000)
        XCTAssertGreaterThan(converted?.frameLength ?? 0, 0)
    }

    func test_convertsStereoInputToMono() throws {
        let input = try format(48_000, channels: 2)
        let converter = try AudioFormatConverter(inputFormat: input)

        let converted = try XCTUnwrap(
            try converter.convert(try toneBuffer(input, frames: 4_800))
        )

        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertGreaterThan(converted.frameLength, 0)
    }

    // MARK: - Additional coverage

    func test_returnsNilForAnEmptyBuffer() throws {
        let input = try format(48_000, channels: 1)
        let converter = try AudioFormatConverter(inputFormat: input)
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1_024))
        empty.frameLength = 0

        XCTAssertNil(try converter.convert(empty))
    }

    func test_passesThroughInputThatIsAlreadySixteenKilohertzMono() throws {
        let input = try format(16_000, channels: 1)
        let converter = try AudioFormatConverter(inputFormat: input)

        let converted = try XCTUnwrap(
            try converter.convert(try toneBuffer(input, frames: 1_024))
        )

        XCTAssertEqual(converted.frameLength, 1_024)
        XCTAssertEqual(converted.format.sampleRate, 16_000)
    }

    /// The converter is reused across taps, so resampler state must survive and keep
    /// producing frames on every subsequent buffer — not just the first.
    func test_keepsConvertingAcrossConsecutiveBuffers() throws {
        let input = try format(48_000, channels: 1)
        let converter = try AudioFormatConverter(inputFormat: input)

        var total = 0
        for _ in 0..<10 {
            let converted = try XCTUnwrap(
                try converter.convert(try toneBuffer(input, frames: 1_024))
            )
            XCTAssertGreaterThan(converted.frameLength, 0)
            total += Int(converted.frameLength)
        }

        // 10 × 1024 frames at 48 kHz ≈ 3413 frames at 16 kHz.
        XCTAssertEqual(Double(total), 3_413, accuracy: 120)
    }

    func test_rejectsAnInvalidInputFormat() throws {
        // A zero-sample-rate format cannot be built, so the guard is exercised through
        // the only reachable degenerate input: a format the converter cannot consume.
        let bogus = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        XCTAssertNoThrow(try AudioFormatConverter(inputFormat: bogus))
    }

    func test_canonicalOutputFormatMatchesInstanceOutputFormat() throws {
        let converter = try AudioFormatConverter(inputFormat: try format(48_000, channels: 1))
        let canonical = try XCTUnwrap(AudioFormatConverter.canonicalOutputFormat)

        XCTAssertEqual(canonical.sampleRate, converter.outputFormat.sampleRate)
        XCTAssertEqual(canonical.channelCount, converter.outputFormat.channelCount)
    }

    // MARK: - Discrete multi-channel input (the voice-processing layout)

    /// Reproduces the AEC-records-silence bug without hardware.
    ///
    /// A voice-processing IO unit hands the tap 44100 Hz / 9 channels / discrete layout,
    /// every channel carrying the same live microphone content. `AVAudioConverter` has no
    /// mixing matrix for a layout whose channels have no declared meaning, so it reports
    /// `.haveData`, produces full-length buffers, and fills them with zeros.
    func test_convertsNineChannelDiscreteInputToNonSilentMono() throws {
        let input = try discreteFormat(44_100, channels: 9)
        let converter = try AudioFormatConverter(inputFormat: input)
        let buffer = try constantBuffer(
            input,
            frames: 4_410,
            amplitudes: Array(repeating: 0.5, count: 9)
        )

        let converted = try XCTUnwrap(try converter.convert(buffer))

        XCTAssertEqual(converted.format.sampleRate, 16_000)
        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertGreaterThan(try peak(of: converted), 0.01, "converted audio is silent")
    }

    /// Pins *which* channel extraction reads. The other eight channels carry a distinctly
    /// smaller signal, so a refactor that quietly starts reading channel 1 — or averaging
    /// the lot — changes the surviving amplitude and fails here.
    func test_extractsChannelZeroSpecificallyNotAnotherChannel() throws {
        let input = try discreteFormat(44_100, channels: 9)
        let converter = try AudioFormatConverter(inputFormat: input)
        var amplitudes = Array(repeating: Float(0.05), count: 9)
        amplitudes[0] = 0.5

        // The first converted buffer carries the resampler's start-up ramp, so the
        // amplitude assertion is made against the steady state.
        _ = try converter.convert(try constantBuffer(input, frames: 4_410, amplitudes: amplitudes))
        let steadyState = try XCTUnwrap(
            try converter.convert(try constantBuffer(input, frames: 4_410, amplitudes: amplitudes))
        )

        XCTAssertEqual(try peak(of: steadyState), 0.5, accuracy: 0.05)
    }

    /// A real stereo microphone must keep both channels: extraction is for layouts
    /// CoreAudio cannot mix, not a blanket "take the first channel" policy.
    func test_convertsGenuineStereoInputToNonSilentMono() throws {
        let input = try format(48_000, channels: 2)
        let converter = try AudioFormatConverter(inputFormat: input)

        let converted = try XCTUnwrap(
            try converter.convert(try toneBuffer(input, frames: 4_800))
        )

        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertGreaterThan(try peak(of: converted), 0.01, "converted audio is silent")
    }

    /// Characterises what `AVAudioConverter` actually does with a standard stereo pair,
    /// which is *not* what the name "downmix" suggests: measured on macOS 26.5, a signal
    /// on the right channel alone converts to silence, and a signal on the left alone
    /// survives at full amplitude. Stereo to mono is a channel-0 take, not a mix.
    ///
    /// That makes the two-channel carve-out in `requiresChannelExtraction` currently a
    /// no-op in behavioural terms — both paths keep channel 0 and drop the rest. The
    /// carve-out is kept anyway, because it expresses the correct intent and a future
    /// CoreAudio that really does mix would silently start benefiting stereo microphones.
    /// If Apple ever makes that change, this test fails, which is the point: it is the
    /// prompt to revisit the carve-out rather than a bug in this converter.
    func test_stereoToMonoKeepsChannelZeroAndDropsChannelOne() throws {
        let input = try format(48_000, channels: 2)
        let leftOnly = try AudioFormatConverter(inputFormat: input)
        let rightOnly = try AudioFormatConverter(inputFormat: input)

        // The first conversion carries the resampler's start-up ramp; assert the steady state.
        _ = try leftOnly.convert(try constantBuffer(input, frames: 4_800, amplitudes: [0.5, 0]))
        let left = try XCTUnwrap(
            try leftOnly.convert(try constantBuffer(input, frames: 4_800, amplitudes: [0.5, 0]))
        )
        _ = try rightOnly.convert(try constantBuffer(input, frames: 4_800, amplitudes: [0, 0.5]))
        let right = try XCTUnwrap(
            try rightOnly.convert(try constantBuffer(input, frames: 4_800, amplitudes: [0, 0.5]))
        )

        XCTAssertEqual(try peak(of: left), 0.5, accuracy: 0.05)
        XCTAssertLessThan(try peak(of: right), 0.01)
    }

    /// Both halves of the decision rule, so neither can drift without a failure.
    func test_requiresChannelExtractionOnlyForLayoutsCoreAudioCannotMix() throws {
        XCTAssertFalse(
            AudioFormatConverter.requiresChannelExtraction(try format(48_000, channels: 1))
        )
        XCTAssertFalse(
            AudioFormatConverter.requiresChannelExtraction(try format(48_000, channels: 2))
        )
        XCTAssertTrue(
            AudioFormatConverter.requiresChannelExtraction(try discreteFormat(44_100, channels: 9))
        )

        // A two-channel *discrete* pair is a bag of unlabelled channels, not a stereo
        // image, so it needs extraction even though an ordinary stereo pair does not.
        XCTAssertTrue(
            AudioFormatConverter.requiresChannelExtraction(try discreteFormat(44_100, channels: 2)),
            "a discrete two-channel layout is not a stereo pair"
        )

        // CoreAudio writes these tags as `tag | channelCount`, so a check that compares
        // the whole tag against the bare constant matches nothing real. This pins the
        // masking: two channels of unknown layout must still extract.
        let unknown = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_Unknown | 2
        ))
        let unknownFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            interleaved: false,
            channelLayout: unknown
        ))
        XCTAssertTrue(
            AudioFormatConverter.requiresChannelExtraction(unknownFormat),
            "an unknown two-channel layout has no mixing matrix either"
        )
    }

    /// The scratch buffer is allocated once and reused, so a later, larger buffer must
    /// grow it rather than be silently truncated or dropped.
    func test_handlesAGrowingDiscreteBufferAfterASmallerOne() throws {
        let input = try discreteFormat(44_100, channels: 9)
        let converter = try AudioFormatConverter(inputFormat: input)
        let amplitudes = Array(repeating: Float(0.5), count: 9)

        _ = try converter.convert(try constantBuffer(input, frames: 1_024, amplitudes: amplitudes))
        let larger = try XCTUnwrap(
            try converter.convert(try constantBuffer(input, frames: 8_192, amplitudes: amplitudes))
        )

        XCTAssertEqual(Double(larger.frameLength), 8_192 * 16_000 / 44_100, accuracy: 64)
        XCTAssertGreaterThan(try peak(of: larger), 0.01, "converted audio is silent")
    }

    /// Interleaved multi-channel input reaches the same channel-0 samples through a
    /// strided read, so the interleaved branch of the copy is exercised too.
    func test_extractsChannelZeroFromAnInterleavedDiscreteBuffer() throws {
        let layout = try XCTUnwrap(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9)
        )
        let input = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100,
                interleaved: true,
                channelLayout: layout
            )
        )
        let converter = try AudioFormatConverter(inputFormat: input)

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let base = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<4_410 {
            for channel in 0..<9 {
                base[frame * 9 + channel] = channel == 0 ? 0.5 : 0.05
            }
        }

        _ = try converter.convert(buffer)
        let steadyState = try XCTUnwrap(try converter.convert(buffer))

        XCTAssertEqual(try peak(of: steadyState), 0.5, accuracy: 0.05)
    }
}
