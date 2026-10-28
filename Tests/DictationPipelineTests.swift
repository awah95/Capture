import AVFoundation
import Combine
import XCTest
@testable import Captur

/// What Groq "returns", shared by every transcriber the pipeline builds.
///
/// Held apart from the transcribers themselves because a retry builds its own
/// transcriber inside the call under test — there is no moment at which a test could
/// reach in and configure it.
private final class TranscriptPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var _text: @Sendable (Int) -> String? = { "segment \($0)" }

    var text: @Sendable (Int) -> String? {
        get { lock.withLock { _text } }
        set { lock.withLock { _text = newValue } }
    }
}

/// Collects the per-capture objects the pipeline builds through its factories, so a
/// test can reach capture A's transcriber after capture B has started.
private final class MadeObjects: @unchecked Sendable {
    private let lock = NSLock()
    private var _recorders: [FakeSegmentRecorder] = []
    private var _transcribers: [FakeTranscriber] = []

    var recorders: [FakeSegmentRecorder] { lock.withLock { _recorders } }
    var transcribers: [FakeTranscriber] { lock.withLock { _transcribers } }

    func add(_ recorder: FakeSegmentRecorder) { lock.withLock { _recorders.append(recorder) } }
    func add(_ transcriber: FakeTranscriber) { lock.withLock { _transcribers.append(transcriber) } }
}

/// An in-memory `DictationRecordLogging` that appends to the shared ordered event
/// log, so persist-before-network is a sequence assertion rather than a guess.
///
/// Every method suspends before doing anything. The real log is an actor, so a caller
/// always yields the main actor to reach it — and a fake that resolved instantly would
/// make "persist, *then* start the microphone" indistinguishable from "start the
/// microphone and persist whenever". It was, until this yield was added.
private final class FakeRecordLog: DictationRecordLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [DictationRecord] = []
    private var _holdsAppend = false
    private var _isWaitingOnAppend = false
    private var _appendContinuation: CheckedContinuation<Void, Never>?
    private let log: EventLog?

    init(log: EventLog? = nil) { self.log = log }

    var records: [DictationRecord] { lock.withLock { _records } }
    /// True once an `append` is parked on the hold.
    var isWaitingOnAppend: Bool { lock.withLock { _isWaitingOnAppend } }

    /// Park the next append, so a test can look at the world in the window where the
    /// record has been asked for but has not landed.
    func holdAppend() { lock.withLock { _holdsAppend = true } }

    func releaseAppend() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            _holdsAppend = false
            let continuation = _appendContinuation
            _appendContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func append(_ record: DictationRecord) async throws {
        await Task.yield()
        let held: Bool = lock.withLock {
            if _holdsAppend { _isWaitingOnAppend = true }
            return _holdsAppend
        }
        if held {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    guard _holdsAppend else { return true }
                    _appendContinuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            lock.withLock { _isWaitingOnAppend = false }
        }
        lock.withLock { _records.append(record) }
        log?.record("record:append")
    }

    func all() async throws -> [DictationRecord] {
        await Task.yield()
        return lock.withLock { _records }
    }

    func record(id: UUID) async throws -> DictationRecord? {
        await Task.yield()
        return lock.withLock { _records.first { $0.id == id } }
    }

    func update(id: UUID, mutate: (inout DictationRecord) -> Void) async throws {
        await Task.yield()
        lock.withLock {
            guard let index = _records.firstIndex(where: { $0.id == id }) else { return }
            mutate(&_records[index])
        }
        log?.record("record:update")
    }
}

/// The user's mode, vocabulary and replacement settings, as one mutable double.
///
/// Everything here is what a real store would hold, so a test can change it
/// *during* a dictation — which is the only way to prove the pipeline reads each
/// value at the moment the spec says it does rather than whenever it gets round
/// to it.
@MainActor
private final class ModeWorld {
    var perAppMap: [String: String] = [:]
    var vocabulary: [VocabularyTerm] = []
    var replacements: [Replacement] = []
    var clipboard: String? = "clipboard contents"
    var bindings: HotkeyBindings = .default
    var localCleanup: (any LocalCleanCompleting)?
    var cleanupRegistry: LocalCleanupRegistry = .builtIn
    var contextEnabled = true
    var snapshot = ContextSnapshot.empty
    var snapshotReads = 0
    var websiteMap: [String: String] = [:]
    var websiteHost: (String?) async -> String? = { _ in nil }
    var clipboardUpdate = ClipboardContextUpdate.unchanged

    /// Every whole-list write, so write amplification is a counted fact.
    private(set) var writes: [[VocabularyTerm]] = []
    /// How many times the pasteboard was *read*. Reading it is the privacy-relevant
    /// act, so this is asserted at zero for modes that did not ask for it.
    private(set) var clipboardReads = 0

    /// The closures capture `self` strongly. A retain cycle in a test double that
    /// lives for one test method is not a leak worth an `unowned`, which would trap
    /// the moment a pipeline outlived its harness by a hair.
    func services(chat: FakeChatClient? = nil,
                  digits: FakeModeDigitRegistrar? = nil) -> ModeServices {
        ModeServices(
            chat: chat,
            refinement: chat,
            localCleanup: localCleanup,
            cleanupRegistry: cleanupRegistry,
            refinementAPIKey: { _ in "test-key" },
            contextEnabled: { self.contextEnabled },
            contextSnapshot: { _, request in
                self.snapshotReads += 1
                let snapshot = self.snapshot
                return Task {
                    var copy = snapshot
                    let host = request.websiteMap.isEmpty ? nil : await self.websiteHost(request.targetBundleID)
                    copy.resolvedModeID = request.resolve(host: host).id
                    return copy
                }
            },
            perWebsiteMap: { self.websiteMap },
            clipboardStartReader: {
                let value = self.clipboard
                return { self.clipboardReads += 1; return value }
            },
            clipboardAtEnd: { _ in self.clipboardUpdate },
            perAppModeMap: { self.perAppMap },
            vocabulary: { self.vocabulary },
            saveVocabulary: { terms in
                self.writes.append(terms)
                self.vocabulary = terms
            },
            replacements: { self.replacements },
            clipboard: {
                self.clipboardReads += 1
                return self.clipboard
            },
            hotkeyBindings: { self.bindings },
            modeDigits: digits)
    }
}

/// A vocabulary term with the fields a test does not care about already filled in.
private func term(_ text: String,
                  soundsLike: String? = nil,
                  pinned: Bool = false,
                  useCount: Int = 0,
                  lastUsed: Date? = nil,
                  apps: Set<String> = []) -> VocabularyTerm {
    VocabularyTerm(id: UUID(), text: text, soundsLike: soundsLike, isPinned: pinned,
                   useCount: useCount, lastUsed: lastUsed, appBundleIDs: apps)
}

private func rule(_ find: String,
                  _ replaceWith: String,
                  wholeWordOnly: Bool = false,
                  caseSensitive: Bool = false,
                  isEnabled: Bool = true) -> Replacement {
    Replacement(id: UUID(), find: find, replaceWith: replaceWith,
                wholeWordOnly: wholeWordOnly, caseSensitive: caseSensitive,
                isEnabled: isEnabled)
}

@MainActor
private final class PipelinePlaybackProbe: NowPlayingControlling {
    var state: NowPlayingRead = .empty
    var holdRead = false
    var waitingOnRead = false
    var continuation: CheckedContinuation<Void, Never>?
    var commands: [String] = []

    func read() async -> NowPlayingRead {
        if holdRead {
            waitingOnRead = true
            await withCheckedContinuation { continuation = $0 }
            waitingOnRead = false
        }
        return state
    }
    func releaseRead() {
        holdRead = false
        continuation?.resume()
        continuation = nil
    }
    func pause(_ snapshot: NowPlayingSnapshot, permit: MediaCommandPermit) async -> Bool {
        commands.append("pause")
        return false
    }
    func play(_ snapshot: NowPlayingSnapshot, permit: MediaCommandPermit) async -> Bool {
        commands.append("play")
        return false
    }
}

@MainActor
private struct NoFallbackPlayback: MediaPlayerControlling {
    func runningPlayers() -> [MediaPlayer] { [] }
    func playback(of player: MediaPlayer) -> MediaPlayback? { nil }
    func pause(_ player: MediaPlayer, permit: MediaCommandPermit) -> Bool { false }
    func play(_ player: MediaPlayer, permit: MediaCommandPermit) -> Bool { false }
}

@MainActor
final class DictationPipelineTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let pipeline: DictationPipeline
        let audio: FakeAudioEngine
        let inserter: FakeInserter
        let made: MadeObjects
        let plan: TranscriptPlan
        let recordLog: any DictationRecordLogging
        let fakeRecordLog: FakeRecordLog?
        let events: EventLog
        let directory: URL
        let world: ModeWorld
        let chat: FakeChatClient
        let digits: FakeModeDigitRegistrar

        /// The recorder and transcriber of the capture that began first.
        var recorder: FakeSegmentRecorder { made.recorders[0] }
        var transcriber: FakeTranscriber { made.transcribers[0] }
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeHarness(
        plannerConfig: SegmentPlannerConfig = .default,
        configuration: DictationPipeline.Configuration = .default,
        configurationProvider: (() -> DictationPipeline.Configuration)? = nil,
        neverStoreAudio: @escaping () -> Bool = { false },
        recordLog: (any DictationRecordLogging)? = nil,
        availableModes: @escaping () -> [Mode] = { Mode.builtIns },
        /// The one thing a test may take away: a pipeline with no chat client at
        /// all, which is what an unwired composition root would build.
        withChatClient: Bool = true,
        world providedWorld: ModeWorld? = nil,
        now: @escaping () -> Date = Date.init
    ) throws -> Harness {
        // Built here rather than as a default argument, which would be evaluated
        // outside the actor.
        let world = providedWorld ?? ModeWorld()
        let events = EventLog()
        let directory = try tempDirectory()
        let audio = FakeAudioEngine(log: events)
        let inserter = FakeInserter(log: events)
        let made = MadeObjects()
        let plan = TranscriptPlan()
        let fakeRecordLog = recordLog == nil ? FakeRecordLog(log: events) : nil
        let log: any DictationRecordLogging = recordLog ?? fakeRecordLog ?? FakeRecordLog()
        let chat = FakeChatClient(log: events)
        let digits = FakeModeDigitRegistrar()

        let pipeline = DictationPipeline(
            audioEngine: audio,
            makeRecorder: {
                let recorder = FakeSegmentRecorder(directory: directory, log: events)
                made.add(recorder)
                return recorder
            },
            makeTranscriber: {
                let transcriber = FakeTranscriber(log: events)
                transcriber.textForIndex = { plan.text($0) }
                made.add(transcriber)
                return transcriber
            },
            planner: SegmentPlanner(config: plannerConfig),
            inserter: inserter,
            recordLog: log,
            sessionDirectory: directory,
            apiKey: { "test-key" },
            micPolicy: { .default },
            availableModes: availableModes,
            configuration: configuration,
            configurationProvider: configurationProvider,
            neverStoreAudio: neverStoreAudio,
            modes: world.services(chat: withChatClient ? chat : nil, digits: digits),
            now: now)

        return Harness(pipeline: pipeline, audio: audio, inserter: inserter, made: made,
                       plan: plan, recordLog: log, fakeRecordLog: fakeRecordLog,
                       events: events, directory: directory,
                       world: world, chat: chat, digits: digits)
    }

    /// A configuration whose default mode is an LLM one, so the mode pass is on the
    /// path by default rather than something each test has to switch into.
    private func cleanConfiguration() -> DictationPipeline.Configuration {
        var configuration = DictationPipeline.Configuration.default
        configuration.defaultModeID = Mode.clean.id
        return configuration
    }

    private func localCleanModes() -> [Mode] {
        Mode.builtIns.map {
            var mode = $0
            if mode.id == Mode.clean.id { mode.cleanupChoice = .localS1Mini }
            return mode
        }
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 5,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if !condition() { XCTFail("timed out waiting: \(message)", file: file, line: line) }
    }

    /// Begin a capture and wait until the microphone is actually live.
    private func beginAndArm(_ harness: Harness,
                             trigger: CaptureTrigger = .pushToTalk) async {
        await harness.pipeline.begin(trigger: trigger)
        await waitUntil({ harness.pipeline.phase.isRecording }, "the capture reaches .recording")
    }

    private func exists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func makeInterruptedRecord(id: UUID, audioFileName: String) -> DictationRecord {
        DictationRecord(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            speakingDuration: 0,
            rawText: "",
            finalText: "",
            modeID: Mode.verbatim.id,
            targetBundleID: nil,
            targetAppName: nil,
            wordCount: 0,
            rawWordCount: 0,
            segmentCount: 0,
            timings: Timings(captureMs: 0, convertMs: 0, uploadMs: 0, whisperMs: 0,
                             llmMs: 0, insertMs: 0, totalMs: 0),
            insertionOutcome: "",
            retryCount: 0,
            editDistanceRawToFinal: 0,
            audioFileName: audioFileName,
            audioBytes: 0,
            estimatedCostUSD: 0,
            vocabularyTermsSent: 0,
            voiceProcessingActive: true,
            outcome: .failed(reason: DictationPipeline.interruptedReason))
    }

    func testScreenRecorderNowPlayingSessionDoesNotInterruptLiveDictation() async throws {
        var configuration = DictationPipeline.Configuration.default
        configuration.transcriptionProvider = .localUnified
        configuration.liveTranscriptionEnabled = true
        let harness = try makeHarness(configuration: configuration)
        let probe = PipelinePlaybackProbe()
        probe.state = .playback(NowPlayingSnapshot(identity: NowPlayingIdentity(
            bundleIdentifier: "com.apple.QuickTimePlayerX", processIdentifier: 500,
            title: "Screen recording", artist: nil, album: nil, duration: nil,
            uniqueIdentifier: nil, contentItemIdentifier: nil), playing: true))
        let media = MediaController(players: NoFallbackPlayback(), nowPlaying: probe, isEnabled: { true })
        let observation = harness.pipeline.$phase.sink { media.update(holdsMicrophone: $0.holdsMicrophone) }
        defer { observation.cancel() }

        await beginAndArm(harness)
        await media.waitForPendingOperations()
        harness.transcriber.emitLiveTranscript("Dictation continues during screen recording")
        await waitUntil({ harness.pipeline.liveTranscriptPreview != nil }, "live transcription continues")
        XCTAssertTrue(harness.audio.isRecording)
        XCTAssertFalse(harness.audio.didStop)
        XCTAssertFalse(harness.audio.didCancel)
        XCTAssertGreaterThan(harness.recorder.ingestCount, 0)
        XCTAssertEqual(probe.commands, [], "A screen recorder receives no pause or play")

        await harness.pipeline.end()
        await media.waitForPendingOperations()
        XCTAssertFalse(harness.inserter.inserted.isEmpty, "Dictation still completes and inserts")
        XCTAssertEqual(probe.commands, [])
    }

    func testSlowPlaybackDetectionDoesNotBlockRecordingOrTranscription() async throws {
        var configuration = DictationPipeline.Configuration.default
        configuration.transcriptionProvider = .localUnified
        configuration.liveTranscriptionEnabled = true
        let harness = try makeHarness(configuration: configuration)
        let probe = PipelinePlaybackProbe()
        probe.holdRead = true
        probe.state = .playback(NowPlayingSnapshot(identity: NowPlayingIdentity(
            bundleIdentifier: "com.google.Chrome", processIdentifier: 501,
            title: "Video", artist: nil, album: nil, duration: 120,
            uniqueIdentifier: .string("item-1"), contentItemIdentifier: nil), playing: true))
        let media = MediaController(players: NoFallbackPlayback(), nowPlaying: probe, isEnabled: { true })
        let observation = harness.pipeline.$phase.sink { media.update(holdsMicrophone: $0.holdsMicrophone) }
        defer { observation.cancel(); probe.releaseRead() }

        await beginAndArm(harness)
        await waitUntil({ probe.waitingOnRead }, "playback detection is still pending")
        harness.transcriber.emitLiveTranscript("Audio and transcription keep running")
        await waitUntil({ harness.pipeline.liveTranscriptPreview != nil }, "live transcript arrives before detection")
        XCTAssertTrue(harness.audio.isRecording)
        XCTAssertFalse(harness.audio.didStop)
        XCTAssertFalse(harness.audio.didCancel)
        XCTAssertGreaterThan(harness.recorder.ingestCount, 0)

        await harness.pipeline.end()
        XCTAssertFalse(harness.inserter.inserted.isEmpty, "Completion does not wait for the media helper")
        probe.releaseRead()
        await media.waitForPendingOperations()
        XCTAssertEqual(probe.commands, [], "No late pause after dictation ended")
    }

    // MARK: - Ported invariant: duplicate triggers are rejected, not queued

    func testDuplicateBeginWhileRecordingIsRejected() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)

        await harness.pipeline.begin(trigger: .toggle)
        await harness.pipeline.begin(trigger: .menuBar)

        XCTAssertEqual(harness.made.recorders.count, 1, "duplicate triggers open no new recording")
        XCTAssertEqual(harness.made.transcribers.count, 1)
        XCTAssertEqual(harness.audio.startCount, 1, "the engine is started exactly once")
        XCTAssertTrue(harness.pipeline.phase.isRecording)
    }

    func testCapabilityEnabledProviderPublishesLiveTranscriptPreviewWhileRecording() async throws {
        var moonshine = DictationPipeline.Configuration.default
        moonshine.transcriptionProvider = .localMoonshine
        moonshine.liveTranscriptionEnabled = true
        let local = try makeHarness(configuration: moonshine)
        await beginAndArm(local)

        local.transcriber.emitLiveTranscript("  A revisable Moonshine partial  ")
        await waitUntil({ local.pipeline.liveTranscriptPreview != nil }, "Moonshine partial appears")
        XCTAssertEqual(local.pipeline.liveTranscriptPreview, "A revisable Moonshine partial")
        XCTAssertEqual(local.transcriber.liveBeginCount, 1)

        await local.pipeline.cancel()
        XCTAssertNil(local.pipeline.liveTranscriptPreview, "preview leaves with the recording")

        let groq = try makeHarness()
        await beginAndArm(groq)
        groq.transcriber.emitLiveTranscript("should remain hidden")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(groq.pipeline.liveTranscriptPreview,
                     "batch-only providers never acquire a live transcript handler")
        await groq.pipeline.cancel()
    }

    func testLiveTranscriptionToggleOffKeepsUnifiedOnBatchPath() async throws {
        var unified = DictationPipeline.Configuration.default
        unified.transcriptionProvider = .localUnified
        unified.liveTranscriptionEnabled = false
        let harness = try makeHarness(configuration: unified)
        await beginAndArm(harness)

        harness.transcriber.emitLiveTranscript("must stay hidden")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(harness.pipeline.liveTranscriptPreview)
        XCTAssertEqual(harness.transcriber.liveBeginCount, 0)
        await harness.pipeline.cancel()
    }

    func testUnifiedCanUseTheSameLivePreviewPathWhenEnabled() async throws {
        var unified = DictationPipeline.Configuration.default
        unified.transcriptionProvider = .localUnified
        unified.liveTranscriptionEnabled = true
        let harness = try makeHarness(configuration: unified)
        await beginAndArm(harness)

        harness.transcriber.emitLiveTranscript("Unified is live")
        await waitUntil({ harness.pipeline.liveTranscriptPreview != nil }, "Unified partial appears")
        XCTAssertEqual(harness.pipeline.liveTranscriptPreview, "Unified is live")
        XCTAssertEqual(harness.transcriber.liveBeginCount, 1)
        await harness.pipeline.cancel()
    }

    func testEndingSuppliesTheContinuousRecordingForFinalTranscription() async throws {
        var unified = DictationPipeline.Configuration.default
        unified.transcriptionProvider = .localUnified
        unified.liveTranscriptionEnabled = true
        let harness = try makeHarness(configuration: unified)
        await beginAndArm(harness)
        let sessionURL = try XCTUnwrap(harness.recorder.sessionURL)

        await harness.pipeline.end()

        XCTAssertEqual(harness.transcriber.finalRecordingURL, sessionURL)
    }

    func testDuplicateBeginWhileArmingIsRejected() async throws {
        let harness = try makeHarness()
        harness.audio.suspendStart = true

        await harness.pipeline.begin(trigger: .pushToTalk)
        await waitUntil({ harness.audio.isStartSuspended }, "the first start suspends")
        XCTAssertEqual(harness.pipeline.phase, .arming)

        await harness.pipeline.begin(trigger: .pushToTalk)

        XCTAssertEqual(harness.made.recorders.count, 1,
                       "a trigger during arming is rejected, not queued behind the first")
        harness.audio.resumeStart()
    }

    // MARK: - Ported invariant: a stale capture cannot finalize a newer one

    func testStaleCaptureCannotFinalizeANewerCapture() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.transcriber.hold()

        let ending = Task { @MainActor in await harness.pipeline.end() }
        await waitUntil({ harness.transcriber.isWaitingForRelease }, "capture A parks on Groq")

        // A new capture starts while A is still transcribing — spec §4.1 allows this.
        await beginAndArm(harness, trigger: .toggle)
        XCTAssertEqual(harness.made.recorders.count, 2)

        harness.transcriber.release()
        await ending.value
        await waitUntil({ harness.inserter.inserted.count == 1 }, "capture A finishes")

        XCTAssertTrue(harness.pipeline.phase.isRecording,
                      "a superseded capture must not drag the newer one out of .recording")
    }

    func testEachCaptureOwnsItsInsertionSoALateResultStillLands() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.plan.text = { _ in "capture A" }
        harness.transcriber.hold()

        let ending = Task { @MainActor in await harness.pipeline.end() }
        await waitUntil({ harness.transcriber.isWaitingForRelease }, "capture A parks on Groq")

        await beginAndArm(harness, trigger: .toggle)
        harness.transcriber.release()
        await ending.value

        await waitUntil({ !harness.inserter.inserted.isEmpty }, "capture A inserts")
        XCTAssertEqual(harness.inserter.inserted, ["capture A"],
                       "a capture's transcript belongs to the session that spoke it")
    }

    func testCancelledCaptureNeverInserts() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        // The fake keeps returning results after `reset()` so that the *only* thing
        // standing between a cancelled capture and the cursor is the pipeline's own
        // revocation, not the transcriber conveniently forgetting its work.
        harness.transcriber.clearsDispatchesOnReset = false
        harness.transcriber.hold()

        let ending = Task { @MainActor in await harness.pipeline.end() }
        await waitUntil({ harness.transcriber.isWaitingForRelease }, "the capture parks on Groq")

        await harness.pipeline.cancel()
        harness.transcriber.release()
        await ending.value

        XCTAssertTrue(harness.inserter.inserted.isEmpty,
                      "a cancelled capture must never reach the cursor")
    }

    // MARK: - Ported invariant: persist before the network

    func testRecordIsPersistedBeforeAudioStartsAndBeforeAnySegmentIsDispatched() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.recorder.closeSegment(speechDuration: 5)
        await harness.pipeline.end()

        let append = harness.events.firstIndex(containing: "record:append")
        let audioStart = harness.events.firstIndex(containing: "audio:start")
        let firstDispatch = harness.events.firstIndex(containing: "net:enqueue")

        let appendIndex = try XCTUnwrap(append, "the record is written")
        let audioIndex = try XCTUnwrap(audioStart, "the microphone starts")
        let dispatchIndex = try XCTUnwrap(firstDispatch, "a segment is uploaded")
        XCTAssertLessThan(appendIndex, audioIndex, "the record is on disk before audio starts")
        XCTAssertLessThan(appendIndex, dispatchIndex,
                          "the record is on disk before anything reaches the network")
    }

    func testTheMicrophoneDoesNotStartUntilTheRecordHasLanded() async throws {
        let harness = try makeHarness()
        let recordLog = try XCTUnwrap(harness.fakeRecordLog)
        recordLog.holdAppend()

        let beginning = Task { @MainActor in await harness.pipeline.begin(trigger: .pushToTalk) }
        await waitUntil({ recordLog.isWaitingOnAppend }, "begin parks on the record write")

        // The window where the record has been asked for but has not landed: if the
        // app died here, there must be nothing on disk that no record points at.
        XCTAssertEqual(harness.audio.startCount, 0, "no audio before the record exists")
        XCTAssertEqual(harness.made.transcribers[0].dispatchCount, 0)

        recordLog.releaseAppend()
        await beginning.value
        await waitUntil({ harness.pipeline.phase.isRecording }, "the capture then arms normally")
    }

    func testBeginWarmsTheConnectionBeforeAudioStarts() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)

        XCTAssertEqual(harness.transcriber.warmCount, 1)
        let warm = try XCTUnwrap(harness.events.firstIndex(containing: "net:warm"))
        let audioStart = try XCTUnwrap(harness.events.firstIndex(containing: "audio:start"))
        XCTAssertLessThan(warm, audioStart, "TLS setup is paid for before there is audio to send")
    }

    // MARK: - Ported invariant: an unfinished capture survives a relaunch

    func testRelaunchRecoversAnUnfinishedCaptureAsRetryable() async throws {
        let directory = try tempDirectory()
        let realLog = DictationRecordLog(fileURL: directory.appendingPathComponent("records.jsonl"))
        let id = UUID()
        let audioFileName = "\(id.uuidString).flac"
        try Data("audio".utf8).write(to: directory.appendingPathComponent(audioFileName))
        try await realLog.append(makeInterruptedRecord(id: id, audioFileName: audioFileName))

        let harness = try makeHarness(recordLog: realLog)
        // The pipeline resolves audio against its own session directory, so point a
        // second pipeline at the directory the record was written into.
        let recovering = DictationPipeline(
            audioEngine: harness.audio,
            makeRecorder: { FakeSegmentRecorder(directory: directory) },
            makeTranscriber: { FakeTranscriber() },
            planner: SegmentPlanner(),
            inserter: harness.inserter,
            recordLog: realLog,
            sessionDirectory: directory,
            apiKey: { "test-key" },
            micPolicy: { .default })

        let unfinished = await recovering.recoverUnfinished()

        XCTAssertEqual(unfinished.map(\.id), [id],
                       "an interrupted capture comes back as a retryable record")
    }

    func testRecoveryIgnoresRecordsWhoseAudioIsGone() async throws {
        let directory = try tempDirectory()
        let realLog = DictationRecordLog(fileURL: directory.appendingPathComponent("records.jsonl"))
        let id = UUID()
        // The record names an audio file the retention sweep has already purged.
        try await realLog.append(makeInterruptedRecord(id: id, audioFileName: "\(id.uuidString).flac"))

        let harness = try makeHarness(recordLog: realLog)
        let recovering = DictationPipeline(
            audioEngine: harness.audio,
            makeRecorder: { FakeSegmentRecorder(directory: directory) },
            makeTranscriber: { FakeTranscriber() },
            planner: SegmentPlanner(),
            inserter: harness.inserter,
            recordLog: realLog,
            sessionDirectory: directory,
            apiKey: { "test-key" },
            micPolicy: { .default })

        let unfinished = await recovering.recoverUnfinished()

        XCTAssertTrue(unfinished.isEmpty, "a record with no audio can never be retried")
    }

    // MARK: - Ported invariant: a cancelled start installs no orphan session

    func testEndDuringSuspendedAudioStartCannotCreateAnOrphanSession() async throws {
        let harness = try makeHarness()
        harness.audio.suspendStart = true
        await harness.pipeline.begin(trigger: .pushToTalk)
        await waitUntil({ harness.audio.isStartSuspended }, "the start suspends on permission")

        let ending = Task { @MainActor in await harness.pipeline.end() }
        await waitUntil({ harness.pipeline.phase != .arming }, "end leaves .arming immediately")

        // The permission result arrives only after key-up has cancelled startup.
        harness.audio.resumeStart()
        await ending.value
        // Wait for the attempt itself to resolve, not merely for `end` to return: a
        // pipeline that never joined the cancelled start would otherwise be asked
        // about a session it was still in the middle of installing.
        await waitUntil({ harness.audio.startAttemptsResolved == 1 },
                        "the suspended start attempt resolves")

        XCTAssertFalse(harness.audio.isRecording, "no microphone is left running")
        XCTAssertEqual(harness.audio.startCount, 0, "a cancelled startup installs no session")
    }

    // MARK: - Ported invariant: ending twice finalizes once

    func testEndingTwiceFinalizesOnlyOnce() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)

        // The real racing pair is an auto-stop and a key-up arriving together.
        async let first: Void = harness.pipeline.end()
        async let second: Void = harness.pipeline.end()
        _ = await (first, second)

        XCTAssertEqual(harness.recorder.finishCount, 1, "the files are closed once")
        XCTAssertEqual(harness.inserter.inserted.count, 1, "the transcript is typed once")
    }

    // MARK: - Failure handling

    func testAllSegmentsFailingInsertsNothingKeepsAudioAndReportsARetryableError() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.plan.text = { _ in nil }
        harness.recorder.closeSegment(speechDuration: 5)
        await harness.pipeline.end()

        XCTAssertTrue(harness.inserter.inserted.isEmpty, "nothing is inserted when everything failed")
        guard case .error(let message, let retryable) = harness.pipeline.phase else {
            return XCTFail("expected an error phase, got \(harness.pipeline.phase)")
        }
        XCTAssertTrue(retryable)
        XCTAssertTrue(message.lowercased().contains("audio saved"),
                      "the user is told their words survived: \(message)")
        XCTAssertTrue(exists(harness.recorder.sessionURL), "the session audio is kept")
        XCTAssertEqual(harness.recorder.deleteSegmentFilesCount, 0,
                       "segment audio is kept so the failure can be retried")
        XCTAssertTrue(harness.recorder.segmentURLs.allSatisfy(exists))
    }

    func testPartialSegmentFailureInsertsTheRestWithTheFailureMarker() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.plan.text = { $0 == 0 ? nil : "the second half" }
        harness.recorder.closeSegment(speechDuration: 5)
        await harness.pipeline.end()

        XCTAssertEqual(harness.inserter.inserted,
                       ["\(TranscriptStitcher.failureMarker) the second half"],
                       "a dead segment leaves a visible hole; the rest still lands")
        XCTAssertEqual(harness.recorder.deleteSegmentFilesCount, 0,
                       "a partially failed capture keeps every segment file")
    }

    func testAudioStartFailureKeepsTheAudioAndReportsAnError() async throws {
        let harness = try makeHarness()
        harness.audio.startError = AudioEngineError.permissionDenied

        await harness.pipeline.begin(trigger: .pushToTalk)
        await waitUntil({
            if case .error = harness.pipeline.phase { return true }
            return false
        }, "a failed start surfaces as an error")

        XCTAssertTrue(harness.inserter.inserted.isEmpty)
        XCTAssertEqual(harness.made.recorders[0].discardCount, 0,
                       "a failed start never deletes what was already captured")
        XCTAssertTrue(exists(harness.made.recorders[0].sessionURL))
    }

    // MARK: - Cancel

    func testCancelKeepsTheSessionAudioAndMarksTheRecordCancelled() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        let sessionURL = harness.recorder.sessionURL

        await harness.pipeline.cancel()

        XCTAssertTrue(harness.inserter.inserted.isEmpty, "a cancelled capture inserts nothing")
        XCTAssertTrue(exists(sessionURL), "cancelled audio still reaches History")
        XCTAssertEqual(harness.recorder.discardCount, 0, "cancel must never delete the recording")
        XCTAssertEqual(harness.pipeline.phase, .idle)

        let records = try XCTUnwrap(harness.fakeRecordLog).records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.outcome, .cancelled)
    }

    // MARK: - Anti-hallucination gate

    func testSilentTailSegmentIsNeverDispatched() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.recorder.tailSpeechDuration = 0.1     // below the 0.3 s dispatch floor
        harness.recorder.closeSegment(speechDuration: 5)

        await harness.pipeline.end()

        XCTAssertEqual(harness.transcriber.dispatches.map(\.index), [0],
                       "two segments were closed; only the one holding speech was sent")
    }

    func testASegmentWithSpeechIsDispatchedExactlyOnce() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.recorder.closeSegment(speechDuration: 5)

        await harness.pipeline.end()

        XCTAssertEqual(harness.transcriber.dispatches.map(\.index), [0, 1],
                       "the mid-recording cut is not re-sent by the end-of-recording sweep")
    }

    // MARK: - Success

    func testSegmentFilesAreDeletedAfterSuccessAndTheSessionFileSurvives() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.recorder.closeSegment(speechDuration: 5)
        let sessionURL = harness.recorder.sessionURL
        let segmentURLs = harness.recorder.segmentURLs

        await harness.pipeline.end()

        XCTAssertFalse(harness.inserter.inserted.isEmpty)
        XCTAssertEqual(harness.recorder.deleteSegmentFilesCount, 1)
        XCTAssertTrue(segmentURLs.allSatisfy { !exists($0) }, "the temporaries are swept")
        XCTAssertTrue(exists(sessionURL), "the durable session recording survives")
    }

    func testNeverStoreAudioDeletesOnlyTheSuccessfulSessionAndClearsItsRecord() async throws {
        let harness = try makeHarness(neverStoreAudio: { true })
        await beginAndArm(harness)
        let sessionURL = try XCTUnwrap(harness.recorder.sessionURL)

        await harness.pipeline.end()

        XCTAssertFalse(exists(sessionURL))
        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertNil(record.audioFileName)
        XCTAssertEqual(record.audioBytes, 0)
    }

    func testNeverStoreAudioKeepsAFailedSessionRetryable() async throws {
        let harness = try makeHarness(neverStoreAudio: { true })
        await beginAndArm(harness)
        harness.plan.text = { _ in nil }
        let sessionURL = try XCTUnwrap(harness.recorder.sessionURL)

        await harness.pipeline.end()

        XCTAssertTrue(exists(sessionURL))
        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertEqual(record.audioFileName, sessionURL.lastPathComponent)
    }

    func testSuccessReportsWordCountAndWordsPerMinute() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.recorder.sessionDuration = 6          // six seconds of speech
        harness.plan.text = { _ in "one two three four five six" }

        await harness.pipeline.end()

        XCTAssertEqual(harness.pipeline.phase, .success(words: 6, wpm: 60))
    }

    func testTheInsertedTranscriptAndItsMetricsAreRecorded() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.recorder.sessionDuration = 12
        harness.plan.text = { _ in "hello there world" }

        await harness.pipeline.end()

        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertEqual(record.finalText, "hello there world")
        XCTAssertEqual(record.rawText, "hello there world")
        XCTAssertEqual(record.wordCount, 3)
        XCTAssertEqual(record.speakingDuration, 12)
        XCTAssertEqual(record.segmentCount, 1)
        XCTAssertEqual(record.outcome, .inserted)
        XCTAssertEqual(record.insertionOutcome, "insertedDirect")
        XCTAssertTrue(record.voiceProcessingActive)
        XCTAssertEqual(record.audioFileName, harness.recorder.sessionURL?.lastPathComponent)
    }

    // MARK: - Echo cancellation and audio-path isolation

    func testEveryCaptureRequestsVoiceProcessing() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        await harness.pipeline.end()
        await beginAndArm(harness, trigger: .toggle)
        await harness.pipeline.end()

        XCTAssertEqual(harness.audio.requestedVoiceProcessing, [true, true],
                       "echo cancellation is the differentiator; it must never regress to off")
    }

    func testCaptureSettingsRefreshForTheNextDictationWithoutChangingOneInFlight() async throws {
        var current = DictationPipeline.Configuration.default
        let harness = try makeHarness(configurationProvider: { current })

        await beginAndArm(harness)
        current.transcriptionModel = "new-model"
        current.language = "de"
        current.voiceProcessing = false
        await harness.pipeline.end()

        await beginAndArm(harness, trigger: .toggle)
        await harness.pipeline.end()

        XCTAssertEqual(harness.audio.requestedVoiceProcessing, [true, false])
        XCTAssertEqual(harness.made.transcribers[0].dispatches.first?.model,
                       DictationPipeline.Configuration.default.transcriptionModel)
        XCTAssertNil(harness.made.transcribers[0].dispatches.first?.language)
        XCTAssertEqual(harness.made.transcribers[1].dispatches.first?.model, "new-model")
        XCTAssertEqual(harness.made.transcribers[1].dispatches.first?.language, "de")
    }

    func testConvertedBuffersReachTheRecorderOffTheMainActor() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)

        XCTAssertGreaterThan(harness.recorder.ingestCount, 0, "the recorder saw audio")
        XCTAssertFalse(harness.recorder.sawIngestOnMainThread,
                       "per-buffer work must never touch the main thread")
    }

    // MARK: - Device loss

    func testDeviceLossMidCaptureFinalizesAndTranscribesWhatExists() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.plan.text = { _ in "partial transcript" }

        harness.audio.simulateActiveDeviceLoss()

        await waitUntil({ !harness.inserter.inserted.isEmpty }, "the partial capture finishes")
        XCTAssertEqual(harness.inserter.inserted, ["partial transcript"])
        XCTAssertFalse(harness.audio.isRecording)
    }

    // MARK: - Modes (resolved, not yet applied)

    func testSwitchModeChangesTheModeRecorded() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.pipeline.switchMode(to: Mode.code.id)

        XCTAssertEqual(harness.pipeline.activeModeID, Mode.code.id,
                       "the menu glyph must resolve the active mode identity")

        guard case .recording(_, let modeName) = harness.pipeline.phase else {
            return XCTFail("expected .recording, got \(harness.pipeline.phase)")
        }
        XCTAssertEqual(modeName, Mode.code.name)

        await harness.pipeline.end()
        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertEqual(record.modeID, Mode.code.id)
    }

    func testSwitchModeIgnoresAnUnknownMode() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.pipeline.switchMode(to: "no-such-mode")

        guard case .recording(_, let modeName) = harness.pipeline.phase else {
            return XCTFail("expected .recording, got \(harness.pipeline.phase)")
        }
        XCTAssertEqual(modeName, Mode.verbatim.name, "an unknown id leaves the active mode alone")
    }

    // MARK: - Modes: resolution happens once, at begin

    func testTheModeIsResolvedFromThePerAppMapAtBegin() async throws {
        let world = ModeWorld()
        world.perAppMap = ["com.test.app": Mode.email.id]
        let harness = try makeHarness(configuration: cleanConfiguration(), world: world)
        harness.plan.text = { _ in "hello" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.chat.calls.map(\.model), [Mode.email.model],
                       "the frontmost app's mapping outranks the global default (§6.3)")
        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertEqual(record.modeID, Mode.email.id)
    }

    func testAnExplicitModeOutranksThePerAppMapping() async throws {
        let world = ModeWorld()
        world.perAppMap = ["com.test.app": Mode.email.id]
        let harness = try makeHarness(configuration: cleanConfiguration(), world: world)
        harness.plan.text = { _ in "hello" }

        await harness.pipeline.begin(trigger: .toggle, explicitModeID: Mode.note.id)
        await waitUntil({ harness.pipeline.phase.isRecording }, "the capture arms")
        await harness.pipeline.end()

        XCTAssertEqual(harness.chat.calls.map(\.model), [Mode.note.model])
    }

    /// The trap this whole task turns on: dictate into Slack, switch to Chrome
    /// mid-sentence, and Chrome's mode must not claim words spoken into Slack.
    func testTheModeResolvedAtBeginSurvivesTheFrontmostAppChanging() async throws {
        let world = ModeWorld()
        world.perAppMap = [
            "com.slack": Mode.email.id,     // uses the LLM
            "com.chrome": Mode.code.id,     // does not
        ]
        let harness = try makeHarness(configuration: cleanConfiguration(), world: world)
        harness.inserter.frontmostBundleID = "com.slack"
        harness.plan.text = { _ in "hello" }

        await beginAndArm(harness)
        // The user moves to another app while still speaking.
        harness.inserter.frontmostBundleID = "com.chrome"
        await harness.pipeline.end()

        XCTAssertEqual(harness.chat.calls.map(\.model), [Mode.email.model],
                       "resolving at insert time would have applied Chrome's mode")
        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertEqual(record.modeID, Mode.email.id)
        XCTAssertEqual(record.targetBundleID, "com.slack")
    }

    func testSwitchingModeMidRecordingChangesTheModeActuallyApplied() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in "hello" }

        await beginAndArm(harness)
        harness.pipeline.switchMode(to: Mode.email.id)
        await harness.pipeline.end()

        XCTAssertEqual(harness.chat.calls.map(\.model), [Mode.email.model],
                       "1–9 changes the mode that is applied, not just the label")
    }

    func testSwitchingToAPassThroughModeMidRecordingCancelsTheLLMPass() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in "hello" }

        await beginAndArm(harness)
        harness.pipeline.switchMode(to: Mode.verbatim.id)
        await harness.pipeline.end()

        XCTAssertEqual(harness.chat.callCount, 0)
        XCTAssertEqual(harness.inserter.inserted, ["hello"])
    }

    // MARK: - Modes: a pass-through mode is free

    func testAPassThroughModeMakesZeroChatRequests() async throws {
        // `.default` is Verbatim, which is the point.
        let harness = try makeHarness()
        harness.plan.text = { _ in "hello there" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.chat.callCount, 0,
                       "usesLLM == false means no request at all, not a request nobody reads")
        XCTAssertEqual(harness.inserter.inserted, ["hello there"])
        XCTAssertNil(harness.pipeline.notice)
    }

    // MARK: - Modes: the LLM pass

    func testLocalCleanKeepsASRAndSkipsCloudForAllTranscriptionProviders() async throws {
        for provider in TranscriptionProvider.allCases {
            let world = ModeWorld()
            let local = StubLocalCleanup(.success("Hello there."))
            world.localCleanup = local
            var config = cleanConfiguration()
            config.transcriptionProvider = provider
            let harness = try makeHarness(configuration: config, availableModes: { self.localCleanModes() }, world: world)
            harness.plan.text = { _ in "um hello there" }
            await beginAndArm(harness)
            await harness.pipeline.end()
            XCTAssertEqual(harness.inserter.inserted, ["Hello there."])
            XCTAssertTrue(harness.chat.calls.isEmpty)
            let calls = await local.calls
            XCTAssertEqual(calls, ["um hello there"])
            let record = try XCTUnwrap(harness.fakeRecordLog?.records.first)
            XCTAssertEqual(record.rawText, "um hello there")
            XCTAssertEqual(record.usageEntries?.last?.providerID, "localS1Mini")
        }
    }

    func testLocalCleanPreservesPartialTranscriptAndHistoryRetry() async throws {
        for rest in ["the second half", "um uh"] {
            let world = ModeWorld()
            let local = StubLocalCleanup(.success(""))
            world.localCleanup = local
            let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { self.localCleanModes() }, world: world)
            await beginAndArm(harness)
            harness.plan.text = { $0 == 0 ? nil : rest }
            harness.recorder.closeSegment(speechDuration: 5)
            await harness.pipeline.end()
            let expected = "\(TranscriptStitcher.failureMarker) \(rest)"
            XCTAssertEqual(harness.inserter.inserted, [expected])
            let calls = await local.calls
            XCTAssertTrue(calls.isEmpty)
            XCTAssertTrue(harness.chat.calls.isEmpty)
            let record = try XCTUnwrap(harness.fakeRecordLog?.records.first)
            XCTAssertEqual(record.rawText, expected)
            XCTAssertEqual(record.finalText, expected)
            let row = HistoryRow(record: record, modeName: "Clean", searchText: "")
            XCTAssertTrue(row.hasPartialTranscript)
            XCTAssertTrue(row.canRetryTranscription)
            XCTAssertEqual(harness.recorder.deleteSegmentFilesCount, 0)
        }
    }

    func testPartialGemmaSelectionEditPreservesSelectionAndHistoryRetry() async throws {
        var mode = Mode.clean
        mode.cleanupChoice = .localGemma
        mode.contextOptions = ModeContextOptions(selectedText: true, editSelectedText: true)
        let world = ModeWorld()
        world.snapshot.selectedText = "Original selection"
        let local = StubLocalCleanup(.success("Should not run"))
        world.localCleanup = local
        let selected = mode
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { [selected] }, world: world)
        await beginAndArm(harness)
        harness.plan.text = { $0 == 0 ? nil : "make it uppercase" }
        harness.recorder.closeSegment(speechDuration: 5)
        await harness.pipeline.end()

        XCTAssertTrue(harness.inserter.inserted.isEmpty)
        let edit = try XCTUnwrap(harness.inserter.selectionEdits.first)
        XCTAssertEqual(edit.text, "Original selection")
        XCTAssertEqual(edit.original, "Original selection")
        XCTAssertEqual(edit.target, "com.test.app")
        let calls = await local.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(harness.chat.calls.isEmpty)
        let record = try XCTUnwrap(harness.fakeRecordLog?.records.first)
        XCTAssertEqual(record.rawText, "\(TranscriptStitcher.failureMarker) make it uppercase")
        XCTAssertEqual(record.finalText, "Original selection")
        XCTAssertTrue(record.isWorthRecovering)
        XCTAssertTrue(HistoryRow(record: record, modeName: "Clean", searchText: "").canRetryTranscription)
        XCTAssertEqual(harness.recorder.deleteSegmentFilesCount, 0)
    }

    func testLocalCleanAppliesReplacementsBeforeCleanup() async throws {
        let world = ModeWorld()
        world.replacements = [rule("capture", "Captur")]
        let local = StubLocalCleanup(.success("Captur works."))
        world.localCleanup = local
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { self.localCleanModes() }, world: world)
        harness.plan.text = { _ in "capture works" }
        await beginAndArm(harness)
        await harness.pipeline.end()
        let calls = await local.calls
        XCTAssertEqual(calls, ["Captur works"])
        XCTAssertEqual(harness.fakeRecordLog?.records.first?.rawText, "capture works")
    }

    func testCancellationDuringLocalCleanupCannotInsert() async throws {
        let world = ModeWorld()
        let local = HeldLocalCleanup()
        world.localCleanup = local
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { self.localCleanModes() }, world: world)
        await beginAndArm(harness)
        let ending = Task { @MainActor in await harness.pipeline.end() }
        await waitUntil({ local.waiting }, "local cleanup starts")
        await harness.pipeline.cancel()
        local.release()
        await ending.value
        XCTAssertTrue(harness.inserter.inserted.isEmpty)
        XCTAssertTrue(harness.chat.calls.isEmpty)
        XCTAssertEqual(harness.fakeRecordLog?.records.first?.outcome, .cancelled)
    }

    func testLocalCleanHistoryRetryUsesLocalAndKeepsRawText() async throws {
        let world = ModeWorld()
        let local = StubLocalCleanup(.success("Cleaned text."))
        world.localCleanup = local
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { self.localCleanModes() }, world: world)
        harness.plan.text = { _ in "um original text" }
        await beginAndArm(harness)
        await harness.pipeline.end()
        let record = try XCTUnwrap(harness.fakeRecordLog?.records.first)
        await harness.pipeline.retryMode(recordID: record.id)
        let calls = await local.calls
        XCTAssertEqual(calls, ["um original text", "um original text"])
        XCTAssertTrue(harness.chat.calls.isEmpty)
        XCTAssertEqual(harness.fakeRecordLog?.records.first?.rawText, "um original text")
        XCTAssertEqual(harness.inserter.inserted.count, 1, "History mode retry does not insert")
    }

    func testLocalCleanEmptyDoesNotTouchInserterAndRetainsRawHistory() async throws {
        let world = ModeWorld()
        world.localCleanup = StubLocalCleanup(.success(""))
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { self.localCleanModes() }, world: world)
        harness.plan.text = { _ in "um uh" }
        await beginAndArm(harness)
        await harness.pipeline.end()
        XCTAssertTrue(harness.inserter.inserted.isEmpty)
        XCTAssertTrue(harness.chat.calls.isEmpty)
        XCTAssertNil(harness.pipeline.notice)
        let record = try XCTUnwrap(harness.fakeRecordLog?.records.first)
        XCTAssertEqual(record.rawText, "um uh")
        XCTAssertEqual(record.finalText, "")
        XCTAssertEqual(record.insertionOutcome, "emptyCleanup")
    }

    func testLocalCleanFailureKeepsTextAndNeverFallsBackToCloud() async throws {
        for error in [S1MiniError.notDownloaded, .timedOut, .generationFailed, .inputTooLong] {
            let world = ModeWorld()
            world.localCleanup = StubLocalCleanup(.failure(error))
            let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { self.localCleanModes() }, world: world)
            harness.plan.text = { _ in "keep my words" }
            await beginAndArm(harness)
            await harness.pipeline.end()
            XCTAssertEqual(harness.inserter.inserted, ["keep my words"])
            XCTAssertTrue(harness.chat.calls.isEmpty)
            XCTAssertEqual(harness.pipeline.notice, .modeSkipped(modeName: Mode.clean.name))
            XCTAssertEqual(harness.fakeRecordLog?.records.first?.usageEntries?.last?.outcome, .failed)
        }
    }

    func testUnavailableLocalSelectionKeepsTextWithoutCloudOrContextReads() async throws {
        let unknown = ModeCleanupChoice(rawValue: "future-model")!
        var custom = Mode.clean
        custom.cleanupChoice = unknown
        custom.includeClipboardContext = true
        custom.contextOptions.selectedText = true
        let selected = custom
        let world = ModeWorld()
        let coordinator = LocalCleanupCoordinator(runtimes: [:])
        world.localCleanup = coordinator
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { [selected] }, world: world)
        harness.plan.text = { _ in "keep my words" }
        await beginAndArm(harness)
        await harness.pipeline.end()
        XCTAssertEqual(harness.inserter.inserted, ["keep my words"])
        XCTAssertTrue(harness.chat.calls.isEmpty)
        XCTAssertEqual(world.clipboardReads, 0)
        XCTAssertEqual(world.snapshotReads, 0)
        XCTAssertEqual(harness.pipeline.notice, .modeSkipped(modeName: custom.name))
        let usage = harness.fakeRecordLog?.records.first?.usageEntries?.last
        XCTAssertEqual(usage?.providerID, unknown.rawValue)
        XCTAssertEqual(usage?.outcome, .failed)
        XCTAssertNil(usage?.actualModelID)
        await coordinator.shutdown()
    }

    func testLocalChoiceLeavesEmailAndVerbatimWorking() async throws {
        for mode in [Mode.email, .verbatim] {
            let world = ModeWorld()
            let local = StubLocalCleanup(.failure(S1MiniError.generationFailed))
            world.localCleanup = local
            var config = cleanConfiguration()
            config.defaultModeID = mode.id
            let harness = try makeHarness(configuration: config, availableModes: { self.localCleanModes() }, world: world)
            await beginAndArm(harness)
            await harness.pipeline.end()
            let calls = await local.calls
            XCTAssertTrue(calls.isEmpty)
            XCTAssertEqual(harness.chat.calls.count, mode.usesLLM ? 1 : 0)
        }
    }

    func testAnLLMModeInsertsTheRefinedTextOnce() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in "um hello there" }
        harness.chat.result = { _ in "Hello there." }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.inserter.inserted, ["Hello there."],
                       "insertion happens once, on completion — never streamed in")
        XCTAssertEqual(harness.chat.calls.count, 1)
        XCTAssertEqual(harness.chat.calls.first?.userMessage, "um hello there")
        XCTAssertEqual(harness.chat.calls.first?.provider, .openRouter)
        XCTAssertEqual(harness.chat.calls.first?.model, "google/gemini-3.8-flash")
        XCTAssertEqual(harness.chat.calls.first?.reasoning, .low)
        XCTAssertEqual(harness.chat.calls.first?.timeout,
                       Mode.clean.refinementProvider.defaultTimeout)
        XCTAssertEqual(harness.chat.calls.first?.temperature, Mode.clean.temperature)
        XCTAssertNil(harness.pipeline.notice)
    }

    func testRefinementUsageIsAttributedToTheActualProviderAndModel() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in "hello" }
        harness.chat.usage = RefinementUsage(
            promptTokens: 120,
            completionTokens: 14,
            reasoningTokens: 4,
            cachedTokens: 20,
            costUSD: Decimal(string: "0.0012"),
            costKind: .billed)

        await beginAndArm(harness)
        await harness.pipeline.end()

        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        let usage = try XCTUnwrap(record.usageEntries?.first(where: { $0.stage == .refinement }))
        XCTAssertEqual(usage.providerID, RefinementProviderID.openRouter.rawValue)
        XCTAssertEqual(usage.requestedModelID, "google/gemini-3.8-flash")
        XCTAssertEqual(usage.actualModelID, "google/gemini-3.8-flash")
        XCTAssertEqual(usage.promptTokens, 120)
        XCTAssertEqual(usage.completionTokens, 14)
        XCTAssertEqual(usage.reasoningTokens, 4)
        XCTAssertEqual(usage.cachedTokens, 20)
        XCTAssertEqual(usage.costUSD, Decimal(string: "0.0012"))
        XCTAssertEqual(usage.costKind, .billed)
    }

    func testTheRecordKeepsTheRawTranscriptAlongsideTheRefinedText() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in "um hello there" }
        harness.chat.result = { _ in "Hello there." }

        await beginAndArm(harness)
        await harness.pipeline.end()

        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertEqual(record.rawText, "um hello there", "what Whisper heard")
        XCTAssertEqual(record.finalText, "Hello there.", "what reached the cursor")
        XCTAssertGreaterThan(record.editDistanceRawToFinal, 0)
    }

    /// Spec §17: every one of these takes a different code path inside the client,
    /// and all of them owe the user their words.
    func testEveryLLMFailureInsertsTheRawTranscriptAndReportsTheModeSkipped() async throws {
        let failures: [(name: String, error: Error)] = [
            ("timeout", GroqChatError.timedOut),
            ("http", GroqChatError.http(status: 500)),
            ("offline", GroqChatError.offline),
            ("decoding", GroqChatError.decoding),
            ("cancellation", CancellationError()),
            ("unknown", FakeFailure.boom("something else entirely")),
        ]

        for failure in failures {
            let harness = try makeHarness(configuration: cleanConfiguration())
            harness.plan.text = { _ in "the words that were spoken" }
            harness.chat.result = { _ in throw failure.error }

            await beginAndArm(harness)
            await harness.pipeline.end()

            XCTAssertEqual(harness.inserter.inserted, ["the words that were spoken"],
                           "\(failure.name): a mode failure never costs the user their words")
            XCTAssertEqual(harness.pipeline.notice, .modeSkipped(modeName: Mode.clean.name),
                           "\(failure.name): the capsule has to say the mode was skipped")
            let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
            XCTAssertEqual(record.outcome, .inserted, "\(failure.name)")
            XCTAssertEqual(record.finalText, "the words that were spoken", "\(failure.name)")
            let usage = try XCTUnwrap(
                record.usageEntries?.first(where: { $0.stage == .refinement }))
            XCTAssertEqual(usage.providerID, RefinementProviderID.openRouter.rawValue)
            XCTAssertEqual(usage.costKind, .unknown)
            XCTAssertNil(usage.costUSD)
        }
    }

    func testAContentFreeLLMResponseIsAFailureNotAnInstructionToInsertNothing() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in "the words that were spoken" }
        harness.chat.result = { _ in "   \n  " }
        harness.chat.usage = RefinementUsage(
            promptTokens: 25,
            completionTokens: 1,
            reasoningTokens: nil,
            cachedTokens: nil,
            costUSD: Decimal(string: "0.0004"),
            costKind: .billed)

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.inserter.inserted, ["the words that were spoken"])
        XCTAssertEqual(harness.pipeline.notice, .modeSkipped(modeName: Mode.clean.name))
        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        let usage = try XCTUnwrap(
            record.usageEntries?.first(where: { $0.stage == .refinement }))
        XCTAssertEqual(usage.costUSD, Decimal(string: "0.0004"))
        XCTAssertEqual(usage.costKind, .billed)
    }

    func testAnLLMModeWithNoChatClientIsReportedAsSkipped() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration(),
                                      withChatClient: false)
        harness.plan.text = { _ in "hello" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.inserter.inserted, ["hello"])
        XCTAssertEqual(harness.pipeline.notice, .modeSkipped(modeName: Mode.clean.name),
                       "an unwired client is a skip, not a silent pass-through")
    }

    func testTheCaptureShowsRefiningWhileTheLLMPassIsInFlight() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in "hello" }
        harness.chat.hold()

        await beginAndArm(harness)
        let ending = Task { @MainActor in await harness.pipeline.end() }
        await waitUntil({ harness.chat.isWaitingForRelease }, "the mode pass starts")

        XCTAssertEqual(harness.pipeline.phase, .refining(modeName: Mode.clean.name))
        harness.chat.release()
        await ending.value
    }

    func testACancelDuringTheLLMPassInsertsNothing() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in "hello" }
        harness.chat.hold()

        await beginAndArm(harness)
        let ending = Task { @MainActor in await harness.pipeline.end() }
        await waitUntil({ harness.chat.isWaitingForRelease }, "the mode pass starts")

        await harness.pipeline.cancel()
        harness.chat.release()
        await ending.value

        XCTAssertTrue(harness.inserter.inserted.isEmpty,
                      "a revoked capture must not type into someone's editor 2.5 s later")
    }

    func testTheModePassIsSkippedEntirelyWhenNothingWasHeard() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in nil }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.chat.callCount, 0, "there is nothing to refine")
    }

    // MARK: - Modes: what the model is told

    func testTheSystemMessageCarriesTheModePromptAndTheSpellingList() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme"), term("Groq", soundsLike: "grock")]
        let harness = try makeHarness(configuration: cleanConfiguration(), world: world)
        harness.plan.text = { _ in "hello" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        let system = try XCTUnwrap(harness.chat.calls.first?.systemMessage)
        XCTAssertTrue(system.contains(PromptAssembler.spellingHeader))
        XCTAssertTrue(system.contains("Acme"))
        XCTAssertTrue(system.contains("Groq (heard as \"grock\")"))
        XCTAssertTrue(system.contains(Mode.requiredAntiInjectionClause(for: .clean)))
    }

    /// Spec §7.3: the 224-token cap is Whisper's. The LLM spelling list "has no such
    /// cap and receives more terms", so a term the ranker had to drop must still be
    /// spelled for the model.
    func testTheSpellingListIsNotCappedToWhispersPromptBudget() async throws {
        let world = ModeWorld()
        // Far more than 224 tokens' worth, so the Whisper selection must truncate.
        world.vocabulary = (0..<300).map { term("Terminology\($0)") }
        let harness = try makeHarness(configuration: cleanConfiguration(), world: world)
        harness.plan.text = { _ in "hello" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        let whisperPrompt = try XCTUnwrap(harness.transcriber.dispatches.first?.vocabularyPrompt)
        let system = try XCTUnwrap(harness.chat.calls.first?.systemMessage)
        let dropped = try XCTUnwrap(
            world.vocabulary.map(\.text).first { !whisperPrompt.contains($0) },
            "the vocabulary must be big enough that the Whisper prompt truncates")
        XCTAssertTrue(system.contains(dropped),
                      "a term Whisper's budget could not fit still reaches the model")
    }

    func testTheClipboardIsNotEvenReadUnlessTheModeAsksForIt() async throws {
        // Clean does not set `includeClipboardContext`.
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in "hello" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.world.clipboardReads, 0,
                       "reading the pasteboard is the privacy-relevant act, not sending it")
        let system = try XCTUnwrap(harness.chat.calls.first?.systemMessage)
        XCTAssertFalse(system.contains("clipboard contents"))
    }

    func testAModeThatAsksForTheClipboardGetsIt() async throws {
        var mode = Mode.clean
        mode.id = "clipboard-mode"
        mode.includeClipboardContext = true
        mode.includeAppNameContext = true
        var configuration = DictationPipeline.Configuration.default
        configuration.defaultModeID = mode.id

        let harness = try makeHarness(configuration: configuration,
                                      availableModes: { [mode] })
        harness.plan.text = { _ in "hello" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.world.clipboardReads, 1)
        let system = try XCTUnwrap(harness.chat.calls.first?.systemMessage)
        XCTAssertTrue(system.contains("clipboard contents"))
        XCTAssertTrue(system.contains("Test App"))
    }

    func testContextSnapshotAndClipboardStayAtRecordingStart() async throws {
        var mode = Mode.clean
        mode.includeClipboardContext = true
        mode.contextOptions.selectedText = true
        let world = ModeWorld()
        world.snapshot.selectedText = "Original selection"
        world.clipboard = "Original clipboard"
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { [mode] }, world: world)
        harness.plan.text = { _ in "hello" }
        await beginAndArm(harness)
        world.snapshot.selectedText = "Later selection"
        world.clipboard = "Later clipboard"
        await harness.pipeline.end()
        let system = try XCTUnwrap(harness.chat.calls.first?.systemMessage)
        XCTAssertTrue(system.contains("Original selection"))
        XCTAssertTrue(system.contains("Original clipboard"))
        XCTAssertFalse(system.contains("Later"))
        XCTAssertEqual(world.clipboardReads, 1)
        let stored = try XCTUnwrap(harness.fakeRecordLog?.records.last)
        XCTAssertTrue(stored.contextSummary?.contains("selection:") == true)
        XCTAssertFalse(String(data: try JSONEncoder().encode(stored), encoding: .utf8)!.contains("Original selection"))
    }

    func testEditorRefreshPreservesStartSelectionAndRetryDoesNotRefresh() async throws {
        var mode = Mode.clean
        mode.contextOptions = ModeContextOptions(selectedText: true, editorText: true,
            applicationDetails: true, refreshEditorBeforeRefinement: true)
        let world = ModeWorld()
        world.snapshot = ContextSnapshot(selectedText: "Start selection", editorText: "Start editor")
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { [mode] }, world: world)
        harness.plan.text = { _ in "hello" }
        await beginAndArm(harness)
        world.snapshot = ContextSnapshot(selectedText: "Later selection", editorText: "Refreshed editor", windowTitle: "Refreshed title")
        await harness.pipeline.end()
        let system = try XCTUnwrap(harness.chat.calls.first?.systemMessage)
        XCTAssertTrue(system.contains("Start selection"))
        XCTAssertFalse(system.contains("Later selection"))
        XCTAssertTrue(system.contains("Refreshed editor"))
        XCTAssertTrue(system.contains("Refreshed title"))
        XCTAssertEqual(world.snapshotReads, 2)
        let id = try XCTUnwrap(harness.fakeRecordLog?.records.last?.id)
        await harness.pipeline.retryMode(recordID: id)
        XCTAssertEqual(world.snapshotReads, 2)
    }

    func testUnavailableRefreshPreservesOriginalContext() async throws {
        var mode = Mode.clean
        mode.contextOptions = ModeContextOptions(selectedText: true, editorText: true, refreshEditorBeforeRefinement: true)
        let world = ModeWorld()
        world.snapshot = ContextSnapshot(selectedText: "Original selection", editorText: "Original editor")
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { [mode] }, world: world)
        await beginAndArm(harness)
        world.snapshot = ContextSnapshot(protectedField: true, targetUnavailable: true, status: "Target changed")
        await harness.pipeline.end()
        let system = try XCTUnwrap(harness.chat.calls.first?.systemMessage)
        XCTAssertTrue(system.contains("Original selection"))
        XCTAssertTrue(system.contains("Original editor"))
    }

    func testProtectedFieldSuppressesAppNameClipboardAndSystemContext() async throws {
        var mode = Mode.clean
        mode.includeAppNameContext = true
        mode.includeClipboardContext = true
        mode.contextOptions.dateTime = true
        let world = ModeWorld()
        world.snapshot.protectedField = true
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { [mode] }, world: world)
        await beginAndArm(harness)
        await harness.pipeline.end()
        let system = try XCTUnwrap(harness.chat.calls.first?.systemMessage)
        XCTAssertFalse(system.contains("Test App"))
        XCTAssertFalse(system.contains("clipboard contents"))
        XCTAssertFalse(system.contains("Recording date"))
    }

    func testMasterSwitchRevokesPreparedContextBeforeSending() async throws {
        var mode = Mode.clean
        mode.contextOptions.editorText = true
        mode.includeClipboardContext = true
        mode.includeAppNameContext = true
        let world = ModeWorld()
        world.snapshot.editorText = "Private editor"
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { [mode] }, world: world)
        await beginAndArm(harness)
        world.contextEnabled = false
        await harness.pipeline.end()
        let system = try XCTUnwrap(harness.chat.calls.first?.systemMessage)
        XCTAssertFalse(system.contains("Private editor"))
        XCTAssertFalse(system.contains("Test App"))
        XCTAssertFalse(system.contains("clipboard contents"))
    }

    func testModeSwitchCannotBroadenContextOrReadClipboardLater() async throws {
        var contextual = Mode.message
        contextual.contextOptions.selectedText = true
        contextual.includeClipboardContext = true
        let world = ModeWorld()
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { [.clean, contextual] }, world: world)
        await beginAndArm(harness)
        harness.pipeline.switchMode(to: contextual.id)
        await harness.pipeline.end()
        XCTAssertEqual(world.clipboardReads, 0)
        XCTAssertFalse(harness.chat.calls.first?.systemMessage.contains("clipboard contents") == true)
    }

    func testDuringRecordingCopyReplacesStartAndRetryNeverReadsClipboard() async throws {
        var mode = Mode.clean
        mode.includeClipboardContext = true
        let world = ModeWorld()
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { [mode] }, world: world)
        await beginAndArm(harness)
        world.clipboardUpdate = .replace("During recording")
        await harness.pipeline.end()
        XCTAssertTrue(harness.chat.calls.first?.systemMessage.contains("During recording") == true)
        let id = try XCTUnwrap(harness.fakeRecordLog?.records.last?.id)
        await harness.pipeline.retryMode(recordID: id)
        XCTAssertEqual(world.clipboardReads, 1)
        XCTAssertFalse(harness.chat.calls.last?.systemMessage.contains("During recording") == true)
    }

    func testWebsiteLookupDoesNotDelayAudioOrLoseRelease() async throws {
        let world = ModeWorld()
        world.websiteMap = ["example.com": "email"]
        var release: CheckedContinuation<String?, Never>?
        world.websiteHost = { _ in await withCheckedContinuation { release = $0 } }
        var contextualEmail = Mode.email
        contextualEmail.includeClipboardContext = true
        contextualEmail.contextOptions.selectedText = true
        world.snapshot.selectedText = "Pinned selection"
        world.clipboard = "Pinned clipboard"
        let harness = try makeHarness(configuration: cleanConfiguration(), availableModes: { [.clean, contextualEmail] }, world: world)
        await beginAndArm(harness)
        world.snapshot.selectedText = "Changed selection"
        world.clipboard = "Changed clipboard"
        XCTAssertTrue(harness.pipeline.phase.isRecording, "Audio is live while URL lookup is held")
        let ending = Task { await harness.pipeline.end() }
        await waitUntil({ !harness.pipeline.phase.holdsMicrophone }, "Release stops recording during URL lookup")
        release?.resume(returning: "example.com")
        await ending.value
        XCTAssertEqual(harness.fakeRecordLog?.records.last?.modeID, "email")
        XCTAssertTrue(harness.chat.calls.first?.systemMessage.contains("Pinned selection") == true)
        XCTAssertTrue(harness.chat.calls.first?.systemMessage.contains("Pinned clipboard") == true)
        XCTAssertFalse(harness.chat.calls.first?.systemMessage.contains("Changed") == true)
    }

    func testManualSwitchCancelsHeldWebsiteContextAndPreventsClipboardRead() async throws {
        let world = ModeWorld()
        world.websiteMap = ["example.com": "email"]
        var release: CheckedContinuation<String?, Never>?
        world.websiteHost = { _ in await withCheckedContinuation { release = $0 } }
        let harness = try makeHarness(configuration: cleanConfiguration(), world: world)
        await beginAndArm(harness)
        harness.pipeline.switchMode(to: "verbatim")
        release?.resume(returning: "example.com")
        await harness.pipeline.end()
        XCTAssertEqual(world.clipboardReads, 0)
        XCTAssertEqual(harness.chat.callCount, 0)
        XCTAssertEqual(harness.fakeRecordLog?.records.last?.modeID, "verbatim")
    }

    func testCancelledWebsiteLookupCannotReviveCaptureOrReadContext() async throws {
        let world = ModeWorld()
        world.websiteMap = ["example.com": "email"]
        var release: CheckedContinuation<String?, Never>?
        world.websiteHost = { _ in await withCheckedContinuation { release = $0 } }
        let harness = try makeHarness(configuration: cleanConfiguration(), world: world)
        await beginAndArm(harness)
        await harness.pipeline.cancel()
        release?.resume(returning: "example.com")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(world.clipboardReads, 0)
        XCTAssertEqual(harness.chat.callCount, 0)
        XCTAssertEqual(harness.pipeline.phase, .idle)
    }

    // MARK: - Replacements

    func testReplacementsAreAppliedBeforeTheLLMPass() async throws {
        let world = ModeWorld()
        world.replacements = [rule("Ackme", "Acme")]
        let harness = try makeHarness(configuration: cleanConfiguration(), world: world)
        harness.plan.text = { _ in "Ackme is a page builder" }
        harness.chat.result = { call in call.userMessage.uppercased() }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.chat.calls.first?.userMessage, "Acme is a page builder",
                       "the model must see the corrected noun, or it will correct it back")
        XCTAssertEqual(harness.inserter.inserted, ["ACME IS A PAGE BUILDER"])
    }

    func testReplacementsSurviveAnLLMFailure() async throws {
        let world = ModeWorld()
        world.replacements = [rule("Ackme", "Acme")]
        let harness = try makeHarness(configuration: cleanConfiguration(), world: world)
        harness.plan.text = { _ in "Ackme is a page builder" }
        harness.chat.result = { _ in throw GroqChatError.timedOut }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.inserter.inserted, ["Acme is a page builder"],
                       "the fallback is the post-replacement transcript, not the raw one")
    }

    func testReplacementsApplyToAPassThroughModeToo() async throws {
        let world = ModeWorld()
        world.replacements = [rule("Ackme", "Acme")]
        let harness = try makeHarness(world: world)   // Verbatim
        harness.plan.text = { _ in "Ackme ships" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.inserter.inserted, ["Acme ships"])
        XCTAssertEqual(harness.chat.callCount, 0)
    }

    func testTheRecordedRawTextIsWhatWhisperHeardNotWhatTheRulesRewrote() async throws {
        let world = ModeWorld()
        world.replacements = [rule("Ackme", "Acme")]
        let harness = try makeHarness(world: world)
        harness.plan.text = { _ in "Ackme ships" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertEqual(record.rawText, "Ackme ships")
        XCTAssertEqual(record.finalText, "Acme ships")
    }

    // MARK: - Vocabulary reaches Whisper

    func testTheRankedVocabularyIsSentAsWhispersPrompt() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme"), term("Groq", soundsLike: "grock")]
        let harness = try makeHarness(world: world)

        await beginAndArm(harness)
        await harness.pipeline.end()

        let prompt = try XCTUnwrap(harness.transcriber.dispatches.first?.vocabularyPrompt)
        XCTAssertFalse(prompt.isEmpty, "an empty prompt is the bug this test exists for")
        XCTAssertTrue(prompt.contains("Acme"))
        XCTAssertTrue(prompt.contains("Groq (grock)"))
    }

    func testTheWhisperPromptLeavesRoomForTheContinuityTail() async throws {
        let world = ModeWorld()
        world.vocabulary = (0..<300).map { term("Terminology\($0)") }
        let harness = try makeHarness(world: world)

        await beginAndArm(harness)
        await harness.pipeline.end()

        let prompt = try XCTUnwrap(harness.transcriber.dispatches.first?.vocabularyPrompt)
        let tokens = VocabularyRanker.estimatedTokens(in: prompt)
        XCTAssertLessThanOrEqual(
            tokens,
            VocabularyRanker.whisperPromptTokenBudget - DictationPipeline.continuityTailTokenReserve,
            "the ranker does the trimming, where the scoring lives — not assemblePrompt")
    }

    func testEverySegmentOfOneCaptureSendsTheSameVocabulary() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme")]
        let harness = try makeHarness(world: world)
        await beginAndArm(harness)

        harness.recorder.closeSegment(speechDuration: 3.0)
        // The user edits their vocabulary while still speaking.
        world.vocabulary = [term("Something Else Entirely")]
        await harness.pipeline.end()

        let prompts = Set(harness.transcriber.dispatches.map(\.vocabularyPrompt))
        XCTAssertEqual(harness.transcriber.dispatches.count, 2)
        XCTAssertEqual(prompts.count, 1, "the prompt must not flap mid-dictation")
        XCTAssertTrue(try XCTUnwrap(prompts.first).contains("Acme"))
    }

    func testTheRecordSaysHowManyTermsWereActuallySent() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme"), term("Groq"), term("Whisper")]
        let harness = try makeHarness(world: world)

        await beginAndArm(harness)
        await harness.pipeline.end()

        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertEqual(record.vocabularyTermsSent, 3)
    }

    func testTheReportedTermCountIsWhatFitNotWhatWasStored() async throws {
        let world = ModeWorld()
        world.vocabulary = (0..<300).map { term("Terminology\($0)") }
        let harness = try makeHarness(world: world)

        await beginAndArm(harness)
        await harness.pipeline.end()

        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertGreaterThan(record.vocabularyTermsSent, 0)
        XCTAssertLessThan(record.vocabularyTermsSent, 300,
                          "reporting the stored count would contradict the Vocabulary screen")
        let prompt = try XCTUnwrap(harness.transcriber.dispatches.first?.vocabularyPrompt)
        XCTAssertEqual(record.vocabularyTermsSent,
                       prompt.components(separatedBy: ", ").count)
    }

    func testAFailedDictationStillRecordsWhatItSent() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme")]
        let harness = try makeHarness(world: world)
        harness.plan.text = { _ in nil }

        await beginAndArm(harness)
        await harness.pipeline.end()

        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertEqual(record.vocabularyTermsSent, 1)
    }

    // MARK: - Vocabulary ranking signals

    func testTermsThatAppearInTheTranscriptGainTheirRankingSignals() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme", useCount: 2), term("Groq")]
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = try makeHarness(world: world, now: { stamp })
        harness.plan.text = { _ in "Acme is a page builder" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        let acme = try XCTUnwrap(world.vocabulary.first { $0.text == "Acme" })
        XCTAssertEqual(acme.useCount, 3)
        XCTAssertEqual(acme.lastUsed, stamp)
        XCTAssertEqual(acme.appBundleIDs, ["com.test.app"],
                       "app affinity can never fire until something writes this")

        let groq = try XCTUnwrap(world.vocabulary.first { $0.text == "Groq" })
        XCTAssertEqual(groq.useCount, 0, "a term nobody said gains nothing")
        XCTAssertNil(groq.lastUsed)
        XCTAssertTrue(groq.appBundleIDs.isEmpty)
    }

    func testUsageIsWrittenOncePerDictationNotOncePerTerm() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme"), term("Groq"), term("Whisper"), term("Captur")]
        let harness = try makeHarness(world: world)
        harness.plan.text = { _ in "Acme Groq Whisper Captur" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(world.writes.count, 1,
                       "four matched terms must not be four rewrites of the whole file")
    }

    func testNothingIsWrittenWhenNoTermWasSpoken() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme")]
        let harness = try makeHarness(world: world)
        harness.plan.text = { _ in "nothing relevant here" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertTrue(world.writes.isEmpty)
    }

    func testUsageIsMergedOntoTheCurrentListNotTheSnapshotTakenAtBegin() async throws {
        let world = ModeWorld()
        let acme = term("Acme")
        world.vocabulary = [acme, term("Doomed")]
        let harness = try makeHarness(world: world)
        harness.plan.text = { _ in "Acme ships" }

        await beginAndArm(harness)
        // The user deletes a term and adds another while the dictation is in flight.
        world.vocabulary = [acme, term("Brand New")]
        await harness.pipeline.end()

        let texts = world.vocabulary.map(\.text).sorted()
        XCTAssertEqual(texts, ["Acme", "Brand New"],
                       "writing back the begin snapshot would resurrect a deleted term")
        XCTAssertEqual(world.vocabulary.first { $0.text == "Acme" }?.useCount, 1)
    }

    func testUsageMatchesWholeWordsOnly() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("API"), term("Acme")]
        let harness = try makeHarness(world: world)
        harness.plan.text = { _ in "the rapid individual divides" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertTrue(world.writes.isEmpty,
                      "'API' inside 'rapid' is not a use of the term")
    }

    func testUsageIsCaseInsensitive() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme")]
        let harness = try makeHarness(world: world)
        harness.plan.text = { _ in "acme ships today" }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(world.vocabulary.first?.useCount, 1)
        XCTAssertEqual(world.vocabulary.first?.text, "Acme", "the stored spelling is untouched")
    }

    func testUsageIsCountedOnThePostReplacementTextSoAnLLMFailureChangesNothing() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme")]
        world.replacements = [rule("Ackme", "Acme")]
        let harness = try makeHarness(configuration: cleanConfiguration(), world: world)
        harness.plan.text = { _ in "Ackme ships" }
        harness.chat.result = { _ in throw GroqChatError.timedOut }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(world.vocabulary.first?.useCount, 1,
                       "the signal is what was said, not whether Groq answered")
    }

    /// The mode is allowed to drop a word; that does not un-say it. Counting usage
    /// on the model's output would let a paraphrase decide what the user's
    /// vocabulary is worth.
    func testUsageIsCountedOnWhatWasSaidNotOnWhatTheModelReturned() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme")]
        let harness = try makeHarness(configuration: cleanConfiguration(), world: world)
        harness.plan.text = { _ in "Acme ships today" }
        harness.chat.result = { _ in "It ships today." }   // the term is gone

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertEqual(harness.inserter.inserted, ["It ships today."])
        XCTAssertEqual(world.vocabulary.first?.useCount, 1)
    }

    func testASecureFieldRefusalBumpsNothing() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme")]
        let harness = try makeHarness(world: world)
        harness.plan.text = { _ in "Acme ships" }
        harness.inserter.outcome = .refusedSecureField

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertTrue(world.writes.isEmpty,
                      "nothing was put in front of the user, so nothing was used")
    }

    func testAFailedDictationBumpsNothing() async throws {
        let world = ModeWorld()
        world.vocabulary = [term("Acme")]
        let harness = try makeHarness(world: world)
        harness.plan.text = { _ in nil }

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertTrue(world.writes.isEmpty, "nothing reached the cursor, so nothing was used")
    }

    // MARK: - The 1–9 transient hotkeys

    func testEnteringRecordingRegistersEveryDigitInBothForms() async throws {
        let harness = try makeHarness()

        await beginAndArm(harness)

        let plain = harness.digits.registered.filter { $0.combo.carbonModifiers == 0 }
        let modified = harness.digits.registered.filter { $0.combo.carbonModifiers != 0 }
        XCTAssertEqual(plain.map(\.digit), [1, 2, 3, 4, 5, 6],
                       "one per available mode, capped at nine")
        XCTAssertEqual(modified.map(\.digit), [1, 2, 3, 4, 5, 6],
                       "⌥1 too — the push-to-talk modifier is physically held (§4.1)")
        XCTAssertEqual(Set(modified.map(\.combo.carbonModifiers)), [0x0800])
    }

    func testTheDigitHotkeysAreNotRegisteredBeforeRecordingStarts() async throws {
        let harness = try makeHarness()
        harness.audio.suspendStart = true

        await harness.pipeline.begin(trigger: .pushToTalk)
        await waitUntil({ harness.audio.isStartSuspended }, "the start suspends on .arming")

        XCTAssertTrue(harness.digits.registered.isEmpty,
                      "the digits belong to `recording`, not to `arming`")
        harness.audio.resumeStart()
    }

    /// A leaked plain-digit registration swallows the number keys for the whole
    /// machine, so every exit from `recording` is tested separately.
    func testEveryExitFromRecordingUnregistersTheDigitHotkeys() async throws {
        // 1. A normal end.
        let ended = try makeHarness()
        await beginAndArm(ended)
        await ended.pipeline.end()
        XCTAssertTrue(ended.digits.registered.isEmpty, "end")

        // 2. Cancel.
        let cancelled = try makeHarness()
        await beginAndArm(cancelled)
        await cancelled.pipeline.cancel()
        XCTAssertTrue(cancelled.digits.registered.isEmpty, "cancel")

        // 3. Device loss.
        let lost = try makeHarness()
        await beginAndArm(lost)
        lost.audio.simulateActiveDeviceLoss()
        await waitUntil({ !lost.inserter.inserted.isEmpty }, "the partial capture finishes")
        XCTAssertTrue(lost.digits.registered.isEmpty, "device loss")

        // 4. A transcription failure.
        let failed = try makeHarness()
        await beginAndArm(failed)
        failed.plan.text = { _ in nil }
        await failed.pipeline.end()
        XCTAssertTrue(failed.digits.registered.isEmpty, "transcription failure")

        // 5. A secure field, which settles on an error while holding a transcript.
        let refused = try makeHarness()
        await beginAndArm(refused)
        refused.inserter.outcome = .refusedSecureField
        await refused.pipeline.end()
        XCTAssertTrue(refused.digits.registered.isEmpty, "secure-field refusal")
    }

    func testAMicrophoneFailureLeavesNoDigitHotkeysBehind() async throws {
        let harness = try makeHarness()
        harness.audio.startError = AudioEngineError.deviceUnavailable

        await harness.pipeline.begin(trigger: .pushToTalk)
        await waitUntil({ if case .error = harness.pipeline.phase { return true }; return false },
                        "the capture fails")

        XCTAssertTrue(harness.digits.registered.isEmpty)
    }

    func testPressingADigitSwitchesToTheNthMode() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in "hello" }
        await beginAndArm(harness)

        // Mode.builtIns is [clean, verbatim, message, email, note, code].
        harness.digits.press(4)

        guard case .recording(_, let modeName) = harness.pipeline.phase else {
            return XCTFail("expected .recording, got \(harness.pipeline.phase)")
        }
        XCTAssertEqual(modeName, Mode.email.name)

        await harness.pipeline.end()
        XCTAssertEqual(harness.chat.calls.map(\.model), [Mode.email.model])
    }

    func testADigitBeyondTheAvailableModesDoesNothing() async throws {
        let harness = try makeHarness(availableModes: { [Mode.verbatim, Mode.clean] })
        await beginAndArm(harness)

        XCTAssertEqual(harness.digits.registered.filter { $0.combo.carbonModifiers == 0 }.count, 2)
        harness.pipeline.switchMode(toModeAt: 9)

        guard case .recording(_, let modeName) = harness.pipeline.phase else {
            return XCTFail("expected .recording, got \(harness.pipeline.phase)")
        }
        XCTAssertEqual(modeName, Mode.verbatim.name)
    }

    func testARefusedDigitIsReportedRatherThanAssumedToHaveWorked() async throws {
        let harness = try makeHarness()
        harness.digits.refusingDigit = 3

        await beginAndArm(harness)

        XCTAssertEqual(harness.pipeline.notice, .modeDigitUnavailable(digit: 3))
        XCTAssertFalse(harness.digits.registered.contains { $0.digit == 3 })
        XCTAssertTrue(harness.digits.registered.contains { $0.digit == 4 },
                      "one occupied digit costs that digit, not the other eight")
        XCTAssertTrue(harness.pipeline.phase.isRecording, "and never the recording")
    }

    func testARefusedDigitStillTearsDownWhenRecordingEnds() async throws {
        let harness = try makeHarness()
        harness.digits.refusingDigit = 3

        await beginAndArm(harness)
        await harness.pipeline.end()

        XCTAssertTrue(harness.digits.registered.isEmpty)
        XCTAssertGreaterThan(harness.digits.unregisterCallCount, 0)
    }

    func testASecondCaptureRegistersTheDigitsAgain() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        await harness.pipeline.end()
        XCTAssertTrue(harness.digits.registered.isEmpty)

        await beginAndArm(harness, trigger: .toggle)

        XCTAssertFalse(harness.digits.registered.isEmpty,
                       "the next recording gets its own registrations")
    }

    func testAPushToTalkKeyWithNoCarbonModifierRegistersOnlyThePlainDigits() async throws {
        let world = ModeWorld()
        world.bindings.pushToTalk = .modifier(.fnGlobe)
        let harness = try makeHarness(world: world)

        await beginAndArm(harness)

        XCTAssertTrue(harness.digits.registered.allSatisfy { $0.combo.carbonModifiers == 0 },
                      "Fn is not expressible to RegisterEventHotKey, so there is no second form")
        XCTAssertEqual(harness.digits.registered.count, 6)
    }

    // MARK: - Retry

    func testRetryReTranscribesTheSessionAudioAndInserts() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.plan.text = { _ in nil }
        await harness.pipeline.end()
        XCTAssertTrue(harness.inserter.inserted.isEmpty)

        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        let initialTranscriptionRequests = record.usageEntries?.filter {
            $0.stage == .transcription
        }.count ?? 0
        let initialCost = record.estimatedCostUSD
        harness.plan.text = { _ in "recovered text" }
        var resourceEvents: [PipelineResourceEvent] = []
        let resourceSubscription = harness.pipeline.resourceEvents.sink {
            resourceEvents.append($0)
        }

        await harness.pipeline.retry(recordID: record.id)

        XCTAssertEqual(harness.inserter.inserted, ["recovered text"])
        let updated = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertEqual(updated.outcome, .inserted)
        XCTAssertEqual(updated.retryCount, 1)
        XCTAssertEqual(
            updated.usageEntries?.filter { $0.stage == .transcription }.count,
            initialTranscriptionRequests + 1)
        XCTAssertGreaterThan(updated.estimatedCostUSD, initialCost)
        let retryTranscriber = try XCTUnwrap(harness.made.transcribers.last)
        XCTAssertEqual(retryTranscriber.dispatches.map(\.url),
                       [try XCTUnwrap(harness.recorder.sessionURL)],
                       "retry re-sends the durable session file, not a swept temporary")
        XCTAssertEqual(resourceEvents, [.started(record.id), .ended(record.id)],
                       "retry CPU measurement needs the same balanced lifecycle as capture")
        withExtendedLifetime(resourceSubscription) {}
    }

    func testRetryModeReappliesTheStoredModeAndUpdatesHistoryWithoutInsertingAgain() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        harness.plan.text = { _ in "raw words" }
        harness.chat.result = { _ in "first clean result" }
        await beginAndArm(harness)
        await harness.pipeline.end()
        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)

        harness.chat.result = { _ in "updated clean result" }
        await harness.pipeline.retryMode(recordID: record.id)

        let updated = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)
        XCTAssertEqual(updated.finalText, "updated clean result")
        XCTAssertEqual(updated.wordCount, 3)
        XCTAssertEqual(harness.inserter.inserted, ["first clean result"],
                       "Retry mode updates History; Re-insert remains a separate action")
        XCTAssertEqual(harness.chat.callCount, 2)
    }

    func testRetryModePreservesALegacyTranscriptionEstimateWhenAddingUsage() async throws {
        let harness = try makeHarness(configuration: cleanConfiguration())
        let log = try XCTUnwrap(harness.fakeRecordLog)
        var legacy = makeInterruptedRecord(id: UUID(), audioFileName: "legacy.flac")
        legacy.rawText = "raw legacy words"
        legacy.finalText = legacy.rawText
        legacy.modeID = Mode.clean.id
        legacy.estimatedCostUSD = 0.25
        legacy.usageEntries = nil
        legacy.outcome = .inserted
        harness.chat.usage = RefinementUsage(
            promptTokens: 20,
            completionTokens: 4,
            reasoningTokens: nil,
            cachedTokens: nil,
            costUSD: Decimal(string: "0.001"),
            costKind: .billed)
        try await log.append(legacy)

        await harness.pipeline.retryMode(recordID: legacy.id)

        let updated = try XCTUnwrap(log.records.first)
        XCTAssertEqual(updated.totalTrackedCostUSD, 0.251, accuracy: 0.000_000_1)
        XCTAssertTrue(updated.usageEntries?.contains {
            $0.requestedModelID == "Legacy estimate" && $0.costUSD == Decimal(string: "0.25")
        } ?? false)
    }

    func testRetryIsRejectedWhileTheMicrophoneIsLive() async throws {
        let harness = try makeHarness()
        await beginAndArm(harness)
        harness.plan.text = { _ in nil }
        await harness.pipeline.end()
        let record = try XCTUnwrap(try XCTUnwrap(harness.fakeRecordLog).records.first)

        await beginAndArm(harness, trigger: .toggle)
        let transcribersBefore = harness.made.transcribers.count
        await harness.pipeline.retry(recordID: record.id)

        XCTAssertEqual(harness.made.transcribers.count, transcribersBefore,
                       "a retry must not disturb a live recording")
        XCTAssertTrue(harness.pipeline.phase.isRecording)
    }

    func testCustomLocalModeUsesItsChoiceThroughDefaultAppMappingAndHistoryRetry() async throws {
        for choice in [ModeCleanupChoice.localS1Mini, .localGemma, CleanupTestModels.third.id] {
        for mapped in [false, true] {
            var custom = Mode.email
            custom.id = "custom-local"
            custom.name = "My local mode"
            custom.isBuiltIn = false
            custom.cleanupChoice = choice
            let world = ModeWorld()
            let local = StubLocalCleanup(.success("Locally cleaned."))
            world.localCleanup = local
            world.cleanupRegistry = CleanupTestModels.registry
            var config = cleanConfiguration()
            if mapped { world.perAppMap["com.test.app"] = custom.id }
            else { config.defaultModeID = custom.id }
            let selected = custom
            let harness = try makeHarness(configuration: config,
                availableModes: { Mode.builtIns + [selected] }, world: world)
            harness.plan.text = { _ in "um original words" }
            await beginAndArm(harness)
            await harness.pipeline.end()
            let record = try XCTUnwrap(harness.fakeRecordLog?.records.first)
            XCTAssertEqual(record.modeID, custom.id)
            XCTAssertEqual(record.rawText, "um original words")
            XCTAssertEqual(record.finalText, "Locally cleaned.")
            XCTAssertEqual(record.usageEntries?.last?.costKind, .noCharge)
            XCTAssertEqual(record.usageEntries?.last?.providerID, choice.rawValue)
            await harness.pipeline.retryMode(recordID: record.id)
            let calls = await local.calls
            XCTAssertEqual(calls, ["um original words", "um original words"])
            let requests = await local.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(requests.allSatisfy { $0.choice == choice && (choice == .localS1Mini || $0.systemMessage.contains("Return only")) })
            XCTAssertTrue(harness.chat.calls.isEmpty)
            XCTAssertEqual(harness.inserter.inserted, ["Locally cleaned."])
        }
        }
    }

    func testLocalCustomModeDoesNotCollectUnusedContextOrEditASelection() async throws {
        var custom = Mode.email
        custom.id = "local-with-saved-context"
        custom.cleanupChoice = .localS1Mini
        custom.includeClipboardContext = true
        custom.includeAppNameContext = true
        custom.contextOptions = ModeContextOptions(selectedText: true, editSelectedText: true,
            editorText: true, dateTime: true, applicationDetails: true, refreshEditorBeforeRefinement: true)
        let world = ModeWorld()
        world.snapshot.selectedText = "Original selection"
        world.snapshot.editorText = "Private surrounding text"
        world.localCleanup = StubLocalCleanup(.failure(S1MiniError.notDownloaded))
        var config = cleanConfiguration()
        config.defaultModeID = custom.id
        let selected = custom
        let harness = try makeHarness(configuration: config, availableModes: { [selected] }, world: world)
        harness.plan.text = { _ in "keep my dictated words" }
        await beginAndArm(harness)
        await harness.pipeline.end()
        XCTAssertEqual(world.snapshotReads, 0)
        XCTAssertEqual(world.clipboardReads, 0)
        XCTAssertTrue(harness.chat.calls.isEmpty)
        XCTAssertEqual(harness.inserter.inserted, ["keep my dictated words"])
        XCTAssertEqual(harness.pipeline.notice, .modeSkipped(modeName: custom.name))
    }

    func testSwitchingBetweenCloudAndCustomLocalModeUsesTheFinalChoice() async throws {
        for endLocally in [false, true] {
            var localMode = Mode.email
            localMode.id = "local-custom"
            localMode.cleanupChoice = .localS1Mini
            let selected = localMode
            let world = ModeWorld()
            let local = StubLocalCleanup(.success("Local output."))
            world.localCleanup = local
            var config = cleanConfiguration()
            config.defaultModeID = endLocally ? Mode.clean.id : localMode.id
            let harness = try makeHarness(configuration: config,
                availableModes: { [Mode.clean, selected] }, world: world)
            harness.chat.result = { _ in "Cloud output." }
            await beginAndArm(harness)
            harness.pipeline.switchMode(to: endLocally ? localMode.id : Mode.clean.id)
            await harness.pipeline.end()
            XCTAssertEqual(harness.inserter.inserted, [endLocally ? "Local output." : "Cloud output."])
            XCTAssertEqual(harness.chat.calls.count, endLocally ? 0 : 1)
            let calls = await local.calls
            XCTAssertEqual(calls.count, endLocally ? 1 : 0)
        }
    }


    func testWebsiteCanResolveFromALocalDefaultToAnotherLocalModeWithoutClipboardReads() async throws {
        var initial = Mode.clean
        initial.cleanupChoice = .localS1Mini
        var custom = Mode.email
        custom.id = "website-local"
        custom.cleanupChoice = .localS1Mini
        custom.includeClipboardContext = true
        custom.contextOptions = ModeContextOptions(selectedText: true, editSelectedText: true,
            editorText: true, website: true, refreshEditorBeforeRefinement: true)
        let world = ModeWorld()
        world.websiteMap = ["example.com": custom.id]
        world.websiteHost = { _ in "example.com" }
        world.snapshot.selectedText = "private selected text"
        let local = StubLocalCleanup(.success("Local output."))
        world.localCleanup = local
        let initialMode = initial
        let websiteMode = custom
        let harness = try makeHarness(configuration: cleanConfiguration(),
            availableModes: { [initialMode, websiteMode] }, world: world)
        await beginAndArm(harness)
        await harness.pipeline.end()
        XCTAssertEqual(harness.fakeRecordLog?.records.first?.modeID, custom.id)
        XCTAssertEqual(world.snapshotReads, 1, "Routing still probes the website, but does not refresh editor context")
        XCTAssertEqual(world.clipboardReads, 0)
        XCTAssertTrue(harness.chat.calls.isEmpty)
        XCTAssertEqual(harness.inserter.inserted, ["Local output."])
        let calls = await local.calls
        XCTAssertEqual(calls.count, 1)
    }

}
