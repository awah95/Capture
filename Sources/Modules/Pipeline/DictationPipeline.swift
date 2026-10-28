import AVFoundation
import Combine
import Foundation

enum PipelineResourceEvent: Equatable, Sendable {
    case started(UUID)
    case ended(UUID)
}

// MARK: - Pipeline

/// Orchestrates one dictation end to end: microphone → segments → transcription → cursor.
///
/// Replaces `CaptureManager` and carries its hard-won invariants forward — a
/// duplicate trigger is rejected rather than queued, a superseded capture can never
/// finalize a newer one, insertion is owned per capture so a late result lands in the
/// session that spoke it, and the record reaches disk before any audio reaches the
/// network.
///
/// **Every capture owns its own recorder and transcriber.** Spec §4.1 allows a new
/// recording to start while the previous one is still transcribing, and shared
/// instances cannot do that: one `reset()` would cancel the older capture's in-flight
/// uploads, and one `deleteSegmentFiles()` would sweep the newer capture's
/// temporaries. Two factories are cheaper than either bug.
///
/// **Nothing per-buffer happens here.** `onConvertedBuffer` routes straight into the
/// recorder on `AudioQueue`; only segment closures, meter levels and phase changes
/// reach the main actor.
@MainActor
final class DictationPipeline: ObservableObject {

    /// Everything about a dictation that is not a user preference.
    struct Configuration: Equatable, Sendable {
        var speechVocabularyEnabled = true
        var parakeetVocabularyBoosting = false
        var transcriptionModel: String = "whisper-large-v3-turbo"
        var transcriptionProvider: TranscriptionProvider = .groq
        /// Publish revisable partial text while recording when the selected provider
        /// supports it. Final insertion still occurs once, after capture ends.
        var liveTranscriptionEnabled: Bool = false
        /// A live Parakeet capture may run the complete recording through the
        /// full-attention batch model before insertion.
        var retranscribeFinalWithBatch: Bool = false
        var language: String?
        /// Seam repair — the §5.2 kill switch, shared with segmentation.
        var repairSeams: Bool = true
        /// Echo cancellation. **On, and it must stay on**: dictating cleanly while
        /// audio plays through the Mac's speakers is the product's differentiator, and
        /// the nine-channel layout that once made voice processing record silence is
        /// handled inside `AudioFormatConverter`, not here.
        var voiceProcessing: Bool = true
        /// The mode a capture starts in. v1 inserts the stitched transcript, so the
        /// only honest default is the mode that does exactly that; the LLM modes are
        /// wired in Task 16.
        var defaultModeID: String = Mode.verbatim.id

        static let `default` = Configuration()
    }

    /// Marks a record opened for a capture that has not yet produced a transcript. A
    /// relaunch finding one knows the app died mid-dictation, and that the audio
    /// beside it is still worth re-sending.
    static let interruptedReason = "Interrupted before transcription finished."

    /// Tokens held back from the vocabulary so the continuity tail (§5.1) still fits
    /// inside Whisper's 224-token prompt on a non-first segment.
    ///
    /// `GroqTranscriber.assemblePrompt` re-trims to the same cap and would drop whole
    /// terms to make room for the tail — but it trims blind, from the end of a list
    /// it did not rank. Reserving here means the trimming happens where the scoring
    /// lives, so what gets dropped is the lowest-scoring term rather than whichever
    /// one happened to be last.
    ///
    /// Sized from the tail's own definition: thirty words at a generous six
    /// characters each, plus the separator, run through the same estimator.
    static let continuityTailTokenReserve = VocabularyRanker.estimatedTokens(
        in: String(repeating: "wordsx", count: GroqTranscriber.continuityTailWordCount) + ". ")

    static let transcriptionFailedMessage = "Transcription failed — audio saved."
    static let noSpeechMessage = "No speech was heard — audio saved."
    static let recordingFailedMessagePrefix = "Recording failed"

    /// Something worth saying *about* a capture that is not a state of one, mirroring
    /// `CapsuleNotice`'s split. The composition root maps this onto the capsule; the
    /// pipeline owns no window.
    enum Notice: Equatable, Sendable {
        /// Spec §6.4/§17: the LLM pass failed, timed out, or had no client, and the
        /// raw post-replacement transcript was inserted instead.
        case modeSkipped(modeName: String)
        /// Carbon refused one of the 1–9 mode-switch combos, so that digit does
        /// nothing this recording. Said out loud rather than swallowed.
        case modeDigitUnavailable(digit: Int)
    }

    /// The last notice, republished on every occurrence — including an identical
    /// one, because two dictations in a row skipping the same mode is two things
    /// the user is entitled to be told.
    @Published private(set) var notice: Notice?

    /// Every registration and teardown of the 1–9 keys hangs off this one `didSet`.
    ///
    /// Nine **plain digits** are taken system-wide while a capture records, so the
    /// dangerous half is the teardown: a leak means the user's number keys stop
    /// working everywhere. Making it a property observer rather than a call in
    /// `end()` means it fires on every exit — end, cancel, device loss, a
    /// transcription failure, a microphone that never started — including exits
    /// nobody has written yet.
    @Published private(set) var phase: PipelinePhase = .idle {
        didSet {
            guard oldValue.isRecording != phase.isRecording else { return }
            syncModeDigitHotkeys()
        }
    }

    /// The microphone's normalized level, republished exactly as often as the engine
    /// delivers it (main actor, ~30 Hz) and zeroed the moment a capture detaches.
    /// The HUD waveform is the only consumer; nothing here adds a timer.
    @Published private(set) var meterLevel: Double = 0

    /// A streaming provider's revisable transcript while the microphone is live.
    /// Batch-only providers never publish here, and final insertion still happens
    /// once in `complete`, after recording stops.
    @Published private(set) var liveTranscriptPreview: String?

    /// Advances after any durable record mutation: success, failure, cancellation,
    /// transcription retry, or mode retry. UI summaries observe this instead of
    /// guessing which pipeline phases happened to change the log.
    @Published private(set) var recordRevision = 0
    let resourceEvents = PassthroughSubject<PipelineResourceEvent, Never>()

    /// The last capture to reach a terminal phase, so ⌘R has something to retry.
    /// Set on success and on failure — both leave a row worth re-running.
    private(set) var lastConcludedRecordID: UUID?

    /// How the capture on screen was started, so the trigger path can tell a held key
    /// from a latched recording.
    private(set) var activeTrigger: CaptureTrigger?

    /// The active recording's identity lets UI resolve its symbol without guessing
    /// from a display name, which can be shared by multiple custom modes.
    var activeModeID: String? { active?.modeID }

    private let audioEngine: any AudioEngineControlling
    private let makeRecorder: () -> any SegmentRecording
    private let makeTranscriber: () -> any DictationTranscribing
    private let planner: SegmentPlanner
    private let inserter: any TextInserting
    private let recordLog: any DictationRecordLogging
    private let sessionDirectory: URL
    private let apiKey: () -> String
    private let micPolicy: () -> MicSelectionPolicy
    private let availableModes: () -> [Mode]
    private let configuration: () -> Configuration
    private let neverStoreAudio: () -> Bool
    private let modes: ModeServices
    private let now: () -> Date

    private var active: ActiveCapture?
    private var generationCounter = 0

    /// Microphone startup can suspend for the system permission prompt. Retaining the
    /// task lets `end`/`cancel` cancel and *join* that suspension before touching the
    /// engine, so a late permission result can never install an orphan session.
    private var pendingStart: Task<Void, Never>?
    private var pendingStartGeneration = 0

    init(audioEngine: any AudioEngineControlling,
         makeRecorder: @escaping () -> any SegmentRecording,
         makeTranscriber: @escaping () -> any DictationTranscribing,
         planner: SegmentPlanner,
         inserter: any TextInserting,
         recordLog: any DictationRecordLogging,
         sessionDirectory: URL,
         apiKey: @escaping () -> String,
         micPolicy: @escaping () -> MicSelectionPolicy,
         availableModes: @escaping () -> [Mode],
         configuration: Configuration = .default,
         configurationProvider: (() -> Configuration)? = nil,
         neverStoreAudio: @escaping () -> Bool = { false },
         modes: ModeServices? = nil,
         now: @escaping () -> Date = Date.init) {
        self.audioEngine = audioEngine
        self.makeRecorder = makeRecorder
        self.makeTranscriber = makeTranscriber
        self.planner = planner
        self.inserter = inserter
        self.recordLog = recordLog
        self.sessionDirectory = sessionDirectory
        self.apiKey = apiKey
        self.micPolicy = micPolicy
        self.availableModes = availableModes
        self.configuration = configurationProvider ?? { configuration }
        self.neverStoreAudio = neverStoreAudio
        // A default argument would be evaluated outside the actor, and `ModeServices`
        // is main-actor isolated.
        self.modes = modes ?? ModeServices()
        self.now = now

        // Spec §4.2: losing the active input finalizes the capture with the audio
        // recorded so far. Never wedged, never discarded.
        self.audioEngine.onActiveDeviceChange = { [weak self] device in
            guard device == nil else { return }
            // The engine publishes this on the main queue (see `AudioEngineControlling`).
            MainActor.assumeIsolated { self?.handleActiveDeviceLoss() }
        }
    }

    // MARK: - Begin

    func begin(trigger: CaptureTrigger, explicitModeID: String? = nil) async {
        // Duplicate-trigger rejection: a second press while the microphone is ours is
        // a no-op, not a queued capture. A trigger during *transcription* is allowed —
        // the two dictations pipeline independently.
        guard !phase.holdsMicrophone else { return }

        generationCounter += 1
        let configuration = configuration()
        // Spec §6.3: the mode is resolved **here**, once, from the app that is
        // frontmost as the key goes down. The user who starts dictating into Slack
        // and switches to Chrome mid-sentence must get Slack's mode — resolving at
        // insert time would hand Chrome's mode words it never heard.
        let targetBundleID = inserter.frontmostAppBundleID()
        let targetAppName = inserter.frontmostAppName()
        let startedAt = now()
        let mode = ModeResolver.resolve(
            explicitModeID: explicitModeID,
            frontmostBundleID: targetBundleID,
            perAppMap: modes.perAppModeMap(),
            defaultModeID: configuration.defaultModeID,
            available: availableModes())

        // Read once, so the terms the ranker scored and the terms the model is told
        // to spell are provably the same list.
        let vocabulary = modes.vocabulary()

        let captureID = UUID()
        let capture = ActiveCapture(
            id: captureID,
            generation: generationCounter,
            trigger: trigger,
            startedAt: startedAt,
            modeID: mode.id,
            targetBundleID: targetBundleID,
            targetAppName: targetAppName,
            vocabularyTerms: vocabulary,
            // Reserving the tail's tokens here rather than letting `assemblePrompt`
            // trim later keeps the cut where the scoring is: the term that gets
            // dropped is the lowest-scoring one, not whichever was last in the list.
            vocabularySelection: VocabularyRanker.select(
                from: vocabulary,
                targetBundleID: targetBundleID,
                now: now(),
                reservedTokens: Self.continuityTailTokenReserve),
            recorder: makeRecorder(),
            transcriber: makeTranscriber(),
            configuration: configuration,
            sessionAudioURL: sessionDirectory.appendingPathComponent("\(captureID.uuidString).flac"))
        active = capture
        activeTrigger = trigger
        startContext(for: capture, initialMode: mode, explicitModeID: explicitModeID)
        resourceEvents.send(.started(capture.id))
        liveTranscriptPreview = nil
        let usesLiveTranscription = configuration.liveTranscriptionEnabled
            && configuration.transcriptionProvider.supportsLiveTranscription
        if usesLiveTranscription {
            let captureID = capture.id
            capture.transcriber.setLiveTranscriptHandler { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.active?.id == captureID,
                          self.active?.isRecording == true,
                          self.phase.isRecording
                    else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    self.liveTranscriptPreview = trimmed
                }
            }
        }
        phase = .arming

        // Spec §5.3: pay for DNS, TCP and TLS while the user is drawing breath.
        capture.transcriber.configureVocabulary(capture.nativeVocabularyTerms)
        capture.transcriber.warmConnection(apiKey: apiKey())
        if usesLiveTranscription {
            capture.transcriber.beginLiveTranscription(
                vocabularyTerms: capture.nativeVocabularyTerms)
        }

        do {
            try capture.recorder?.begin(captureID: capture.id)
        } catch {
            settle(capture, phase: .error(
                message: "\(Self.recordingFailedMessagePrefix): \(error.localizedDescription)",
                retryable: false))
            return
        }

        // PERSIST BEFORE audio and before anything reaches the network. A crash from
        // here on leaves a row pointing at real audio instead of an orphaned file.
        let sessionURL = capture.sessionURL(in: sessionDirectory)
        try? await recordLog.append(DictationRecordDraft.opened(
            id: capture.id,
            startedAt: capture.startedAt,
            modeID: capture.modeID,
            targetBundleID: capture.targetBundleID,
            targetAppName: capture.targetAppName,
            audioFileName: sessionURL.lastPathComponent,
            voiceProcessingActive: configuration.voiceProcessing,
            interruptedReason: Self.interruptedReason))
        guard active === capture else { return }   // cancelled while we were on disk

        attachEngine(to: capture)
        startMicrophone(for: capture)
    }

    /// Context work starts beside recording, never before microphone ownership. Website
    /// resolution may update the mode while arming, but cannot consume a release edge.
    private func startContext(for capture: ActiveCapture, initialMode: Mode, explicitModeID: String?) {
        if initialMode.usesLocalCleanup { modes.prewarmLocalCleanup(initialMode.cleanupChoice) }
        guard modes.contextEnabled() else { return }
        let request = ContextCaptureRequest(initialMode: initialMode, explicitModeID: explicitModeID,
            targetBundleID: capture.targetBundleID, appMap: modes.perAppModeMap(),
            websiteMap: explicitModeID == nil ? modes.perWebsiteMap() : [:],
            defaultModeID: capture.configuration.defaultModeID, availableModes: availableModes(), cleanupRegistry: modes.cleanupRegistry)
        guard initialMode.usesModePrompt(in: modes.cleanupRegistry) || !request.websiteMap.isEmpty else { return }
        // Freeze clipboard text at the same edge even when website routing is pending.
        // Read only if a possible resolved mode explicitly allows clipboard context;
        // discard it immediately when the actual mode does not allow it.
        let eligible = request.websiteMap.isEmpty ? [initialMode] :
            request.availableModes.filter { $0.id == initialMode.id || request.websiteMap.values.contains($0.id) }
        let allowsClipboard = eligible.contains { $0.usesModePrompt(in: modes.cleanupRegistry) && $0.includeClipboardContext }
        let clipboardReader = allowsClipboard ? modes.clipboardStartReader?() : nil
        let freezeBeforeRouting = request.websiteMap.isEmpty || modes.clipboardBeforeWebsiteResolution()
        let startingClipboard = allowsClipboard && freezeBeforeRouting ? (clipboardReader?() ??
            (clipboardReader == nil ? (modes.clipboardAtStart ?? modes.clipboard)() : nil)) : nil
        let probe = modes.contextSnapshot(capture.targetBundleID, request)
        capture.contextTask = Task { [weak self] in
            let snapshot = await ContextCollector.value(of: probe)
            guard let self, !Task.isCancelled, !capture.isRevoked,
                  !capture.modeWasManuallySelected, modes.contextEnabled() else { return .empty }
            let resolved = request.availableModes.first { $0.id == snapshot.resolvedModeID } ?? initialMode
            capture.modeID = resolved.id
            if active === capture, case .recording(let elapsed, _) = phase {
                phase = .recording(elapsed: elapsed, modeName: resolved.name)
            }
            if resolved.usesModePrompt(in: modes.cleanupRegistry), !snapshot.protectedField {
                if resolved.includeClipboardContext {
                    capture.contextAtStart.clipboard = freezeBeforeRouting ? startingClipboard : clipboardReader?()
                    capture.capturesClipboard = true
                }
                if resolved.contextOptions.dateTime {
                    capture.contextAtStart.dateTime = ISO8601DateFormatter().string(from: capture.startedAt)
                }
            } else { capture.contextAtStart = .empty }
            return snapshot
        }
    }

    /// Routes converted buffers into the recorder **on the audio queue**, and segment
    /// closures back onto the main actor.
    private func attachEngine(to capture: ActiveCapture) {
        capture.recorder?.onSegmentClosed = { [weak self] segment in
            // `SegmentRecorder` delivers this on the main queue by contract, which is
            // what makes the synchronous hop below safe — and synchronous matters:
            // an async hop could land after `end()` had already swept the segments.
            MainActor.assumeIsolated { self?.handleSegmentClosed(segment, for: capture) }
        }

        let recorder = capture.recorder
        let transcriber = capture.transcriber
        audioEngine.onConvertedBuffer = { buffer in
            // Audio queue. The recorder writes immediately; a streaming local model
            // copies the small canonical buffer and moves inference off this queue.
            recorder?.ingest(buffer)
            transcriber.ingestLiveAudio(buffer)
        }
        audioEngine.onLevel = { [weak self] level, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.meterLevel = level
                self.advanceElapsed(for: capture)
            }
        }
    }

    private func startMicrophone(for capture: ActiveCapture) {
        pendingStartGeneration = capture.generation
        pendingStart = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.completePendingStart(generation: capture.generation) }
            do {
                let info = try await self.audioEngine.startRecording(
                    policy: self.micPolicy(),
                    voiceProcessing: capture.configuration.voiceProcessing)
                guard !Task.isCancelled, self.active === capture, capture.isRecording else { return }
                capture.armedAt = self.now()
                capture.voiceProcessingActive = info.voiceProcessingActive
                self.phase = .recording(elapsed: 0, modeName: self.modeName(capture.modeID))
            } catch is CancellationError {
                // An end/cancel during startup owns the cleanup.
            } catch {
                guard !Task.isCancelled else { return }
                await self.handleStartFailure(capture, error)
            }
        }
    }

    private func handleStartFailure(_ capture: ActiveCapture, _ error: Error) async {
        guard active === capture else { return }
        capture.isRecording = false
        detachEngine(from: capture)
        // Audio is never deleted on failure: whatever landed before the failure stays
        // on disk and stays attached to its record.
        let session = capture.recorder?.finish()
        let message = "\(Self.recordingFailedMessagePrefix): \(error.localizedDescription)"
        await amend(capture, session: session, isRetry: false) { record in
            record.outcome = .failed(reason: message)
        }
        // Not retryable: a microphone that would not start is not fixed by re-sending
        // audio that was never captured.
        settle(capture, phase: .error(message: message, retryable: false))
    }

    // MARK: - Segments

    private func handleSegmentClosed(_ segment: AudioSegment, for capture: ActiveCapture) {
        guard capture.isRecording else { return }   // `end` sweeps everything itself
        dispatch(segment, for: capture)
    }

    /// Sends one segment, unless it holds too little speech to be worth sending.
    ///
    /// The gate is the anti-hallucination guard from spec §5.1: fed near-silence,
    /// Whisper invents a sentence, and that sentence would be typed at the cursor.
    private func dispatch(_ segment: AudioSegment, for capture: ActiveCapture) {
        guard !capture.dispatchedIndices.contains(segment.index) else { return }
        guard planner.shouldDispatch(speechDuration: segment.speechDuration) else { return }
        capture.dispatchedIndices.insert(segment.index)
        capture.dispatchedDurations.append(segment.duration)
        capture.transcriber.enqueue(
            index: segment.index,
            url: segment.url,
            precedingSilence: segment.precedingSilence,
            apiKey: apiKey(),
            model: capture.configuration.transcriptionModel,
            language: capture.configuration.language,
            // The same ranked list on every segment of one capture (§7.1). The
            // transcriber appends the continuity tail to it and re-checks the 224
            // cap, which the reserve above is sized to leave room for.
            vocabularyPrompt: capture.configuration.speechVocabularyEnabled ? capture.vocabularySelection.promptString : "")
    }

    // MARK: - End

    func end() async {
        guard let capture = active, capture.isRecording else { return }
        if modes.contextEnabled(), !capture.modeWasManuallySelected {
            if let makeReader = modes.clipboardEndReader {
                capture.clipboardEndReader = makeReader(capture.startedAt)
            } else if capture.capturesClipboard,
                      case .replace(let clipboard) = modes.clipboardAtEnd(capture.startedAt) {
                capture.contextAtStart.clipboard = clipboard
            }
        }
        capture.isRecording = false
        phase = .transcribing
        await finishRecording(capture)
    }

    /// Stop the microphone, close the files, send whatever has not gone yet, and wait.
    private func finishRecording(_ capture: ActiveCapture) async {
        // The stop edge. Everything between here and `whisperStartedAt` is the user
        // waiting with nothing to show for it — engine teardown plus closing BOTH audio
        // writers, the per-segment file and the continuous session file that History and
        // retry read. It was previously unmeasured and folded into an unattributed
        // residual; now it is a number that can be argued with.
        let finalizeStartedAt = now()

        // Detached synchronously, before any suspension point, so a capture that
        // starts while we are awaiting the engine cannot have its callbacks stolen.
        detachEngine(from: capture)
        await cancelPendingStart(generation: capture.generation)
        if active === capture { await audioEngine.stopRecording() }

        let session = capture.recorder?.finish()
        if let session {
            capture.transcriber.setFinalRecordingURL(session.url)
        }
        for segment in session?.segments ?? [] {
            dispatch(segment, for: capture)
        }

        let whisperStartedAt = now()
        capture.finalizeSeconds = whisperStartedAt.timeIntervalSince(finalizeStartedAt)
        let results = await capture.transcriber.awaitAll()
        capture.selectedTranscriptionPath = capture.transcriber.selectedTranscriptionPath()
        await complete(capture, session: session, results: results,
                       whisperStartedAt: whisperStartedAt, isRetry: false)
    }

    /// Stitch, insert, and write down what happened.
    private func complete(_ capture: ActiveCapture,
                          session: SessionRecording?,
                          results: [SegmentResult],
                          whisperStartedAt: Date,
                          isRetry: Bool) async {
        // A cancelled capture has already been written down as cancelled. Everything
        // below would either contradict that or type into someone's editor.
        guard !capture.isRevoked else { return }

        let transcript = TranscriptStitcher.stitch(
            results, repairSeams: capture.configuration.repairSeams)
        let failures = results.filter { $0.text == nil }.count
        let everySegmentFailed = !results.isEmpty && failures == results.count
        let heardSomething = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard !everySegmentFailed, heardSomething else {
            // Two different failures that must not be described the same way: Groq
            // refused, or nobody said anything worth sending.
            let message = everySegmentFailed
                ? Self.transcriptionFailedMessage
                : Self.noSpeechMessage
            await amend(
                capture,
                session: session,
                isRetry: isRetry,
                transcriptionResults: results
            ) { record in
                record.outcome = .failed(reason: message)
                DictationRecordDraft.finalizeTranscriptionUsage(
                    in: &record,
                    rawText: "",
                    whisperSeconds: self.now().timeIntervalSince(whisperStartedAt),
                    outcome: .failed,
                    isRetry: isRetry,
                    selectedPath: capture.selectedTranscriptionPath,
                    provider: capture.configuration.transcriptionProvider,
                    recordedDuration: session?.duration ?? capture.recordedDuration,
                    dispatchedDurations: capture.dispatchedDurations,
                    results: results)
            }
            // Nothing is deleted: the session file and every segment temporary stay on
            // disk so History can offer the retry this failure earned.
            settle(capture, phase: .error(message: message, retryable: true))
            return
        }

        // The order the rest of this function implements, and the reason for it:
        // stitch → replacements → mode → insert. §7.2 puts the replacements *before*
        // the LLM because a rule that fixes a proper noun has to be in the text the
        // model reads, or the model will helpfully correct it back.
        let modeStartedAt = now()
        let corrected = ReplacementEngine.apply(modes.replacements(), to: transcript)
        let refinement = await refine(corrected, for: capture)
        let refined = refinement.text

        // Cancel can land during the mode pass, which is the one step long enough to
        // give it a window. Everything below either types into someone's editor or
        // contradicts the `.cancelled` row `cancel()` already wrote.
        guard !capture.isRevoked else { return }

        let insertStartedAt = now()
        let outcome: InsertionOutcome
        if refined.isEmpty {
            // A valid filler-only normalization must never paste an empty string:
            // that could delete a selection or overwrite the clipboard.
            outcome = .insertedDirect
        } else if let selection = refinement.originalSelection {
            outcome = await inserter.insertSelectionEdit(refined, originalSelection: selection,
                targetBundleID: capture.targetBundleID)
        } else { outcome = await inserter.insert(refined) }
        let finishedAt = now()

        // Only a clean run sweeps the temporaries. A dictation with a hole in it keeps
        // every file it has until the user has decided what to do about the hole.
        if failures == 0 { capture.recorder?.deleteSegmentFiles() }

        let shouldDiscardSession = failures == 0
            && outcome != .refusedSecureField
            && neverStoreAudio()
        var discardedSession = false
        if shouldDiscardSession, let audioURL = capture.sessionAudioURL {
            do {
                if FileManager.default.fileExists(atPath: audioURL.path) {
                    try FileManager.default.removeItem(at: audioURL)
                }
                discardedSession = true
            } catch {
                // Retain the record's reference when deletion fails. Privacy UI can
                // then still account for and delete the file instead of claiming it
                // is gone while silently orphaning it on disk.
            }
        }

        await amend(
            capture,
            session: session,
            isRetry: isRetry,
            transcriptionResults: results
        ) { record in
            DictationRecordDraft.applyTranscript(
                to: &record,
                // What Whisper heard, before the user's rules and before the mode.
                // Keeping it is what makes `editDistanceRawToFinal` mean anything.
                rawText: transcript,
                finalText: refined,
                insertionOutcome: outcome,
                whisperSeconds: modeStartedAt.timeIntervalSince(whisperStartedAt),
                llmSeconds: insertStartedAt.timeIntervalSince(modeStartedAt),
                insertSeconds: finishedAt.timeIntervalSince(insertStartedAt),
                totalSeconds: finishedAt.timeIntervalSince(capture.startedAt))
            DictationRecordDraft.finalizeTranscriptionUsage(
                in: &record,
                rawText: transcript,
                whisperSeconds: modeStartedAt.timeIntervalSince(whisperStartedAt),
                // Insertion can be refused by a secure field after transcription
                // completed successfully. Keep provider reliability distinct from
                // final delivery reliability.
                outcome: .succeeded,
                isRetry: isRetry,
                selectedPath: isRetry ? .retryBatch : capture.selectedTranscriptionPath,
                provider: capture.configuration.transcriptionProvider,
                recordedDuration: session?.duration ?? capture.recordedDuration,
                dispatchedDurations: capture.dispatchedDurations,
                results: results)
            if refined.isEmpty { record.insertionOutcome = "emptyCleanup" }
            if let usage = refinement.usage {
                record.appendUsageEntriesPreservingLegacyCost([usage])
            }
            if discardedSession {
                record.audioFileName = nil
                record.audioBytes = 0
            }
        }

        // After the record is on disk and only for a dictation that landed: a
        // refusal put nothing in front of the user, and counting it as a use of a
        // term would train the ranker on words that were never delivered.
        if outcome != .refusedSecureField {
            recordVocabularyUse(in: corrected, for: capture)
        }

        // Amended first, deliberately: `amend` is what puts the transcript in the record
        // log, and spec §17's promise for a secure field is that the text is still in
        // History. Returning before that would honour "nothing inserted" by also losing
        // the words.
        if outcome == .refusedSecureField {
            settle(capture, phase: .error(
                message: DictationRecordDraft.secureFieldRefusalReason,
                // Retryable so History can re-insert once the caret is somewhere safe.
                // Nothing is re-transcribed: the transcript already exists.
                retryable: true))
            return
        }

        let words = TextMetrics.wordCount(transcript)
        let duration = session?.duration ?? capture.recordedDuration
        settle(capture, phase: .success(
            words: words,
            wpm: DictationRecordDraft.wordsPerMinute(words: words, speakingDuration: duration)))
    }

    private func amend(_ capture: ActiveCapture,
                       session: SessionRecording?,
                       isRetry: Bool,
                       transcriptionResults: [SegmentResult]? = nil,
                       _ mutate: @escaping (inout DictationRecord) -> Void) async {
        let dispatched = capture.dispatchedDurations
        let modeID = capture.modeID
        let voiceProcessingActive = capture.voiceProcessingActive
        let vocabularyTermsSent = !capture.configuration.speechVocabularyEnabled ? 0 :
            (capture.configuration.transcriptionProvider.isLocal ? capture.nativeVocabularyTerms.count : capture.vocabularySelection.terms.count)
        do {
            try await recordLog.update(id: capture.id) { record in
                if isRetry {
                    record.retryCount += 1
                    let retryUsage = DictationRecordDraft.transcriptionUsageEntries(
                        forDispatched: [capture.recordedDuration],
                        model: capture.configuration.transcriptionModel,
                        provider: capture.configuration.transcriptionProvider,
                        recordedDuration: capture.recordedDuration,
                        isRetry: true,
                        results: transcriptionResults)
                    record.appendUsageEntriesPreservingLegacyCost(retryUsage)
                    record.estimatedCostUSD += retryUsage.compactMap(\.costUSD)
                        .map { NSDecimalNumber(decimal: $0).doubleValue }
                        .reduce(0, +)
                } else {
                    DictationRecordDraft.applyRecording(
                        to: &record,
                        duration: session?.duration ?? 0,
                        segmentCount: session?.segments.count ?? 0,
                        dispatchedDurations: dispatched,
                        audioURL: session?.url,
                        voiceProcessingActive: voiceProcessingActive,
                        transcriptionProvider: capture.configuration.transcriptionProvider,
                        transcriptionModel: capture.configuration.transcriptionModel,
                        liveTranscriptionEnabled: capture.configuration.liveTranscriptionEnabled,
                        retranscribeFinalWithBatch:
                            capture.configuration.retranscribeFinalWithBatch,
                        transcriptionResults: transcriptionResults,
                        vocabularyTermsSent: vocabularyTermsSent,
                        armingSeconds: capture.armedAt.map {
                            $0.timeIntervalSince(capture.startedAt)
                        } ?? 0,
                        finalizeSeconds: capture.finalizeSeconds)
                    // The mode may have been switched mid-recording; the row records what
                    // was actually applied, not what was selected when the key went down.
                    record.modeID = modeID
                }
                record.contextSummary = capture.contextSummary
                mutate(&record)
            }
            recordRevision &+= 1
        } catch {
            // The log already owns recovery/corruption reporting. A failed amendment
            // must not publish a revision that would make the UI claim it refreshed.
        }
    }

    // MARK: - Cancel

    /// Ends and discards — but **only the text**. Spec §4.1: the audio is still
    /// written to disk and shows up in History marked cancelled, so nothing spoken is
    /// ever lost, even when the user changes their mind.
    func cancel() async {
        guard let capture = active else { return }
        capture.contextTask?.cancel()
        capture.contextTask = nil
        capture.contextAtStart = .empty
        capture.clipboardEndReader = nil
        capture.isRevoked = true
        capture.transcriber.reset()

        var session: SessionRecording?
        if capture.isRecording {
            capture.isRecording = false
            detachEngine(from: capture)
            await cancelPendingStart(generation: capture.generation)
            if active === capture { await audioEngine.cancelRecording() }
            session = capture.recorder?.finish()
        }

        await amend(capture, session: session, isRetry: false) { record in
            record.outcome = .cancelled
            DictationRecordDraft.finalizeTranscriptionUsage(
                in: &record,
                rawText: "",
                whisperSeconds: 0,
                outcome: .cancelled,
                isRetry: false,
                selectedPath: capture.selectedTranscriptionPath,
                provider: capture.configuration.transcriptionProvider,
                recordedDuration: session?.duration ?? capture.recordedDuration)
        }
        settle(capture, phase: .idle)
    }

    // MARK: - Modes

    /// Switches the mode of the recording in progress. Deliberately does not change
    /// the user's default: 1–9 is "this dictation", not "from now on".
    func switchMode(to modeID: String) {
        guard let mode = availableModes().first(where: { $0.id == modeID }),
              let capture = active
        else { return }
        capture.modeWasManuallySelected = true
        capture.contextTask?.cancel()
        capture.contextTask = nil
        capture.contextAtStart = .empty
        capture.clipboardEndReader = nil
        capture.capturesClipboard = false
        capture.modeID = mode.id
        if case .recording(let elapsed, _) = phase {
            phase = .recording(elapsed: elapsed, modeName: mode.name)
        }
    }

    /// Switches to the `index`-th available mode, 1-based, as the 1–9 keys name it.
    func switchMode(toModeAt index: Int) {
        let available = availableModes()
        guard index >= 1, index <= available.count else { return }
        switchMode(to: available[index - 1].id)
    }

    /// The mode this capture is going to be transformed by.
    ///
    /// Re-derived from the id the capture is *holding* rather than from the world as
    /// it is now: `capture.targetBundleID` is the app that was frontmost at `begin`,
    /// so even the fallback rungs describe the dictation that happened. Total by
    /// construction, because failing to name a mode would mean failing to insert
    /// words the user has already spoken.
    private func mode(for capture: ActiveCapture) -> Mode {
        ModeResolver.resolve(
            explicitModeID: capture.modeID,
            frontmostBundleID: capture.targetBundleID,
            perAppMap: modes.perAppModeMap(),
            defaultModeID: capture.configuration.defaultModeID,
            available: availableModes())
    }

    /// The mode's LLM pass (spec §6.4), or the text unchanged.
    ///
    /// Returns the text to insert either way. **Every** failure — a timeout, an HTTP
    /// status, no connection, an undecodable stream, a cancellation, an absent client
    /// — inserts what it was given and reports the mode as skipped, because §17's
    /// governing rule is that a mode failure never costs the user their words.
    private struct RefinementAttempt {
        var text: String
        var usage: DictationUsageEntry?
        var originalSelection: String? = nil
    }

    private func refine(_ text: String, for capture: ActiveCapture) async -> RefinementAttempt {
        let hasOriginalContext = capture.contextTask != nil
        var snapshot = await capture.contextTask?.value ?? .empty
        guard !capture.isRevoked else { return RefinementAttempt(text: text, usage: nil) }
        let mode = mode(for: capture)
        if hasOriginalContext, !capture.modeWasManuallySelected, mode.usesModePrompt(in: modes.cleanupRegistry),
           mode.contextOptions.refreshEditorBeforeRefinement, modes.contextEnabled() {
            let request = ContextCaptureRequest(initialMode: mode, explicitModeID: mode.id,
                targetBundleID: capture.targetBundleID, appMap: [:], websiteMap: [:],
                defaultModeID: mode.id, availableModes: [mode], cleanupRegistry: modes.cleanupRegistry)
            let refresh = await ContextCollector.value(of: modes.contextSnapshot(capture.targetBundleID, request))
            guard !capture.isRevoked else { return RefinementAttempt(text: text, usage: nil) }
            if !refresh.targetUnavailable {
                snapshot.editorText = refresh.editorText
                snapshot.windowTitle = refresh.windowTitle
                snapshot.inputLabel = refresh.inputLabel
                snapshot.website = refresh.website
                snapshot.protectedField = snapshot.protectedField || refresh.protectedField
            }
            snapshot.captureMilliseconds += refresh.captureMilliseconds
            snapshot.status += "; editor refresh: " + refresh.status
        }
        if !snapshot.protectedField, capture.capturesClipboard, mode.includeClipboardContext,
           modes.contextEnabled(), case .replace(let clipboard) = capture.clipboardEndReader?() {
            capture.contextAtStart.clipboard = clipboard
        }
        capture.clipboardEndReader = nil
        snapshot.clipboard = capture.contextAtStart.clipboard
        snapshot.dateTime = capture.contextAtStart.dateTime
        snapshot.website = snapshot.website ?? capture.contextAtStart.website
        snapshot = snapshot.filtered(for: mode, enabled: modes.contextEnabled())
        capture.contextSummary = modes.saveContextMetadata() && modes.contextEnabled() ? snapshot.summary : nil
        capture.contextTask = nil
        capture.contextAtStart = .empty
        return await refine(
            text,
            mode: mode,
            vocabularyTerms: capture.vocabularyTerms,
            targetAppName: capture.targetAppName,
            context: snapshot,
            publishesPhase: active === capture)
    }

    private func refine(_ text: String,
                        mode: Mode,
                        vocabularyTerms: [VocabularyTerm],
                        targetAppName: String?,
                        context: ContextSnapshot = .empty,
                        publishesPhase: Bool) async -> RefinementAttempt {

        let originalSelection = modes.contextEnabled() ? PromptAssembler.editingSource(mode: mode, snapshot: context, registry: modes.cleanupRegistry) : nil
        let fallback = originalSelection ?? text

        // A pass-through mode makes no request at all. The client does not check
        // `usesLLM` — this is the only place that does, and "no latency, nothing
        // between your voice and your cursor" is the whole promise of Verbatim.
        guard mode.usesLLM else { return RefinementAttempt(text: fallback, usage: nil, originalSelection: originalSelection) }

        if mode.usesLocalCleanup {
            // Normalization can erase the missing-segment marker, hiding History retry.
            if text.contains(TranscriptStitcher.failureMarker) {
                notice = .modeSkipped(modeName: mode.name)
                return RefinementAttempt(text: fallback, usage: nil, originalSelection: originalSelection)
            }
            if publishesPhase { phase = .refining(modeName: mode.cleanupChoice.title(in: modes.cleanupRegistry)) }
            let started = now()
            do {
                guard let local = modes.localCleanup else { throw LocalCleanupError.unavailable(mode.cleanupChoice) }
                let systemMessage = mode.usesModePrompt(in: modes.cleanupRegistry) ? PromptAssembler.systemMessage(
                    mode: mode, vocabularyTerms: vocabularyTerms,
                    appName: mode.includeAppNameContext && modes.contextEnabled() && !context.protectedField ? targetAppName : nil,
                    clipboard: modes.contextEnabled() ? context.clipboard : nil,
                    snapshot: context.filtered(for: mode, enabled: modes.contextEnabled(), registry: modes.cleanupRegistry), registry: modes.cleanupRegistry) : ""
                let output = try await local.clean(text, request: .init(
                    choice: mode.cleanupChoice, systemMessage: systemMessage, temperature: mode.temperature))
                return RefinementAttempt(text: output, usage: mode.cleanupChoice.usage(
                    elapsed: now().timeIntervalSince(started), outcome: .succeeded, registry: modes.cleanupRegistry), originalSelection: originalSelection)
            } catch {
                notice = .modeSkipped(modeName: mode.name)
                return RefinementAttempt(text: fallback, usage: mode.cleanupChoice.usage(
                    elapsed: now().timeIntervalSince(started), outcome: .failed, registry: modes.cleanupRegistry), originalSelection: originalSelection)
            }
        }

        guard modes.refinement != nil || modes.chat != nil else {
            // No client was injected. Saying so is better than behaving like
            // Verbatim while the capsule shows a mode that did nothing.
            notice = .modeSkipped(modeName: mode.name)
            return RefinementAttempt(text: fallback, usage: nil, originalSelection: originalSelection)
        }

        if publishesPhase { phase = .refining(modeName: mode.name) }

        let systemMessage = PromptAssembler.systemMessage(
            mode: mode,
            // Spec §7.3 exempts this list from Whisper's 224-token cap — "the
            // LLM-side spelling list has no such cap and receives more terms" — so
            // the whole snapshot goes, not the budgeted subset.
            vocabularyTerms: vocabularyTerms,
            appName: mode.includeAppNameContext && modes.contextEnabled() && !context.protectedField ? targetAppName : nil,
            // Context was collected at the recording edge. Never reread live
            // clipboard/editor contents when refinement or a History retry runs.
            clipboard: modes.contextEnabled() ? context.clipboard : nil,
            snapshot: context.filtered(for: mode, enabled: modes.contextEnabled(), registry: modes.cleanupRegistry), registry: modes.cleanupRegistry)

        do {
            let result: RefinementResult
            if let refinement = modes.refinement {
                result = try await refinement.complete(
                    systemMessage: systemMessage,
                    userMessage: text,
                    provider: mode.refinementProvider,
                    model: mode.model,
                    reasoning: mode.reasoningEffort,
                    temperature: mode.temperature,
                    apiKey: modes.refinementAPIKey(mode.refinementProvider) ?? "",
                    timeout: mode.refinementProvider.defaultTimeout,
                    onDelta: { _ in })
            } else if let chat = modes.chat {
                let output = try await chat.complete(
                    systemMessage: systemMessage,
                    userMessage: text,
                    model: mode.model,
                    temperature: mode.temperature,
                    apiKey: apiKey(),
                    timeout: GroqChatClient.defaultTimeout,
                    onDelta: { _ in })
                result = RefinementResult(
                    text: output,
                    provider: .groq,
                    requestedModelID: mode.model,
                    actualModelID: mode.model,
                    generationID: nil,
                    usage: nil)
            } else {
                notice = .modeSkipped(modeName: mode.name)
                return RefinementAttempt(text: fallback, usage: nil, originalSelection: originalSelection)
            }

            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // A content-free answer is a failed pass, not an instruction to
                // insert nothing. The request can still have a billable receipt.
                notice = .modeSkipped(modeName: mode.name)
                return RefinementAttempt(text: fallback, usage: Self.usageEntry(from: result), originalSelection: originalSelection)
            }
            return RefinementAttempt(text: trimmed, usage: Self.usageEntry(from: result), originalSelection: originalSelection)
        } catch {
            notice = .modeSkipped(modeName: mode.name)
            // A missing key is rejected before a request begins. For every other
            // provider-neutral failure the safest financial statement is not $0,
            // but "unknown": a timeout can happen after the provider generated
            // and charged for an answer whose final usage receipt never arrived.
            let failedBeforeRequest: Bool
            if case RefinementError.missingAPIKey = error {
                failedBeforeRequest = true
            } else {
                failedBeforeRequest = false
            }
            let usage = modes.refinement != nil && !failedBeforeRequest
                ? Self.unknownUsageEntry(for: mode)
                : nil
            return RefinementAttempt(text: fallback, usage: usage, originalSelection: originalSelection)
        }
    }

    private static func unknownUsageEntry(for mode: Mode) -> DictationUsageEntry {
        DictationUsageEntry(
            stage: .refinement,
            providerID: mode.refinementProvider.rawValue,
            requestedModelID: mode.model,
            actualModelID: nil,
            promptTokens: nil,
            completionTokens: nil,
            reasoningTokens: nil,
            cachedTokens: nil,
            costUSD: nil,
            costKind: .unknown,
            generationID: nil)
    }

    private static func usageEntry(from result: RefinementResult) -> DictationUsageEntry {
        DictationUsageEntry(
            stage: .refinement,
            providerID: result.provider.rawValue,
            requestedModelID: result.requestedModelID,
            actualModelID: result.actualModelID,
            promptTokens: result.usage?.promptTokens,
            completionTokens: result.usage?.completionTokens,
            reasoningTokens: result.usage?.reasoningTokens,
            cachedTokens: result.usage?.cachedTokens,
            costUSD: result.usage?.costUSD,
            costKind: result.usage?.costKind ?? .unknown,
            generationID: result.generationID)
    }

    // MARK: - Vocabulary usage

    /// Bumps the ranking signals of the terms that were actually spoken.
    ///
    /// Without this the ranker degenerates: every term scores zero for frequency and
    /// recency, so the selection collapses to "pinned first, then alphabetical", and
    /// the app-affinity bonus can never fire because no term ever gains a bundle ID.
    ///
    /// Two things it deliberately does not do. It does not write per term — one
    /// dictation naming eight terms is **one** whole-list write, not eight rewrites
    /// of the file. And it does not write back the snapshot taken at `begin`: the
    /// list is re-read here, so a term the user deleted mid-dictation stays deleted
    /// and one they added survives.
    ///
    /// Counted on the post-replacement transcript rather than the final text, so the
    /// signal is what was said — identical whether the mode pass succeeded, failed,
    /// or never ran.
    private func recordVocabularyUse(in text: String, for capture: ActiveCapture) {
        let current = modes.vocabulary()
        guard !current.isEmpty else { return }

        let stamp = now()
        var updated = current
        var changed = false

        for index in updated.indices where Self.transcript(text, mentions: updated[index].text) {
            updated[index].useCount += 1
            updated[index].lastUsed = stamp
            if let bundleID = capture.targetBundleID {
                updated[index].appBundleIDs.insert(bundleID)
            }
            changed = true
        }

        guard changed else { return }
        modes.saveVocabulary(updated)
    }

    /// Whole-word, case-insensitive containment.
    ///
    /// Whole-word because "API" inside "rapid" is not a use of the term, and a
    /// substring rule would inflate exactly the terms that are short enough to hide
    /// inside ordinary words. Boundaries are only asserted on a side that ends in a
    /// word character: `\b` next to "C++" would never match, and a term the user can
    /// type is a term that has to be countable.
    private static func transcript(_ text: String, mentions term: String) -> Bool {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return false }

        func isWordCharacter(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isLetter || character.isNumber || character == "_"
        }

        var pattern = NSRegularExpression.escapedPattern(for: needle)
        if isWordCharacter(needle.first) { pattern = "\\b" + pattern }
        if isWordCharacter(needle.last) { pattern += "\\b" }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    // MARK: - The 1–9 transient hotkeys

    /// Reconciles the digit registrations against the phase, from `phase`'s `didSet`.
    ///
    /// Spec §4.1: registered on entering `recording`, gone on leaving it. Both the
    /// plain digit and its push-to-talk-modified form are taken, because while the
    /// modifier is physically held the keystroke arrives as ⌥1 rather than 1 — and
    /// the capsule never becomes key, so a Carbon hotkey is the only way to receive
    /// it at all.
    private func syncModeDigitHotkeys() {
        guard let registrar = modes.modeDigits else { return }

        guard phase.isRecording else {
            registrar.unregisterModeDigits()
            return
        }

        let bindings = ModeDigitHotkeys.bindings(
            modeCount: availableModes().count,
            pushToTalk: modes.hotkeyBindings().pushToTalk)
        do {
            try registrar.registerModeDigits(bindings) { [weak self] digit in
                self?.switchMode(toModeAt: digit)
            }
        } catch let refusal as ModeDigitRefusal {
            // Carbon refused one. The other digits are registered — the registrar
            // attempts everything before it throws — so the cost is one key, and the
            // recording carries on. Said out loud rather than swallowed, which is
            // the defect this registration path was fixed for in the first place.
            notice = .modeDigitUnavailable(digit: refusal.digit)
        } catch {
            // The protocol only publishes `ModeDigitRefusal`, but a registration
            // failure must never take a live recording with it.
            notice = .modeDigitUnavailable(digit: 0)
        }
    }

    // MARK: - Retry

    /// Re-applies the record's mode to its stored raw transcript. This deliberately
    /// does not insert text: History owns a separate, explicit Re-insert action.
    func retryMode(recordID: UUID) async {
        guard active == nil,
              let stored = try? await recordLog.record(id: recordID),
              !stored.rawText.isEmpty
        else { return }

        let configuration = configuration()
        let mode = ModeResolver.resolve(
            explicitModeID: stored.modeID,
            frontmostBundleID: stored.targetBundleID,
            perAppMap: modes.perAppModeMap(),
            defaultModeID: configuration.defaultModeID,
            available: availableModes())
        let corrected = ReplacementEngine.apply(modes.replacements(), to: stored.rawText)
        let startedAt = now()
        let refinement = await refine(
            corrected,
            mode: mode,
            vocabularyTerms: modes.vocabulary(),
            targetAppName: stored.targetAppName,
            publishesPhase: false)
        let refined = refinement.text
        let elapsed = now().timeIntervalSince(startedAt)

        do {
            try await recordLog.update(id: recordID) { record in
                record.contextSummary = modes.saveContextMetadata() && modes.contextEnabled()
                    ? "Retry: original context not retained; no live context collected" : nil
                record.finalText = refined
                record.modeID = mode.id
                record.wordCount = TextMetrics.wordCount(refined)
                record.editDistanceRawToFinal = TextMetrics.normalizedEditDistance(
                    record.rawText, refined)
                record.timings.llmMs = Int((max(0, elapsed) * 1_000).rounded())
                if let usage = refinement.usage {
                    record.appendUsageEntriesPreservingLegacyCost([usage])
                }
            }
            recordRevision &+= 1
        } catch {
            // Do not publish a revision for a write that did not land.
        }
    }

    /// Re-transcribes a record from its **session** file — the durable artifact — as
    /// one clip. The per-segment temporaries may well have been swept by then.
    func retry(recordID: UUID) async {
        guard !phase.holdsMicrophone else { return }   // never disturb a live recording
        guard let stored = try? await recordLog.record(id: recordID),
              let audioFileName = stored.audioFileName
        else { return }

        let url = sessionDirectory.appendingPathComponent(audioFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        generationCounter += 1
        let configuration = configuration()
        let targetBundleID = stored.targetBundleID
        let vocabulary = modes.vocabulary()
        let capture = ActiveCapture(
            id: stored.id,
            generation: generationCounter,
            trigger: .menuBar,
            startedAt: now(),
            // The mode the dictation was recorded under, not the one that would be
            // resolved now: a retry re-runs a capture that already happened.
            modeID: stored.modeID,
            targetBundleID: targetBundleID,
            targetAppName: stored.targetAppName,
            vocabularyTerms: vocabulary,
            // One clip, index 0, so there is no continuity tail to leave room for
            // and the whole 224-token budget is the vocabulary's.
            vocabularySelection: VocabularyRanker.select(
                from: vocabulary,
                targetBundleID: targetBundleID,
                now: now(),
                reservedTokens: 0),
            recorder: nil,
            transcriber: makeTranscriber(),
            configuration: configuration,
            sessionAudioURL: url)
        capture.isRecording = false
        capture.recordedDuration = stored.speakingDuration
        active = capture
        activeTrigger = nil
        resourceEvents.send(.started(capture.id))
        phase = .transcribing

        capture.transcriber.configureVocabulary(capture.nativeVocabularyTerms)
        capture.transcriber.enqueue(
            index: 0,
            url: url,
            precedingSilence: 0,
            apiKey: apiKey(),
            model: capture.configuration.transcriptionModel,
            language: capture.configuration.language,
            vocabularyPrompt: capture.configuration.speechVocabularyEnabled ? capture.vocabularySelection.promptString : "")

        let whisperStartedAt = now()
        let results = await capture.transcriber.awaitAll()
        capture.selectedTranscriptionPath = .retryBatch
        await complete(capture, session: nil, results: results,
                       whisperStartedAt: whisperStartedAt, isRetry: true)
    }

    /// Records left unfinished by a crash, a quit, or a failure, whose audio is still
    /// on disk. History offers *Retry transcription* on exactly these.
    func recoverUnfinished() async -> [DictationRecord] {
        guard let records = try? await recordLog.all() else { return [] }
        return records.filter { record in
            // `isWorthRecovering` rather than `case .failed`: a capture whose segment
            // failed permanently is stored `.inserted` with a marker in the text, and
            // filtering on `.failed` skipped exactly the records that still had audio
            // worth re-sending. See `DictationRecord+Recovery.swift`.
            guard record.isWorthRecovering, let name = record.audioFileName else { return false }
            return FileManager.default.fileExists(
                atPath: sessionDirectory.appendingPathComponent(name).path)
        }
    }

    // MARK: - Device loss

    private func handleActiveDeviceLoss() {
        guard let capture = active, capture.isRecording else { return }
        capture.isRecording = false
        phase = .transcribing
        Task { @MainActor [weak self] in
            await self?.finishRecording(capture)
        }
    }

    // MARK: - Plumbing

    /// The elapsed seconds shown while recording, advanced by the meter rather than by
    /// a timer — there are no polling timers anywhere in this app. Republished only on
    /// a whole-second boundary, so a 30 Hz meter does not become 30 Hz of UI churn.
    private func advanceElapsed(for capture: ActiveCapture) {
        guard active === capture,
              case .recording(let elapsed, let modeName) = phase,
              let armedAt = capture.armedAt
        else { return }
        let seconds = (now().timeIntervalSince(armedAt)).rounded(.down)
        guard seconds > elapsed else { return }
        phase = .recording(elapsed: seconds, modeName: modeName)
    }

    private func detachEngine(from capture: ActiveCapture) {
        capture.recorder?.onSegmentClosed = nil
        guard active === capture else { return }
        audioEngine.onConvertedBuffer = nil
        audioEngine.onLevel = nil
        // Nothing is metering any more, so the waveform must not be left holding the
        // last level it saw.
        meterLevel = 0
        liveTranscriptPreview = nil
    }

    private func completePendingStart(generation: Int) {
        guard pendingStartGeneration == generation else { return }
        pendingStart = nil
    }

    private func cancelPendingStart(generation: Int) async {
        guard pendingStartGeneration == generation, let task = pendingStart else { return }
        task.cancel()
        await task.value
        if pendingStartGeneration == generation { pendingStart = nil }
    }

    /// Publishes a terminal phase **only if this capture still owns the screen**.
    ///
    /// This is the generation guard: when a newer capture is already recording, an
    /// older one finishing must insert its own words and then say nothing at all.
    private func settle(_ capture: ActiveCapture, phase newPhase: PipelinePhase) {
        capture.clipboardEndReader = nil
        capture.contextTask?.cancel()
        capture.contextTask = nil
        capture.contextAtStart = .empty
        switch newPhase {
        case .success, .error, .idle:
            resourceEvents.send(.ended(capture.id))
        case .arming, .recording, .transcribing, .refining:
            break
        }
        guard active === capture else { return }
        active = nil
        activeTrigger = nil
        liveTranscriptPreview = nil
        switch newPhase {
        case .success, .error: lastConcludedRecordID = capture.id
        case .idle, .arming, .recording, .transcribing, .refining: break
        }
        phase = newPhase
    }

    private func modeName(_ modeID: String) -> String {
        availableModes().first { $0.id == modeID }?.name ?? modeID
    }
}
