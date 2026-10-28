import AVFoundation
import XCTest
@testable import Captur

/// Proves that `kAudioFormatFLAC` really encodes on this machine: a file lands on disk,
/// is non-empty, reports the expected duration, and can be re-opened for reading.
final class FLACWriterTests: XCTestCase {

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-flac-\(UUID().uuidString).flac")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func captureFormat() throws -> AVAudioFormat {
        try XCTUnwrap(AudioFormatConverter.canonicalOutputFormat)
    }

    private func toneBuffer(
        _ format: AVAudioFormat,
        frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let step = 2 * Double.pi * 440 / format.sampleRate
        for frame in 0..<Int(frames) {
            channelData[0][frame] = Float(sin(Double(frame) * step) * 0.5)
        }
        return buffer
    }

    /// `FLACWriter` is audio-queue confined and asserts in DEBUG when touched on main,
    /// so every write in these tests is driven from the real audio queue.
    private func onAudioQueue(_ work: @escaping @Sendable () -> Void) {
        let done = expectation(description: "audio-queue work")
        AudioQueue.queue.async {
            work()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func test_writesARealNonEmptyFLACFileThatCanBeReopened() throws {
        let url = tempURL()
        let format = try captureFormat()

        var writer: FLACWriter? = try FLACWriter(url: url, format: format)
        let buffer = try toneBuffer(format, frames: 1_600)

        onAudioQueue { [writer] in
            for _ in 0..<10 { writer?.write(buffer) }
        }

        XCTAssertEqual(writer?.frameCount, 16_000)
        XCTAssertEqual(writer?.duration ?? 0, 1.0, accuracy: 0.001)
        XCTAssertNil(writer?.writeError)

        writer?.finish()
        writer = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        )
        XCTAssertGreaterThan(size, 0, "the FLAC container is not empty")

        let readBack = try AVAudioFile(forReading: url)
        XCTAssertEqual(readBack.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(readBack.fileFormat.channelCount, 1)
        XCTAssertEqual(readBack.length, 16_000)
        XCTAssertEqual(
            readBack.fileFormat.streamDescription.pointee.mFormatID,
            kAudioFormatFLAC,
            "the file really is FLAC, not a silently substituted codec"
        )
    }

    func test_reportsZeroDurationBeforeAnythingIsWritten() throws {
        let url = tempURL()
        let writer = try FLACWriter(url: url, format: try captureFormat())

        XCTAssertEqual(writer.frameCount, 0)
        XCTAssertEqual(writer.duration, 0)
        XCTAssertNil(writer.writeError)
        writer.finish()
    }

    func test_ignoresEmptyBuffersAndNeverThrows() throws {
        let url = tempURL()
        let format = try captureFormat()
        let writer = try FLACWriter(url: url, format: format)
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        empty.frameLength = 0

        onAudioQueue { writer.write(empty) }

        XCTAssertEqual(writer.frameCount, 0)
        XCTAssertNil(writer.writeError)
        writer.finish()
    }

    func test_writesAfterFinishAreDroppedRatherThanCrashing() throws {
        let url = tempURL()
        let format = try captureFormat()
        let writer = try FLACWriter(url: url, format: format)
        let buffer = try toneBuffer(format, frames: 6_000)

        onAudioQueue { writer.write(buffer) }
        writer.finish()
        onAudioQueue { writer.write(buffer) }

        XCTAssertEqual(writer.frameCount, 6_000, "post-finish writes do not extend the file")
        XCTAssertNil(writer.writeError)

        let readBack = try AVAudioFile(forReading: url)
        XCTAssertEqual(readBack.length, 6_000)
    }

    /// CoreAudio's FLAC encoder only emits its first packet at 4608 frames. Closing a
    /// shorter file leaves a 42-byte header stub that `AVAudioFile(forReading:)`
    /// refuses to open, so a very short capture would silently land on disk unreadable.
    /// `finish()` pads it, and the reported duration stays the captured duration.
    func test_padsACaptureShorterThanOneEncoderPacketSoTheFileStaysReadable() throws {
        let url = tempURL()
        let format = try captureFormat()
        let writer = try FLACWriter(url: url, format: format)
        let buffer = try toneBuffer(format, frames: 800)

        onAudioQueue { writer.write(buffer) }
        XCTAssertLessThan(writer.frameCount, AVAudioFramePosition(FLACWriter.encoderPacketFrames))
        writer.finish()

        XCTAssertEqual(writer.frameCount, 800, "the reported duration is the captured audio")
        XCTAssertEqual(writer.duration, 0.05, accuracy: 0.001)

        let readBack = try AVAudioFile(forReading: url)
        XCTAssertEqual(
            readBack.length,
            AVAudioFramePosition(FLACWriter.encoderPacketFrames),
            "the file is padded up to one whole encoder packet"
        )
    }

    func test_urlIsExposedForCallersThatOwnTheFile() throws {
        let url = tempURL()
        let writer = try FLACWriter(url: url, format: try captureFormat())
        XCTAssertEqual(writer.url, url)
        writer.finish()
    }
}
