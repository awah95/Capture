import AVFoundation
import XCTest
@testable import Captur

/// The latency model and the FLAC bit-depth fix.
///
/// The migration cases here are load-bearing. `DictationRecordLog.decodeRecords` drops any
/// line it cannot decode, so a `Timings` that failed to read an old record would silently
/// erase the user's dictation history from History and from every statistic over it.
final class LatencyTimingsTests: XCTestCase {

    // MARK: - Backward compatibility

    /// Exactly what a record written before 2026-07-27 carries: no `armingMs`, no
    /// `finalizeMs`.
    private let legacyTimings = Data("""
    {"captureMs":6900,"convertMs":0,"uploadMs":0,"whisperMs":524,
     "llmMs":564,"insertMs":328,"totalMs":2175}
    """.utf8)

    func testTimingsWithoutTheNewFieldsStillDecode() throws {
        let timings = try JSONDecoder().decode(Timings.self, from: legacyTimings)
        XCTAssertEqual(timings.whisperMs, 524)
        XCTAssertEqual(timings.armingMs, 0, "absent, not a decode failure")
        XCTAssertEqual(timings.finalizeMs, 0)
    }

    /// The consequence test. A whole record must survive, because the alternative is that
    /// it vanishes from the app without an error.
    func testAWholeLegacyRecordStillDecodes() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","startedAt":1785057543,"speakingDuration":6.9,
         "rawText":"hello","finalText":"Hello.","modeID":"clean","wordCount":1,
         "rawWordCount":1,"segmentCount":1,
         "timings":{"captureMs":6900,"whisperMs":524,"llmMs":564,"insertMs":328,
                    "totalMs":2175},
         "insertionOutcome":"pastedViaKeyboard","retryCount":0,
         "editDistanceRawToFinal":0.1,"audioBytes":161000,"estimatedCostUSD":0.0001,
         "vocabularyTermsSent":38,"voiceProcessingActive":true,
         "outcome":{"inserted":{}}}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(DictationRecord.self, from: json)
        XCTAssertEqual(record.finalText, "Hello.")
        XCTAssertEqual(record.timings.armingMs, 0)
    }

    func testNewTimingsRoundTrip() throws {
        let timings = Timings(captureMs: 6900, armingMs: 421, finalizeMs: 290,
                              whisperMs: 524, llmMs: 564, insertMs: 28, totalMs: 2133)
        let data = try JSONEncoder().encode(timings)
        XCTAssertEqual(try JSONDecoder().decode(Timings.self, from: data), timings)
    }

    // MARK: - Perceived latency

    /// The definition the whole feature turns on: what the user waits through, and
    /// nothing else. Arming is excluded because it happens before they speak; the
    /// post-insert clipboard settle is excluded because the text is already visible.
    func testPerceivedLatencyIsTheSumOfTheStagesTheUserWaitsThrough() {
        let timings = Timings(captureMs: 6900, armingMs: 421, finalizeMs: 290,
                              whisperMs: 524, llmMs: 564, insertMs: 28, totalMs: 2133)
        XCTAssertEqual(timings.perceivedMs, 290 + 524 + 564 + 28)
    }

    func testPerceivedLatencyExcludesArming() {
        let withArming = Timings(armingMs: 500, finalizeMs: 100, whisperMs: 200, insertMs: 10)
        let without = Timings(armingMs: 0, finalizeMs: 100, whisperMs: 200, insertMs: 10)
        XCTAssertEqual(withArming.perceivedMs, without.perceivedMs)
    }

    /// A record with no stage data reports nil, not a plausible-looking zero.
    func testAnUninstrumentedRecordHasNoPerceivedFigure() {
        XCTAssertNil(Timings(captureMs: 5000, totalMs: 6000).perceivedMs)
        XCTAssertFalse(Timings(captureMs: 5000, totalMs: 6000).hasStageBreakdown)
    }

    func testAnInstrumentedRecordIsRecognised() {
        XCTAssertTrue(Timings(armingMs: 400).hasStageBreakdown)
        XCTAssertTrue(Timings(finalizeMs: 200).hasStageBreakdown)
    }

    /// Old records must not drag the percentiles: they cannot be decomposed, and counting
    /// them as zero would report a latency nothing ever measured.
    func testUninstrumentedRecordsAreExcludedFromLatencyPercentiles() {
        let instrumented = record(mode: "verbatim",
                                  timings: Timings(armingMs: 400, finalizeMs: 100,
                                                   whisperMs: 500, insertMs: 20))
        let legacy = record(mode: "verbatim", timings: Timings(captureMs: 5000, totalMs: 9000))

        let summary = HealthAggregator.summarize(sessions: [], records: [instrumented, legacy])

        XCTAssertEqual(summary.latencySampleCount, 1)
        XCTAssertEqual(summary.perceivedP50Ms, 620)
    }

    func testLatencyIsSplitByModeBecauseTheBudgetsDiffer() {
        let verbatim = record(mode: "verbatim",
                              timings: Timings(armingMs: 400, finalizeMs: 100,
                                               whisperMs: 500, insertMs: 20))
        let clean = record(mode: "clean",
                           timings: Timings(armingMs: 400, finalizeMs: 100, whisperMs: 500,
                                            llmMs: 600, insertMs: 20))

        let summary = HealthAggregator.summarize(sessions: [], records: [verbatim, clean])

        XCTAssertEqual(summary.verbatimP50Ms, 620)
        XCTAssertEqual(summary.cleanP50Ms, 1220)
    }

    /// Arming is reported but marked as not part of the wait — the one stage that is felt
    /// without being waited through.
    func testArmingIsReportedButNotOnThePerceivedPath() {
        let summary = HealthAggregator.summarize(
            sessions: [],
            records: [record(mode: "verbatim",
                             timings: Timings(armingMs: 421, finalizeMs: 100,
                                              whisperMs: 500, insertMs: 20))])
        let arming = summary.stages.first { $0.name == "Arming" }
        XCTAssertEqual(arming?.p50Ms, 421)
        XCTAssertEqual(arming?.isOnPerceivedPath, false)
    }

    private func record(mode: String, timings: Timings) -> DictationRecord {
        DictationRecord(id: UUID(), startedAt: Date(), speakingDuration: 5,
                        rawText: "a", finalText: "a", modeID: mode,
                        targetBundleID: nil, targetAppName: nil,
                        wordCount: 1, rawWordCount: 1, segmentCount: 1,
                        timings: timings, insertionOutcome: "insertedDirect",
                        retryCount: 0, editDistanceRawToFinal: 0,
                        audioFileName: nil, audioBytes: 0, estimatedCostUSD: 0,
                        vocabularyTermsSent: 0, voiceProcessingActive: true,
                        outcome: .inserted)
    }

    // MARK: - The FLAC bit-depth fix

    /// The bug: `AVLinearPCMBitDepthKey: 16` was set and silently ignored, because
    /// CoreAudio derives the encoder's source depth from the file's processing format.
    /// Every capture was written at 24-bit and uploaded to Groq at twice the necessary
    /// size.
    func testCapturesAreWrittenAtSixteenBits() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-depth-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16000, channels: 1, interleaved: false)!
        let writer = try FLACWriter(url: url, format: format)
        let buffer = tone(format: format, frames: 16000)
        onAudioQueue { writer.write(buffer) }
        onAudioQueue { writer.finish() }

        let read = try AVAudioFile(forReading: url)
        // `mBitsPerChannel` is 0 for any COMPRESSED format — asserting on it would pass
        // for 16-bit, 24-bit and a corrupt file alike. FLAC carries its source depth in
        // `mFormatFlags`, using the Apple Lossless source-depth values: 1 = 16-bit,
        // 3 = 24-bit. Measured on both files before this assertion was written.
        let flags = read.fileFormat.streamDescription.pointee.mFormatFlags
        XCTAssertEqual(flags, 1,
                       "expected a 16-bit source (flag 1); flag 3 is the 24-bit bug. "
                           + "Format reads: \(read.fileFormat)")
    }

    /// The point of the fix is the byte count, so assert on it rather than only on the
    /// header field.
    func testSixteenBitCapturesAreSubstantiallySmallerThanTwentyFour() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16000, channels: 1, interleaved: false)!
        let fixed = directory.appendingPathComponent("fixed.flac")
        let writer = try FLACWriter(url: fixed, format: format)
        let buffer = tone(format: format, frames: 16000)
        onAudioQueue { writer.write(buffer) }
        onAudioQueue { writer.finish() }

        // The old behaviour, reproduced exactly: float32 processing format.
        let old = directory.appendingPathComponent("old.flac")
        var oldFile: AVAudioFile? = try AVAudioFile(
            forWriting: old,
            settings: [AVFormatIDKey: Int(kAudioFormatFLAC),
                       AVSampleRateKey: 16000.0,
                       AVNumberOfChannelsKey: 1,
                       AVLinearPCMBitDepthKey: 16],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try oldFile?.write(from: tone(format: format, frames: 16000))
        oldFile = nil

        let fixedSize = try fileSize(fixed)
        let oldSize = try fileSize(old)
        XCTAssertLessThan(fixedSize, oldSize / 3 * 2,
                          "measured ~2x on real captures; anything under 2/3 proves the fix")
    }

    /// Padding runs when a capture is too short for one encoder packet. It writes into the
    /// file's format, which is now Int16 — handing it a float32 buffer would throw and
    /// leave an unreadable stub, which is the bug padding exists to prevent.
    func testAShortCaptureIsStillReadableAfterPadding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-short-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16000, channels: 1, interleaved: false)!
        let writer = try FLACWriter(url: url, format: format)
        let short = tone(format: format, frames: 1000)     // well under 4,608
        onAudioQueue { writer.write(short) }
        onAudioQueue { writer.finish() }

        XCTAssertNoThrow(try AVAudioFile(forReading: url))
        XCTAssertEqual(writer.frameCount, 1000, "padding must not inflate the honest count")
    }

    /// Samples beyond full scale must clamp. Wrapping would turn the loudest moment of a
    /// dictation into a click.
    func testSamplesBeyondFullScaleClampRatherThanWrap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-clip-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = 8000
        for index in 0..<8000 {
            buffer.floatChannelData![0][index] = index.isMultiple(of: 2) ? 4.0 : -4.0
        }

        let writer = try FLACWriter(url: url, format: format)
        onAudioQueue { writer.write(buffer) }
        onAudioQueue { writer.finish() }

        let read = try AVAudioFile(forReading: url)
        let out = AVAudioPCMBuffer(pcmFormat: read.processingFormat,
                                   frameCapacity: AVAudioFrameCount(read.length))!
        try read.read(into: out)
        // Every sample should sit at the rail, with the sign it went in with.
        let channel = out.floatChannelData![0]
        XCTAssertGreaterThan(channel[0], 0.9)
        XCTAssertLessThan(channel[1], -0.9)
    }

    /// `FLACWriter` is audio-queue confined and asserts in DEBUG when touched on main.
    /// Driving writes from the real queue is not ceremony: calling `write` on the main
    /// thread trips the assertion and takes the whole test process down, which is how
    /// these four tests first "failed" without appearing in the executed count at all.
    private func onAudioQueue(_ work: @escaping @Sendable () -> Void) {
        let done = expectation(description: "audio-queue work")
        AudioQueue.queue.async {
            work()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    private func tone(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.05) * 0.3)
        }
        return buffer
    }

    private func fileSize(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    }

    // MARK: - The instrument that was lying

    /// `--probe-latency` filtered its arguments on `.flac` alone, so a `.ogg` path
    /// silently vanished and the probe measured the newest saved capture instead — while
    /// printing that file's name as though it had been requested. That made an A/B of two
    /// encodings impossible to run and easy to misread.
    func testEveryUploadableExtensionIsRecognised() {
        let supported = Set(GroqClient.supportedAudioExtensions)
        XCTAssertTrue(supported.isSuperset(of: ["flac", "ogg", "wav", "mp3"]))
    }
}
