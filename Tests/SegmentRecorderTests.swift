import AVFoundation
import XCTest
@testable import Captur

/// Drives the recorder with synthetic 100 ms buffers so the whole segment lifecycle —
/// cuts, the dual writers, speech accounting, file cleanup — is deterministic.
///
/// Real `FLACWriter` instances against a real temporary directory: the CoreAudio FLAC
/// encoder's packet behaviour (a file closed before the first 4608-frame packet is an
/// unreadable stub) is exactly the sort of thing a fake writer would hide, and short
/// tail segments land in that window constantly.
final class SegmentRecorderTests: XCTestCase {

    private var directory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-recorder-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Fixtures

    /// 100 ms of 16 kHz mono float32: loud enough to read as speech, or pure silence.
    private func buffer(speech: Bool) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AudioFormatConverter.canonicalOutputFormat)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        let channel = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<1_600 {
            channel[0][frame] = speech ? 0.5 : 0
        }
        return buffer
    }

    private func makeRecorder(
        config: SegmentPlannerConfig = .default
    ) throws -> SegmentRecorder {
        let format = try XCTUnwrap(AudioFormatConverter.canonicalOutputFormat)
        return SegmentRecorder(
            directory: directory,
            planner: SegmentPlanner(config: config),
            makeVAD: { VoiceActivityDetector(config: .dictation(.normal)) },
            makeWriter: { try FLACWriter(url: $0, format: format) }
        )
    }

    /// `ingest` is audio-queue confined (it asserts in DEBUG when touched on main), so
    /// every buffer in these tests goes in from the real audio queue, exactly as the
    /// engine's tap would deliver it.
    private func feed(
        _ recorder: SegmentRecorder,
        speech: Bool,
        seconds: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let buffer = try buffer(speech: speech)
        let count = Int((seconds * 10).rounded())
        let done = expectation(description: "ingest \(count) buffers")
        AudioQueue.queue.async {
            for _ in 0..<count { recorder.ingest(buffer) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        drainMainQueue()
    }

    /// The segment-closed callback is delivered with `DispatchQueue.main.async`, and the
    /// main queue is FIFO, so a block enqueued afterwards runs only once every pending
    /// callback has. Waiting on it is a deterministic drain, not a sleep.
    private func drainMainQueue() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Segment lifecycle

    func test_shortRecordingProducesOneFinalSegmentAndADistinctSessionFile() throws {
        let recorder = try makeRecorder()
        try recorder.begin(captureID: UUID())
        try feed(recorder, speech: true, seconds: 5)

        let session = recorder.finish()

        XCTAssertEqual(session.segments.count, 1, "5 s of unbroken speech is never cut")
        let segment = try XCTUnwrap(session.segments.first)
        XCTAssertEqual(segment.index, 0)
        XCTAssertTrue(segment.isFinal)
        XCTAssertEqual(session.duration, 5.0, accuracy: 0.001)
        XCTAssertEqual(segment.duration, 5.0, accuracy: 0.001)

        XCTAssertNotEqual(
            session.url, segment.url,
            "the durable session file must not be the disposable segment file"
        )
        XCTAssertTrue(exists(session.url))
        XCTAssertTrue(exists(segment.url))
    }

    func test_cutsAtSilenceAfterTheMinimumAndKeepsRecording() throws {
        let recorder = try makeRecorder()
        var closed: [AudioSegment] = []
        recorder.onSegmentClosed = { closed.append($0) }
        try recorder.begin(captureID: UUID())

        try feed(recorder, speech: true, seconds: 10)
        XCTAssertTrue(closed.isEmpty, "no cut while speech is running")

        try feed(recorder, speech: false, seconds: 1)
        XCTAssertEqual(closed.count, 1, "a real pause with 8 s banked closes the segment")
        let first = try XCTUnwrap(closed.first)
        XCTAssertEqual(first.index, 0)
        XCTAssertFalse(first.isFinal, "the recording is still running")

        try feed(recorder, speech: true, seconds: 3)
        let session = recorder.finish()

        XCTAssertEqual(session.segments.map(\.index), [0, 1])
        XCTAssertTrue(try XCTUnwrap(session.segments.last).isFinal)
        XCTAssertFalse(try XCTUnwrap(session.segments.first).isFinal)
        XCTAssertEqual(closed.count, 1, "the tail is returned by finish(), not re-emitted")
    }

    func test_sessionFileSpansEverySegment() throws {
        let recorder = try makeRecorder()
        try recorder.begin(captureID: UUID())
        try feed(recorder, speech: true, seconds: 10)
        try feed(recorder, speech: false, seconds: 1)
        try feed(recorder, speech: true, seconds: 3)

        let session = recorder.finish()
        let segmentTotal = session.segments.reduce(0) { $0 + $1.duration }

        XCTAssertEqual(session.segments.count, 2)
        XCTAssertEqual(session.duration, 14.0, accuracy: 0.001, "every buffer fed, no more")
        XCTAssertEqual(
            segmentTotal, session.duration, accuracy: 0.001,
            "the segments tile the session with no gap and no overlap"
        )

        let readBack = try AVAudioFile(forReading: session.url)
        XCTAssertEqual(readBack.length, 224_000, "the session file really holds 14 s at 16 kHz")
    }

    func test_segmentUrlsAreAllDistinct() throws {
        let recorder = try makeRecorder()
        try recorder.begin(captureID: UUID())
        try feed(recorder, speech: true, seconds: 10)
        try feed(recorder, speech: false, seconds: 1)
        try feed(recorder, speech: true, seconds: 10)
        try feed(recorder, speech: false, seconds: 1)

        let session = recorder.finish()
        let urls = Set(session.segments.map(\.url))
        XCTAssertEqual(urls.count, session.segments.count)
        XCTAssertGreaterThanOrEqual(session.segments.count, 3)
        XCTAssertFalse(urls.contains(session.url))
    }

    // MARK: - Speech accounting

    func test_reportsSpeechDurationSoSilentTailsCanBeGated() throws {
        let recorder = try makeRecorder()
        try recorder.begin(captureID: UUID())
        try feed(recorder, speech: true, seconds: 10)
        try feed(recorder, speech: false, seconds: 2.5)

        let session = recorder.finish()

        XCTAssertEqual(session.segments.count, 2)
        let first = try XCTUnwrap(session.segments.first)
        XCTAssertGreaterThan(first.speechDuration, 5.0, "the spoken segment is worth sending")
        XCTAssertTrue(SegmentPlanner().shouldDispatch(speechDuration: first.speechDuration))

        let tail = try XCTUnwrap(session.segments.last)
        XCTAssertLessThan(
            tail.speechDuration, 0.3,
            "a silent tail must be gateable so Whisper cannot hallucinate on it"
        )
        XCTAssertFalse(SegmentPlanner().shouldDispatch(speechDuration: tail.speechDuration))
    }

    func test_precedingSilenceCarriesThePauseThatCausedTheCut() throws {
        let recorder = try makeRecorder()
        try recorder.begin(captureID: UUID())
        try feed(recorder, speech: true, seconds: 10)
        try feed(recorder, speech: false, seconds: 1.2)
        try feed(recorder, speech: true, seconds: 3)

        let session = recorder.finish()

        XCTAssertEqual(session.segments.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(session.segments.first).precedingSilence, 0, accuracy: 0.001,
            "nothing precedes the first segment"
        )
        // 1.2 s of silence went in; the detector smooths, so the first buffer or two
        // still read as speech. The stitcher only needs the pause to be recognisably
        // longer than the 0.6 s cut threshold.
        let second = try XCTUnwrap(session.segments.last)
        XCTAssertEqual(second.precedingSilence, 1.0, accuracy: 0.3)
        XCTAssertGreaterThanOrEqual(second.precedingSilence, 0.6)
    }

    /// The pause is only *carried* across the cut when speech resumes on the very next
    /// buffer — any silence after the cut re-derives it from the detector's own clock.
    /// So the silence is fed one buffer at a time and stopped the instant the cut fires,
    /// which pins the carry regardless of how long the detector's smoothing hangs over.
    func test_precedingSilenceSurvivesSpeechResumingImmediatelyAfterTheCut() throws {
        let recorder = try makeRecorder()
        var closed: [AudioSegment] = []
        recorder.onSegmentClosed = { closed.append($0) }
        try recorder.begin(captureID: UUID())
        try feed(recorder, speech: true, seconds: 10)

        var silenceFed = 0.0
        while closed.isEmpty && silenceFed < 4.0 {
            try feed(recorder, speech: false, seconds: 0.1)
            silenceFed += 0.1
        }
        XCTAssertEqual(closed.count, 1, "the cut fired inside the silence we fed")

        try feed(recorder, speech: true, seconds: 3)
        let session = recorder.finish()

        let second = try XCTUnwrap(session.segments.last)
        XCTAssertGreaterThanOrEqual(
            second.precedingSilence, 0.6,
            "the pause that caused the cut must reach the segment it precedes"
        )
        XCTAssertLessThanOrEqual(
            second.precedingSilence, silenceFed + 0.001,
            "and it cannot exceed the silence actually recorded"
        )
    }

    // MARK: - Files on disk

    func test_everySegmentFileIsAReadableFLACIncludingAShortTail() throws {
        let recorder = try makeRecorder()
        try recorder.begin(captureID: UUID())
        try feed(recorder, speech: true, seconds: 10)
        // The cut lands inside this second, leaving a tail far shorter than the FLAC
        // encoder's 4608-frame first packet — the case that writes an unreadable stub
        // unless the writer pads it.
        try feed(recorder, speech: false, seconds: 1)

        let session = recorder.finish()
        XCTAssertEqual(session.segments.count, 2)

        let tail = try XCTUnwrap(session.segments.last)
        XCTAssertLessThan(tail.duration, 0.3)
        for segment in session.segments {
            let readBack = try AVAudioFile(forReading: segment.url)
            XCTAssertEqual(readBack.fileFormat.sampleRate, 16_000)
        }
        XCTAssertNoThrow(try AVAudioFile(forReading: session.url))
    }

    func test_discardRemovesSegmentFilesAndTheSessionFile() throws {
        let recorder = try makeRecorder()
        try recorder.begin(captureID: UUID())
        try feed(recorder, speech: true, seconds: 10)
        try feed(recorder, speech: false, seconds: 1)
        try feed(recorder, speech: true, seconds: 3)

        let session = recorder.finish()
        XCTAssertEqual(session.segments.count, 2)
        for segment in session.segments { XCTAssertTrue(exists(segment.url)) }

        recorder.discard()

        for segment in session.segments {
            XCTAssertFalse(exists(segment.url), "segment \(segment.index) survived discard")
        }
        XCTAssertFalse(exists(session.url), "discard means the whole capture is gone")
    }

    func test_deleteSegmentFilesLeavesTheDurableSessionFile() throws {
        let recorder = try makeRecorder()
        try recorder.begin(captureID: UUID())
        try feed(recorder, speech: true, seconds: 10)
        try feed(recorder, speech: false, seconds: 1)
        try feed(recorder, speech: true, seconds: 3)

        let session = recorder.finish()
        recorder.deleteSegmentFiles()

        for segment in session.segments {
            XCTAssertFalse(exists(segment.url), "segment \(segment.index) is a temporary")
        }
        XCTAssertTrue(
            exists(session.url),
            "History playback and retry both need the session file to outlive transcription"
        )
        XCTAssertNoThrow(try AVAudioFile(forReading: session.url))
    }

    // MARK: - Threading

    func test_segmentClosedIsDeliveredOnTheMainActor() throws {
        let recorder = try makeRecorder()
        var threads: [Bool] = []
        recorder.onSegmentClosed = { _ in threads.append(Thread.isMainThread) }
        try recorder.begin(captureID: UUID())

        try feed(recorder, speech: true, seconds: 10)
        try feed(recorder, speech: false, seconds: 1)

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads, [true], "the only hop out of the audio queue lands on main")
    }

    // MARK: - Degenerate cases

    func test_finishingWithNoBuffersAtAllIsSafe() throws {
        let recorder = try makeRecorder()
        try recorder.begin(captureID: UUID())

        let session = recorder.finish()

        XCTAssertEqual(session.duration, 0)
        XCTAssertTrue(session.segments.isEmpty, "an empty segment is not worth reporting")
        XCTAssertNoThrow(recorder.discard())
    }

    func test_finishingWithoutBeginningReportsAnEmptyRecording() throws {
        let recorder = try makeRecorder()

        let session = recorder.finish()

        XCTAssertEqual(session.duration, 0)
        XCTAssertTrue(session.segments.isEmpty)
        XCTAssertFalse(exists(session.url))
    }

    func test_ingestBeforeBeginIsIgnored() throws {
        let recorder = try makeRecorder()
        try feed(recorder, speech: true, seconds: 1)

        let session = recorder.finish()
        XCTAssertEqual(session.duration, 0)
        XCTAssertTrue(session.segments.isEmpty)
    }

    func test_finishIsIdempotent() throws {
        let recorder = try makeRecorder()
        try recorder.begin(captureID: UUID())
        try feed(recorder, speech: true, seconds: 5)

        let first = recorder.finish()
        let second = recorder.finish()

        XCTAssertEqual(first, second, "a second finish neither re-closes nor duplicates")
    }

    func test_disabledSegmentationKeepsTheWholeRecordingInOneSegment() throws {
        var config = SegmentPlannerConfig.default
        config.enabled = false
        let recorder = try makeRecorder(config: config)
        try recorder.begin(captureID: UUID())
        try feed(recorder, speech: true, seconds: 10)
        try feed(recorder, speech: false, seconds: 2)
        try feed(recorder, speech: true, seconds: 3)

        let session = recorder.finish()

        XCTAssertEqual(session.segments.count, 1)
        XCTAssertEqual(session.duration, 15.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(session.segments.first).duration, 15.0, accuracy: 0.001)
    }
}
