import AVFoundation
import Foundation

/// One closed slice of a recording, written to its own FLAC file and transcribed on its
/// own while the user is still talking.
///
/// Segment files are **temporaries**: once their transcription succeeds the pipeline
/// calls `deleteSegmentFiles()` and only the continuous session file survives.
struct AudioSegment: Equatable, Sendable, Identifiable {
    let id: UUID
    /// Position in the recording. Segments are transcribed concurrently and complete in
    /// arbitrary order, so the transcript is reassembled by this, never by arrival.
    let index: Int
    let url: URL
    /// Derived from frame counts at 16 kHz, not from a clock.
    let duration: TimeInterval
    /// How much of this segment the detector heard as speech. Below
    /// `SegmentPlannerConfig.minimumSpeechToDispatch` the segment is never sent —
    /// fed near-silence, Whisper invents text.
    let speechDuration: TimeInterval
    /// Silence observed at this segment's START — the length of the pause that caused
    /// the cut before it. The stitcher uses it to tell a mid-sentence breath from a
    /// genuine sentence break. For the first segment this is the lead-in before the
    /// user started speaking, which the stitcher never consults.
    let precedingSilence: TimeInterval
    /// True for the tail closed by `finish()`, the only segment that is not followed by
    /// more audio.
    let isFinal: Bool
}

/// The durable artifact of a capture: one continuous FLAC spanning the whole recording,
/// plus the segments it was cut into.
///
/// History plays this file, "retry transcription" re-sends it, and retention purges it.
/// A record that pointed at N segment files instead would have nothing coherent to
/// scrub, replay or re-send once the temporaries were swept.
struct SessionRecording: Equatable, Sendable {
    let url: URL
    let duration: TimeInterval
    let segments: [AudioSegment]
}

/// Owns the files of a live recording, and decides where each converted buffer lands.
///
/// **Two writers, always.** Every buffer is written twice — once to the currently open
/// segment and once to the continuous session file. The second write costs one extra
/// encode of a buffer already in hand, and buys a single durable artifact instead of a
/// pile of temporaries that playback, retry and retention would all have to reassemble.
///
/// **The timeline is frames, never wall-clock.** Every duration this type reports is
/// `frames / 16 000`, so N buffers in means exactly the duration those buffers
/// represent — deterministic under test and immune to scheduling jitter under load.
///
/// Not `@MainActor`: `ingest` runs on `AudioQueue` for every buffer, and the only hop to
/// the main actor in the whole path is the `onSegmentClosed` dispatch.
final class SegmentRecorder: @unchecked Sendable {

    /// Fired on the **main actor** when a segment is closed mid-recording, so the
    /// pipeline can gate it and start its transcription while the user keeps talking.
    ///
    /// The final tail segment is *not* delivered here — it comes back from `finish()`,
    /// so a caller never has to reconcile a callback with a return value.
    var onSegmentClosed: ((AudioSegment) -> Void)? {
        get { lock.withLock { _onSegmentClosed } }
        set { lock.withLock { _onSegmentClosed = newValue } }
    }

    /// The last error that stopped a *segment* file from opening. The recording keeps
    /// running when this is set — the session file is still being written, and losing
    /// segmentation costs latency, while losing the tail of a dictation costs words.
    var lastError: Error? { lock.withLock { _lastError } }

    /// Everything downstream of the converter is 16 kHz mono, so the timeline divisor is
    /// a constant rather than something read back off a buffer that could disagree.
    private static let sampleRate = AudioFormatConverter.targetSampleRate

    /// Stands in for a session that was never begun, so `finish()` can stay
    /// non-optional. Nothing is ever written here; callers recognise the case by
    /// `duration == 0` and no segments.
    private static let unstartedFileName = "no-recording.flac"

    private let directory: URL
    private let planner: SegmentPlanner
    private let makeVAD: () -> VoiceActivityDetector
    private let makeWriter: (URL) throws -> FLACWriter
    private let fileManager: FileManager

    private let lock = NSLock()

    private var _onSegmentClosed: ((AudioSegment) -> Void)?
    private var _lastError: Error?

    private var _captureID: UUID?
    private var _sessionURL: URL?
    private var _sessionWriter: FLACWriter?
    private var _vad: VoiceActivityDetector?

    /// Frames written since `begin`. The single source of the recording's timeline.
    private var _totalFrames: AVAudioFramePosition = 0

    private var _segmentWriter: FLACWriter?
    private var _segmentIndex = 0
    private var _segmentStartFrames: AVAudioFramePosition = 0
    /// The detector's speech total when the open segment started; the segment's own
    /// speech is the delta from here. One detector spans the whole recording so its
    /// adaptive noise floor is not thrown away at every cut.
    private var _segmentSpeechBaseline: TimeInterval = 0
    private var _segmentPrecedingSilence: TimeInterval = 0
    private var _segmentHeardSpeech = false

    /// Every segment file created since `begin`, including ones too empty to report.
    /// Cleanup works off this, not off the reported segments.
    private var _segmentURLs: [URL] = []
    private var _closedSegments: [AudioSegment] = []

    init(directory: URL,
         planner: SegmentPlanner,
         makeVAD: @escaping () -> VoiceActivityDetector,
         makeWriter: @escaping (URL) throws -> FLACWriter,
         fileManager: FileManager = .default) {
        self.directory = directory
        self.planner = planner
        self.makeVAD = makeVAD
        self.makeWriter = makeWriter
        self.fileManager = fileManager
    }

    // MARK: - Lifecycle

    /// Opens the session file and the first segment file.
    ///
    /// Any recording still in flight is flushed to disk and abandoned in memory; its
    /// files are deliberately left alone, because a previous session file may already
    /// belong to a record. Call `finish()` or `discard()` first.
    func begin(captureID: UUID) throws {
        try lock.withLock {
            closeWritersLocked()
            resetLocked()

            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true
            )

            let sessionURL = directory
                .appendingPathComponent("\(captureID.uuidString).flac")
            let sessionWriter = try makeWriter(sessionURL)

            let firstSegmentURL = segmentURL(captureID: captureID, index: 0)
            do {
                _segmentWriter = try makeWriter(firstSegmentURL)
            } catch {
                // Half-open is worse than not open: drop the session file too, so the
                // caller sees a clean failure rather than a capture that can never be
                // segmented.
                sessionWriter.finish()
                try? fileManager.removeItem(at: sessionURL)
                throw error
            }

            _segmentURLs = [firstSegmentURL]
            _captureID = captureID
            _sessionURL = sessionURL
            _sessionWriter = sessionWriter
            _vad = makeVAD()
        }
    }

    /// Writes one converted buffer to **both** open writers, updates the speech/silence
    /// picture, and asks the planner whether the segment should be cut.
    ///
    /// Audio-queue confined: called once per buffer, 20–50 times a second.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        AudioQueue.assertNotMain("SegmentRecorder.ingest")
        guard buffer.frameLength > 0 else { return }

        // Computed before the lock: it is pure arithmetic over the caller's buffer.
        let level = level(of: buffer)

        let closed: AudioSegment? = lock.withLock {
            guard let sessionWriter = _sessionWriter, var vad = _vad else { return nil }

            sessionWriter.write(buffer)
            _segmentWriter?.write(buffer)
            _totalFrames += AVAudioFramePosition(buffer.frameLength)

            // The detector is driven off the frame timeline too, so speech and silence
            // totals stay consistent with the durations reported for the same audio.
            let now = seconds(_totalFrames)
            _ = vad.process(level: level, at: now)
            _vad = vad

            let silence = max(0, now - (vad.lastSpeechTime ?? 0))
            let isSpeaking = silence <= 0
            if isSpeaking {
                _segmentHeardSpeech = true
            } else if !_segmentHeardSpeech {
                // Still waiting for the first word: the pause that opened this segment
                // is still growing, and the stitcher wants its full length.
                _segmentPrecedingSilence = silence
            }

            guard _segmentWriter != nil,
                  planner.shouldCut(
                      currentSegmentDuration: seconds(_totalFrames - _segmentStartFrames),
                      continuousSilenceDuration: silence,
                      isSpeaking: isSpeaking
                  )
            else { return nil }

            let segment = closeSegmentLocked(isFinal: false)
            openNextSegmentLocked(carriedSilence: silence)
            return segment
        }

        guard let closed, let handler = lock.withLock({ _onSegmentClosed }) else { return }
        DispatchQueue.main.async { handler(closed) }
    }

    /// Closes both writers and reports the recording. Idempotent; the files stay on disk
    /// until `discard()` or `deleteSegmentFiles()` removes them.
    func finish() -> SessionRecording {
        lock.withLock {
            _ = closeSegmentLocked(isFinal: true)
            // `FLACWriter` records a mid-recording disk error instead of throwing, so
            // that a bad sector costs a second of audio rather than the dictation. That
            // error has to be read somewhere or the failure is invisible: the reported
            // duration is the audio captured, which after a write error is more than
            // the file on disk actually holds.
            noteLocked(_sessionWriter?.writeError)
            _sessionWriter?.finish()
            _sessionWriter = nil
            _vad = nil

            guard let sessionURL = _sessionURL else {
                return SessionRecording(
                    url: directory.appendingPathComponent(Self.unstartedFileName),
                    duration: 0,
                    segments: []
                )
            }
            return SessionRecording(
                url: sessionURL,
                duration: seconds(_totalFrames),
                segments: _closedSegments
            )
        }
    }

    /// Throws the whole capture away — every segment file *and* the session file.
    func discard() {
        let urls: [URL] = lock.withLock {
            closeWritersLocked()
            var urls = _segmentURLs
            if let sessionURL = _sessionURL { urls.append(sessionURL) }
            resetLocked()
            return urls
        }
        remove(urls)
    }

    /// Removes only the disposable segment temporaries, leaving the durable session
    /// file. This is what the pipeline calls once transcription has succeeded.
    ///
    /// Call it after `finish()`: it deletes files by URL and does not wait for a writer.
    func deleteSegmentFiles() {
        let urls: [URL] = lock.withLock {
            let urls = _segmentURLs
            _segmentURLs = []
            return urls
        }
        remove(urls)
    }

    // MARK: - Segment bookkeeping (lock held)

    /// Finalizes the open segment writer and records the segment. Returns nil when there
    /// was nothing to close, or when the segment holds no audio at all — an empty
    /// segment would only ever be a file the caller has to reason about and gate out.
    private func closeSegmentLocked(isFinal: Bool) -> AudioSegment? {
        guard let writer = _segmentWriter else { return nil }
        noteLocked(writer.writeError)
        writer.finish()
        _segmentWriter = nil

        let frames = _totalFrames - _segmentStartFrames
        guard frames > 0 else { return nil }

        let speech = max(0, (_vad?.speechAccumulated ?? 0) - _segmentSpeechBaseline)
        let segment = AudioSegment(
            id: UUID(),
            index: _segmentIndex,
            url: writer.url,
            duration: seconds(frames),
            speechDuration: speech,
            precedingSilence: _segmentPrecedingSilence,
            isFinal: isFinal
        )
        _closedSegments.append(segment)
        return segment
    }

    /// Opens the next segment file and resets the per-segment counters.
    ///
    /// A failure here stops segmentation but never the recording: the session writer is
    /// untouched, so the audio still lands on disk and the capture degrades to a single
    /// end-of-recording transcription instead of losing its tail.
    private func openNextSegmentLocked(carriedSilence: TimeInterval) {
        guard let captureID = _captureID else { return }

        _segmentIndex += 1
        _segmentStartFrames = _totalFrames
        _segmentSpeechBaseline = _vad?.speechAccumulated ?? 0
        _segmentPrecedingSilence = carriedSilence
        _segmentHeardSpeech = false

        let url = segmentURL(captureID: captureID, index: _segmentIndex)
        do {
            _segmentWriter = try makeWriter(url)
            _segmentURLs.append(url)
        } catch {
            _lastError = error
            _segmentWriter = nil
        }
    }

    /// Keeps the *first* failure. A disk that has started refusing writes will report
    /// again on every buffer, and the first error is the one that explains the capture.
    private func noteLocked(_ error: Error?) {
        guard _lastError == nil, let error else { return }
        _lastError = error
    }

    private func closeWritersLocked() {
        _segmentWriter?.finish()
        _segmentWriter = nil
        _sessionWriter?.finish()
        _sessionWriter = nil
    }

    private func resetLocked() {
        _lastError = nil
        _captureID = nil
        _sessionURL = nil
        _vad = nil
        _totalFrames = 0
        _segmentIndex = 0
        _segmentStartFrames = 0
        _segmentSpeechBaseline = 0
        _segmentPrecedingSilence = 0
        _segmentHeardSpeech = false
        _segmentURLs = []
        _closedSegments = []
    }

    // MARK: - Helpers

    private func segmentURL(captureID: UUID, index: Int) -> URL {
        directory.appendingPathComponent("\(captureID.uuidString)-segment-\(index).flac")
    }

    private func seconds(_ frames: AVAudioFramePosition) -> TimeInterval {
        guard Self.sampleRate > 0 else { return 0 }
        return TimeInterval(frames) / Self.sampleRate
    }

    private func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?.pointee else { return 0 }
        return normalizedRMS(
            samples: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        )
    }

    private func remove(_ urls: [URL]) {
        for url in urls { try? fileManager.removeItem(at: url) }
    }
}
