import Foundation

/// The state one dictation owns for its whole life, including after a newer capture
/// has taken over the screen. Reference semantics on purpose: a completion that lands
/// late must see the same object it started with, not a stale copy.
@MainActor
final class ActiveCapture {
    let id: UUID
    let generation: Int
    let trigger: CaptureTrigger
    let startedAt: Date
    let targetBundleID: String?
    /// The frontmost app's display name, resolved at `begin` beside its bundle ID.
    /// A mode with `includeAppNameContext` is told which app was being dictated
    /// *into*, which is not necessarily the app that is frontmost by the time the
    /// mode pass runs.
    let targetAppName: String?
    let recorder: (any SegmentRecording)?
    let transcriber: any DictationTranscribing
    /// Capture settings are snapshotted at key-down. Settings changed while this
    /// recording is in flight apply to the next dictation, never halfway through one.
    let configuration: DictationPipeline.Configuration
    /// The durable session file, including on a retry where there is no recorder.
    let sessionAudioURL: URL?

    /// The whole vocabulary as it stood when this dictation started.
    ///
    /// Snapshotted rather than read live so every segment of one capture sends the
    /// same prompt: a list edited mid-dictation would otherwise make two segments of
    /// the same sentence disagree about how a name is spelled. It also feeds the
    /// mode's spelling section, which spec §7.3 exempts from Whisper's cap.
    let vocabularyTerms: [VocabularyTerm]
    /// The budgeted subset of `vocabularyTerms` that fits Whisper's prompt, and the
    /// prompt string itself.
    let vocabularySelection: VocabularySelection
    let nativeVocabularyTerms: [String]

    var contextTask: Task<ContextSnapshot, Never>?
    var contextAtStart = ContextSnapshot.empty
    var contextSummary: String?
    var capturesClipboard = false
    var modeWasManuallySelected = false
    var clipboardEndReader: (() -> ClipboardContextUpdate)?
    var modeID: String
    var armedAt: Date?
    /// Stop edge → first byte dispatchable: engine teardown plus closing both audio
    /// writers. Carried on the capture rather than returned, because the record is
    /// written well after `finishRecording` has gone out of scope.
    var finalizeSeconds: TimeInterval = 0
    var voiceProcessingActive = false
    var isRecording = true
    /// Set by `cancel`. The one thing that revokes a capture's right to insert — a
    /// newer capture starting does not.
    var isRevoked = false
    var dispatchedIndices: Set<Int> = []
    var dispatchedDurations: [TimeInterval] = []
    /// Known up front only for a retry, where no recording happens.
    var recordedDuration: TimeInterval = 0
    var selectedTranscriptionPath: DictationTranscriptionPath?

    init(id: UUID,
         generation: Int,
         trigger: CaptureTrigger,
         startedAt: Date,
         modeID: String,
         targetBundleID: String?,
         targetAppName: String?,
         vocabularyTerms: [VocabularyTerm] = [],
         vocabularySelection: VocabularySelection = .empty,
         recorder: (any SegmentRecording)?,
         transcriber: any DictationTranscribing,
         configuration: DictationPipeline.Configuration = .default,
         sessionAudioURL: URL? = nil) {
        self.id = id
        self.generation = generation
        self.trigger = trigger
        self.startedAt = startedAt
        self.modeID = modeID
        self.targetBundleID = targetBundleID
        self.targetAppName = targetAppName
        self.vocabularyTerms = vocabularyTerms
        self.vocabularySelection = vocabularySelection
        let nativeEnabled = configuration.speechVocabularyEnabled &&
            (!configuration.transcriptionProvider.supportsAcousticVocabularyBoosting || configuration.parakeetVocabularyBoosting)
        self.nativeVocabularyTerms = nativeEnabled ? SpeechVocabulary.bounded(VocabularyRanker.rank(
            vocabularyTerms, targetBundleID: targetBundleID, now: startedAt).map(\.text)) : []
        self.recorder = recorder
        self.transcriber = transcriber
        self.configuration = configuration
        self.sessionAudioURL = sessionAudioURL
    }

    /// Mirrors `SegmentRecorder`'s naming so the record can name its audio file before
    /// the recording has produced one.
    func sessionURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).flac")
    }
}
