import AVFoundation
import Foundation
@testable import Captur

// Shared doubles for the DictationPipeline tests. Every dependency the pipeline
// takes has a controllable in-memory stand-in here. Owned by the pipeline task.

// MARK: - Ordered event log

/// A lock-guarded, cross-actor ordered log used to prove ordering invariants
/// (persist-before-audio, persist-before-network). Writers append from whichever
/// actor they happen to run on, so the lock-ordered sequence reflects the real
/// happens-before order rather than a per-actor view of it.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    func record(_ event: String) {
        lock.lock(); _events.append(event); lock.unlock()
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }; return _events
    }

    /// First index of an event whose string contains `needle`, or nil.
    func firstIndex(containing needle: String) -> Int? {
        events.firstIndex { $0.contains(needle) }
    }
}

// MARK: - Audio engine

/// Controllable `AudioEngineControlling`. A successful `startRecording` delivers one
/// converted buffer on the real audio queue — exactly as the concrete engine does —
/// so whoever consumes buffers is exercised on the isolation it actually runs under.
///
/// Deliberately not `@MainActor`: the protocol it fulfils is not, and pretending
/// otherwise would hide the very isolation the audio path is built around.
final class FakeAudioEngine: AudioEngineControlling, @unchecked Sendable {
    var onLevel: ((Double, TimeInterval) -> Void)?
    var onActiveDeviceChange: ((AudioInputDevice?) -> Void)?
    var onConvertedBuffer: ((AVAudioPCMBuffer) -> Void)?
    var activeDevice: AudioInputDevice?
    private(set) var isRecording = false

    var startError: Error?
    var suspendStart = false
    /// How many 16 kHz mono frames a successful start hands to the buffer consumer.
    var framesOnStart: AVAudioFrameCount = 1_600
    var startInfo = CaptureStartInfo(
        device: AudioInputDevice(
            id: "fake-input", name: "Fake Input", transport: .builtIn, isContinuityDevice: false),
        hardwareSampleRate: 48_000,
        hardwareChannels: 1,
        voiceProcessingActive: true,
        fellBackToSystemDefault: false,
        armedLatency: 0.05)

    private(set) var didStop = false
    private(set) var didCancel = false
    private(set) var startCount = 0
    /// Start attempts that have run to completion, however they ended. Distinct from
    /// `startCount`, which counts only the ones that installed a live session: a test
    /// asserting that a cancelled startup installed nothing has to be able to wait for
    /// the attempt to *finish* first, or it is asserting on a race.
    private(set) var startAttemptsResolved = 0
    private(set) var isStartSuspended = false
    /// The `voiceProcessing` argument of every start attempt, so a regression back to
    /// plain capture is a failing test rather than a silently worse product.
    private(set) var requestedVoiceProcessing: [Bool] = []
    private var startContinuation: CheckedContinuation<Void, Never>?
    let log: EventLog?

    init(log: EventLog? = nil) { self.log = log }

    func availableInputDevices() -> [AudioInputDevice] { [] }

    func startRecording(
        policy: MicSelectionPolicy,
        voiceProcessing: Bool
    ) async throws -> CaptureStartInfo {
        defer { startAttemptsResolved += 1 }
        requestedVoiceProcessing.append(voiceProcessing)
        if let startError { throw startError }
        if suspendStart {
            isStartSuspended = true
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
            isStartSuspended = false
            try Task.checkCancellation()
        }
        // Simulate captured audio reaching the consumer before the engine reports
        // itself live, so `isRecording` is a reliable signal that audio exists.
        await deliverSyntheticBuffer()
        isRecording = true
        startCount += 1
        log?.record("audio:start")
        return startInfo
    }

    func stopRecording() async {
        guard isRecording else { return }
        didStop = true
        isRecording = false
        log?.record("audio:stop")
    }

    func cancelRecording() async {
        didCancel = true
        isRecording = false
        log?.record("audio:cancel")
    }

    /// Push a meter sample to the consumer.
    func emitLevel(_ level: Double, at time: TimeInterval) { onLevel?(level, time) }

    func resumeStart() {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume()
    }

    /// Simulate the production engine's device-loss order: stop first, then publish
    /// nil while leaving the partial audio on disk for the owner to finalize.
    func simulateActiveDeviceLoss() {
        guard isRecording else { return }
        isRecording = false
        activeDevice = nil
        onActiveDeviceChange?(nil)
    }

    /// Hand one converted buffer to the consumer on the real audio queue and wait for
    /// it to land, mirroring the concrete engine's `onConvertedBuffer` contract.
    private func deliverSyntheticBuffer() async {
        guard framesOnStart > 0,
              let handler = onConvertedBuffer,
              let format = AudioFormatConverter.canonicalOutputFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesOnStart)
        else { return }
        buffer.frameLength = framesOnStart
        if let channel = buffer.floatChannelData?.pointee {
            for frame in 0..<Int(framesOnStart) {
                channel[frame] = Float(sin(Double(frame) * 0.05) * 0.25)
            }
        }
        // The concrete engine hands a freshly copied buffer straight to the audio queue
        // and nothing else retains it, which is exactly what this mirrors.
        nonisolated(unsafe) let payload = buffer
        nonisolated(unsafe) let deliver = handler
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AudioQueue.queue.async {
                deliver(payload)
                continuation.resume()
            }
        }
    }
}

// MARK: - Segment recorder

/// Controllable `SegmentRecording` that owns **real files**, because most of what the
/// pipeline is asked to prove about segments is a filesystem fact: the session file
/// survives a cancel, the segment temporaries are swept only after a clean success,
/// and nothing is deleted on a failure.
final class FakeSegmentRecorder: SegmentRecording, @unchecked Sendable {
    let directory: URL
    let log: EventLog?

    var beginError: Error?
    /// The tail segment produced by `finish()`. Speech below the planner's floor is
    /// the case the anti-hallucination gate exists for.
    var tailSpeechDuration: TimeInterval = 2.0
    var tailDuration: TimeInterval = 2.0
    var tailPrecedingSilence: TimeInterval = 0.7
    var sessionDuration: TimeInterval = 6.0

    private let lock = NSLock()
    private var _onSegmentClosed: ((AudioSegment) -> Void)?
    private var _beginCount = 0
    private var _finishCount = 0
    private var _discardCount = 0
    private var _deleteSegmentFilesCount = 0
    private var _ingestCount = 0
    private var _sawIngestOnMainThread = false
    private var _captureID: UUID?
    private var _sessionURL: URL?
    private var _segmentURLs: [URL] = []
    private var _closed: [AudioSegment] = []
    private var _nextIndex = 0
    private var _tailClosed = false

    init(directory: URL, log: EventLog? = nil) {
        self.directory = directory
        self.log = log
    }

    var onSegmentClosed: ((AudioSegment) -> Void)? {
        get { lock.withLock { _onSegmentClosed } }
        set { lock.withLock { _onSegmentClosed = newValue } }
    }

    var beginCount: Int { lock.withLock { _beginCount } }
    var finishCount: Int { lock.withLock { _finishCount } }
    var discardCount: Int { lock.withLock { _discardCount } }
    var deleteSegmentFilesCount: Int { lock.withLock { _deleteSegmentFilesCount } }
    var ingestCount: Int { lock.withLock { _ingestCount } }
    var sawIngestOnMainThread: Bool { lock.withLock { _sawIngestOnMainThread } }
    var sessionURL: URL? { lock.withLock { _sessionURL } }
    var segmentURLs: [URL] { lock.withLock { _segmentURLs } }

    func begin(captureID: UUID) throws {
        if let beginError { throw beginError }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionURL = directory.appendingPathComponent("\(captureID.uuidString).flac")
        try Data("session".utf8).write(to: sessionURL)
        lock.withLock {
            _beginCount += 1
            _captureID = captureID
            _sessionURL = sessionURL
            _segmentURLs = []
            _closed = []
            _nextIndex = 0
            _tailClosed = false
        }
        log?.record("recorder:begin")
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        let onMain = Thread.isMainThread
        lock.withLock {
            _ingestCount += 1
            if onMain { _sawIngestOnMainThread = true }
        }
    }

    func finish() -> SessionRecording {
        let recording: SessionRecording = lock.withLock {
            _finishCount += 1
            guard let sessionURL = _sessionURL else {
                return SessionRecording(
                    url: directory.appendingPathComponent("no-recording.flac"),
                    duration: 0,
                    segments: [])
            }
            if !_tailClosed {
                _tailClosed = true
                _closed.append(makeSegmentLocked(
                    speechDuration: tailSpeechDuration,
                    precedingSilence: tailPrecedingSilence,
                    duration: tailDuration,
                    isFinal: true))
            }
            return SessionRecording(
                url: sessionURL, duration: sessionDuration, segments: _closed)
        }
        log?.record("recorder:finish")
        return recording
    }

    func discard() {
        let urls: [URL] = lock.withLock {
            _discardCount += 1
            var urls = _segmentURLs
            if let sessionURL = _sessionURL { urls.append(sessionURL) }
            _segmentURLs = []
            _sessionURL = nil
            return urls
        }
        for url in urls { try? FileManager.default.removeItem(at: url) }
        log?.record("recorder:discard")
    }

    func deleteSegmentFiles() {
        let urls: [URL] = lock.withLock {
            _deleteSegmentFilesCount += 1
            let urls = _segmentURLs
            _segmentURLs = []
            return urls
        }
        for url in urls { try? FileManager.default.removeItem(at: url) }
        log?.record("recorder:deleteSegments")
    }

    /// Test hook: close a segment mid-recording exactly as the real recorder does —
    /// the handler is invoked on the main queue, which is the contract the pipeline
    /// relies on.
    @discardableResult
    func closeSegment(
        speechDuration: TimeInterval,
        precedingSilence: TimeInterval = 0.7,
        duration: TimeInterval = 8.0
    ) -> AudioSegment {
        let segment: AudioSegment = lock.withLock {
            let segment = makeSegmentLocked(
                speechDuration: speechDuration,
                precedingSilence: precedingSilence,
                duration: duration,
                isFinal: false)
            _closed.append(segment)
            return segment
        }
        onSegmentClosed?(segment)
        return segment
    }

    /// Creates the segment's file and its descriptor. Lock held.
    private func makeSegmentLocked(
        speechDuration: TimeInterval,
        precedingSilence: TimeInterval,
        duration: TimeInterval,
        isFinal: Bool
    ) -> AudioSegment {
        let index = _nextIndex
        _nextIndex += 1
        let id = _captureID ?? UUID()
        let url = directory.appendingPathComponent("\(id.uuidString)-segment-\(index).flac")
        try? Data("segment".utf8).write(to: url)
        _segmentURLs.append(url)
        return AudioSegment(
            id: UUID(),
            index: index,
            url: url,
            duration: duration,
            speechDuration: speechDuration,
            precedingSilence: precedingSilence,
            isFinal: isFinal)
    }
}

// MARK: - Transcriber

/// Controllable `DictationTranscribing`. Records every dispatch so the anti-hallucination
/// gate can be asserted by *absence*, and can be held open so a capture's results
/// land after a newer capture has already started.
final class FakeTranscriber: DictationTranscribing, @unchecked Sendable {
    struct Dispatch: Equatable, Sendable {
        let index: Int
        let url: URL
        let precedingSilence: TimeInterval
        let model: String
        let language: String?
        let vocabularyPrompt: String
    }

    /// Transcript for a segment index. `nil` is a permanently failed segment.
    var textForIndex: @Sendable (Int) -> String? = { "segment \($0)" }

    /// When false, `reset()` keeps its dispatches and `awaitAll` still resolves them.
    /// That is deliberately *worse* than the real transcriber, which cancels in-flight
    /// uploads: it forces the pipeline's own revocation to be the thing that stops a
    /// cancelled capture reaching the cursor, instead of the transcriber quietly
    /// covering for a missing guard.
    var clearsDispatchesOnReset = true

    private let lock = NSLock()
    private var _dispatches: [Dispatch] = []
    private var _warmCount = 0
    private var _resetCount = 0
    private var _keysSeen: Set<String> = []
    private var _isHeld = false
    private var _releaseContinuation: CheckedContinuation<Void, Never>?
    private var _isWaiting = false
    private var _liveTranscriptHandler: (@Sendable (String) -> Void)?
    private var _liveBeginCount = 0
    private var _finalRecordingURL: URL?
    let log: EventLog?

    init(log: EventLog? = nil) { self.log = log }

    var dispatches: [Dispatch] { lock.withLock { _dispatches } }
    var dispatchCount: Int { lock.withLock { _dispatches.count } }
    var warmCount: Int { lock.withLock { _warmCount } }
    var resetCount: Int { lock.withLock { _resetCount } }
    var keysSeen: Set<String> { lock.withLock { _keysSeen } }
    var liveBeginCount: Int { lock.withLock { _liveBeginCount } }
    var finalRecordingURL: URL? { lock.withLock { _finalRecordingURL } }
    /// True once `awaitAll` is parked on the hold, so a test can proceed without
    /// sleeping for a fixed interval.
    var isWaitingForRelease: Bool { lock.withLock { _isWaiting } }

    /// Park `awaitAll` until `release()` is called. Set before the capture ends.
    func hold() { lock.withLock { _isHeld = true } }

    func release() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            _isHeld = false
            let continuation = _releaseContinuation
            _releaseContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func enqueue(index: Int, url: URL, precedingSilence: TimeInterval,
                 apiKey: String, model: String, language: String?,
                 vocabularyPrompt: String) {
        lock.withLock {
            _dispatches.append(Dispatch(
                index: index, url: url, precedingSilence: precedingSilence,
                model: model, language: language, vocabularyPrompt: vocabularyPrompt))
            _keysSeen.insert(apiKey)
        }
        log?.record("net:enqueue:\(index)")
    }

    func awaitAll() async -> [SegmentResult] {
        let held: Bool = lock.withLock {
            if _isHeld { _isWaiting = true }
            return _isHeld
        }
        if held {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    guard _isHeld else { return true }
                    _releaseContinuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            lock.withLock { _isWaiting = false }
        }
        let dispatches = lock.withLock { _dispatches }
        let text = textForIndex
        return dispatches
            .sorted { $0.index < $1.index }
            .map { SegmentResult(index: $0.index,
                                 text: text($0.index),
                                 precedingSilence: $0.precedingSilence) }
    }

    func setLiveTranscriptHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.withLock { _liveTranscriptHandler = handler }
    }

    func emitLiveTranscript(_ text: String) {
        let handler = lock.withLock { _liveTranscriptHandler }
        handler?(text)
    }

    func beginLiveTranscription(vocabularyTerms: [String]) {
        lock.withLock { _liveBeginCount += 1 }
    }

    func setFinalRecordingURL(_ url: URL) {
        lock.withLock { _finalRecordingURL = url }
    }

    func warmConnection(apiKey: String) {
        lock.withLock {
            _warmCount += 1
            _keysSeen.insert(apiKey)
        }
        log?.record("net:warm")
    }

    func reset() {
        lock.withLock {
            _resetCount += 1
            _liveTranscriptHandler = nil
            _finalRecordingURL = nil
            if clearsDispatchesOnReset { _dispatches = [] }
        }
        log?.record("net:reset")
    }
}

// MARK: - Inserter

/// Records every insertion; returns a configurable outcome.
@MainActor
final class FakeInserter: TextInserting {
    private(set) var inserted: [String] = []
    private(set) var selectionEdits: [(text: String, original: String, target: String?)] = []
    var outcome: InsertionOutcome = .insertedDirect
    var accessibility = true
    /// Mutable so a test can move the user to a different app mid-recording — the
    /// case that separates "the mode was resolved at begin" from "the mode was
    /// resolved at insert time".
    var frontmostBundleID: String? = "com.test.app"
    var frontmostName: String? = "Test App"
    let log: EventLog?

    init(log: EventLog? = nil) { self.log = log }

    func hasAccessibilityPermission() -> Bool { accessibility }
    func requestAccessibilityPermission() {}
    func frontmostAppBundleID() -> String? { frontmostBundleID }
    func frontmostAppName() -> String? { frontmostName }

    func insert(_ text: String) async -> InsertionOutcome {
        inserted.append(text)
        log?.record("insert")
        return outcome
    }

    func insertSelectionEdit(_ text: String, originalSelection: String, targetBundleID: String?) async -> InsertionOutcome {
        selectionEdits.append((text, originalSelection, targetBundleID))
        guard text != originalSelection else { return .insertedDirect }
        return await insert(text)
    }
}

// MARK: - Chat client

/// Controllable `GroqChatting`.
///
/// **The call counter is the point.** "A pass-through mode makes zero chat requests"
/// is a claim about traffic, and asserting on the inserted text instead would pass
/// just as happily against a client that was called and echoed its input back.
final class FakeChatClient: GroqChatting, RefinementCompleting, @unchecked Sendable {
    struct Call: Equatable, @unchecked Sendable {
        let systemMessage: String
        let userMessage: String
        let provider: RefinementProviderID
        let model: String
        let reasoning: ReasoningEffort
        let temperature: Double
        let timeout: TimeInterval
    }

    /// What the pass returns. Throw from here to exercise a §17 fallback.
    var result: @Sendable (Call) throws -> String = { _ in "refined" }
    var usage: RefinementUsage?

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _keysSeen: Set<String> = []
    private var _isHeld = false
    private var _isWaiting = false
    private var _releaseContinuation: CheckedContinuation<Void, Never>?
    let log: EventLog?

    init(log: EventLog? = nil) { self.log = log }

    var calls: [Call] { lock.withLock { _calls } }
    var callCount: Int { lock.withLock { _calls.count } }
    var keysSeen: Set<String> { lock.withLock { _keysSeen } }
    /// True once a call is parked on the hold, so a test never sleeps on a clock.
    var isWaitingForRelease: Bool { lock.withLock { _isWaiting } }

    /// Park the pass until `release()`, so a test can act inside the window the
    /// 2.5 s timeout would otherwise own.
    func hold() { lock.withLock { _isHeld = true } }

    func release() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            _isHeld = false
            let continuation = _releaseContinuation
            _releaseContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func complete(systemMessage: String, userMessage: String, model: String,
                  temperature: Double, apiKey: String, timeout: TimeInterval,
                  onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let call = Call(systemMessage: systemMessage, userMessage: userMessage,
                        provider: .groq, model: model, reasoning: .providerDefault,
                        temperature: temperature, timeout: timeout)
        return try await perform(call: call, apiKey: apiKey)
    }

    func complete(systemMessage: String, userMessage: String,
                  provider: RefinementProviderID, model: String,
                  reasoning: ReasoningEffort, temperature: Double,
                  apiKey: String, timeout: TimeInterval,
                  onDelta: @escaping @Sendable (String) -> Void) async throws -> RefinementResult {
        let call = Call(systemMessage: systemMessage, userMessage: userMessage,
                        provider: provider, model: model, reasoning: reasoning,
                        temperature: temperature, timeout: timeout)
        let text = try await perform(call: call, apiKey: apiKey)
        return RefinementResult(
            text: text,
            provider: provider,
            requestedModelID: model,
            actualModelID: model,
            generationID: "fake-generation",
            usage: usage)
    }

    private func perform(call: Call, apiKey: String) async throws -> String {
        let held: Bool = lock.withLock {
            _calls.append(call)
            _keysSeen.insert(apiKey)
            if _isHeld { _isWaiting = true }
            return _isHeld
        }
        log?.record("chat:complete")
        if held {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    guard _isHeld else { return true }
                    _releaseContinuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            lock.withLock { _isWaiting = false }
        }
        return try result(call)
    }
}

// MARK: - Mode digit hotkeys

/// Controllable `ModeDigitHotkeyRegistering`.
///
/// Holds what Carbon would be holding, so a leaked plain-digit registration — the
/// worst bug this task can ship, because it swallows the number keys system-wide —
/// is an assertion on `registered` rather than an inspection of the machine.
@MainActor
final class FakeModeDigitRegistrar: ModeDigitHotkeyRegistering {
    private(set) var registered: [ModeDigitBinding] = []
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    /// Refuse this digit, the way an occupied combo would.
    var refusingDigit: Int?

    private var handler: ((Int) -> Void)?

    func registerModeDigits(_ bindings: [ModeDigitBinding],
                            onDigit: @escaping (Int) -> Void) throws {
        registerCallCount += 1
        handler = onDigit
        // Mirrors the real manager: everything registrable is registered, and the
        // refusal is thrown afterwards.
        registered = bindings.filter { $0.digit != refusingDigit }
        if let refusingDigit, bindings.contains(where: { $0.digit == refusingDigit }) {
            throw ModeDigitRefusal(digit: refusingDigit,
                                   underlying: .registrationFailed(-9878))
        }
    }

    func unregisterModeDigits() {
        unregisterCallCount += 1
        registered = []
        handler = nil
    }

    /// Deliver a keystroke the way Carbon would — only if it is actually registered.
    func press(_ digit: Int) {
        guard registered.contains(where: { $0.digit == digit }) else { return }
        handler?(digit)
    }
}

// MARK: - Errors

/// A generic failure double for paths that only care that *something* went wrong.
enum FakeFailure: Error, LocalizedError, Equatable {
    case boom(String)
    var errorDescription: String? { if case .boom(let message) = self { return message }; return nil }
}
