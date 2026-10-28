import AVFoundation
import Foundation

/// Dispatches recorded segments to Groq and collects their transcripts.
///
/// Groq's Whisper endpoint is batch-only, so the only way dictation can feel
/// instant is to close a segment at a pause and upload it **while the user keeps
/// talking**. `enqueue` therefore returns immediately and is safe to call from
/// the recording path; `awaitAll` is the single join point at the end.
protocol DictationTranscribing: AnyObject, Sendable {
    /// Fire-and-track. Safe to call while recording continues.
    func enqueue(index: Int, url: URL, precedingSilence: TimeInterval,
                 apiKey: String, model: String, language: String?,
                 vocabularyPrompt: String)
    /// Awaits every enqueued segment; returns them in index order.
    func awaitAll() async -> [SegmentResult]
    /// Optional streaming surface used by on-device engines. Cloud/batch
    /// transcribers intentionally inherit the no-op defaults below.
    func configureVocabulary(_ terms: [String])
    func setLiveTranscriptHandler(_ handler: (@Sendable (String) -> Void)?)
    func beginLiveTranscription(vocabularyTerms: [String])
    func ingestLiveAudio(_ buffer: AVAudioPCMBuffer)
    /// Supplies the durable, continuous recording after its writer has closed. A live
    /// transcriber may use it for an authoritative batch pass; other providers ignore it.
    func setFinalRecordingURL(_ url: URL)
    /// Which transcription path produced the text returned by `awaitAll`.
    /// Batch/cloud providers use the default; streaming providers override it so
    /// telemetry records fallbacks rather than the configured happy path.
    func selectedTranscriptionPath() -> DictationTranscriptionPath?
    func warmConnection(apiKey: String)
    func reset()
}

extension DictationTranscribing {
    func configureVocabulary(_ terms: [String]) {}
    func setLiveTranscriptHandler(_ handler: (@Sendable (String) -> Void)?) {}
    func beginLiveTranscription(vocabularyTerms: [String]) {}
    func ingestLiveAudio(_ buffer: AVAudioPCMBuffer) {}
    func setFinalRecordingURL(_ url: URL) {}
    func selectedTranscriptionPath() -> DictationTranscriptionPath? { nil }
}

/// The concurrent half of the transcription pipeline.
///
/// Every enqueued segment gets its own `Task`, so N segments are in flight at
/// once and the wall-clock cost of a dictation is the slowest segment rather
/// than the sum of all of them. Two pieces of state make that safe:
///
/// * the **registry** — a lock-guarded `[Int: Task]`, because `enqueue` is
///   synchronous (the recorder must not `await` to hand a segment over) and must
///   be visible to a `awaitAll()` called on the very next line;
/// * the **completed transcripts** — actor-isolated, because they are written by
///   whichever segment happens to finish first and read by whichever segment
///   happens to start next.
///
/// A segment that exhausts its retries resolves to `nil` rather than throwing.
/// One dead segment out of twelve must cost the user that segment, not the whole
/// dictation; `TranscriptStitcher` renders the hole as a visible `[…]`.
actor GroqTranscriber: DictationTranscribing {

    /// Attempts per segment, including the first.
    static let maxAttempts = 3

    /// Delay *after* a failed attempt, indexed by that attempt. Roughly 3x, which
    /// clears a rate-limit blip without holding the pipeline open for long — a
    /// segment is worth at most a few seconds of retrying before the user is
    /// better served by the rest of their transcript arriving.
    static let backoffSchedule: [TimeInterval] = [0.4, 1.2, 3.6]

    /// How much of the previous transcript is replayed as continuity context.
    /// Enough to carry a clause across the cut, short enough that it cannot
    /// crowd the vocabulary out of the 224-token prompt.
    static let continuityTailWordCount = 30

    /// Separates the vocabulary list from the continuity tail, so the last term
    /// cannot merge into the first word of the previous sentence.
    private static let promptSeparator = ". "

    private static let modelsURL = URL(string: "https://api.groq.com/openai/v1/models")

    private nonisolated let session: URLSession
    private nonisolated let client: GroqClient
    private nonisolated let sleeper: @Sendable (TimeInterval) async -> Void
    private nonisolated let registry = TranscriptionSegmentRegistry()

    /// Text of every segment that has come back, for the run identified by
    /// `completedGeneration`. Actor-isolated: concurrently written.
    private var completedTexts: [Int: String] = [:]
    private var completedAttemptCounts: [Int: Int] = [:]
    private var completedGeneration = 0

    /// - Parameter sleeper: retry backoff. Injectable so tests can assert the
    ///   delay that *would* have been taken without spending it.
    init(
        session: URLSession = .shared,
        sleeper: (@Sendable (TimeInterval) async -> Void)? = nil
    ) {
        self.session = session
        self.client = GroqClient(session: session)
        self.sleeper = sleeper ?? { seconds in
            // Clamped at both ends: `UInt64(_: Double)` traps on a negative or
            // absurd value, and a hostile Retry-After must not park a segment
            // for an hour.
            let clamped = min(max(seconds, 0), 120)
            try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
        }
    }

    deinit {
        registry.cancelAll()
    }

    // MARK: - Dispatch

    nonisolated func enqueue(
        index: Int,
        url: URL,
        precedingSilence: TimeInterval,
        apiKey: String,
        model: String,
        language: String?,
        vocabularyPrompt: String
    ) {
        let generation = registry.currentGeneration

        // `[weak self]` deliberately: the registry holds the task and the actor
        // holds the registry, so a strong capture would be a retain cycle that
        // outlives the dictation.
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.transcribeSegment(
                index: index,
                url: url,
                apiKey: apiKey,
                model: model,
                language: language,
                vocabularyPrompt: vocabularyPrompt,
                generation: generation
            )
        }

        // A `reset()` that landed between reading the generation and registering
        // means this segment belongs to a dictation that no longer exists.
        if !registry.register(
            index: index,
            precedingSilence: precedingSilence,
            task: task,
            expectedGeneration: generation
        ) {
            task.cancel()
        }
    }

    func awaitAll() async -> [SegmentResult] {
        var results: [Int: SegmentResult] = [:]
        var awaited: Set<Int> = []

        // Re-snapshot after every join: awaiting suspends the actor, and a
        // recorder can legitimately hand over a final tail segment while we are
        // parked on an earlier one.
        while true {
            let pending = registry.snapshot().filter { !awaited.contains($0.index) }
            if pending.isEmpty { break }

            for entry in pending {
                awaited.insert(entry.index)
                let text = await entry.task.value
                results[entry.index] = SegmentResult(
                    index: entry.index,
                    text: text,
                    precedingSilence: entry.precedingSilence,
                    attemptCount: completedAttemptCounts[entry.index] ?? 0
                )
            }
        }

        return results.values.sorted { $0.index < $1.index }
    }

    /// Opens the HTTP/2 connection to Groq before there is anything to send.
    ///
    /// Called on hotkey-*down*, so DNS, TCP and the TLS handshake are paid for
    /// while the user is drawing breath instead of on the first segment. The
    /// outcome is deliberately ignored — a failed warm-up is not an error, it
    /// just means the first upload pays the setup cost as it always would have.
    nonisolated func warmConnection(apiKey: String) {
        guard let url = Self.modelsURL else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = self.session
        // Detached: this must neither block the caller nor die with whatever
        // task the hotkey handler happens to be running on.
        Task.detached(priority: .utility) {
            _ = try? await session.data(for: request)
        }
    }

    /// Abandons the current dictation: in-flight uploads are cancelled and the
    /// continuity context is dropped, so the next dictation cannot inherit the
    /// previous one's words.
    nonisolated func reset() {
        registry.cancelAll()
    }

    // MARK: - One segment

    private func transcribeSegment(
        index: Int,
        url: URL,
        apiKey: String,
        model: String,
        language: String?,
        vocabularyPrompt: String,
        generation: Int
    ) async -> String? {
        // Resolved once, at dispatch: the prompt describes the moment this
        // segment was sent, and re-resolving it per attempt would make an
        // identical retry a different request.
        let prompt = Self.assemblePrompt(
            vocabularyPrompt: vocabularyPrompt,
            continuityTail: continuityTail(before: index, generation: generation)
        )

        var attemptCount = 0
        for attempt in 0..<Self.maxAttempts {
            if Task.isCancelled {
                recordAttemptCount(index: index, count: attemptCount, generation: generation)
                return nil
            }
            attemptCount += 1

            do {
                let text = try await client.transcribe(
                    fileURL: url,
                    apiKey: apiKey,
                    prompt: prompt.isEmpty ? nil : prompt,
                    maxRetries: 0,
                    model: model,
                    language: language
                )
                recordCompletion(
                    index: index,
                    text: text,
                    attemptCount: attemptCount,
                    generation: generation)
                return text
            } catch {
                guard Self.isRetryable(error), attempt < Self.maxAttempts - 1 else {
                    recordAttemptCount(
                        index: index, count: attemptCount, generation: generation)
                    return nil
                }
                await sleeper(Self.retryDelay(for: error, afterAttempt: attempt))
            }
        }

        return nil
    }

    /// Only errors that a second identical request could plausibly survive.
    ///
    /// A bad key, a rejected file or an unparseable success body will fail the
    /// same way three times; spending 4 seconds proving that delays every other
    /// segment's result reaching the user.
    static func isRetryable(_ error: Error) -> Bool {
        guard let groqError = error as? GroqError else { return false }
        switch groqError {
        case .transient, .offline:
            return true
        case .permanent, .decoding, .cancelled, .fileMissing:
            return false
        }
    }

    /// The server's own `Retry-After` wins when it sent one — it knows when the
    /// rate limit clears and we do not.
    static func retryDelay(for error: Error, afterAttempt attempt: Int) -> TimeInterval {
        if let groqError = error as? GroqError,
           case .transient(_, _, let retryAfter) = groqError,
           let retryAfter,
           retryAfter >= 0 {
            return retryAfter
        }
        let index = min(max(attempt, 0), backoffSchedule.count - 1)
        return backoffSchedule[index]
    }

    // MARK: - Continuity context

    /// The transcript of the newest **completed** segment that precedes `index`.
    ///
    /// Deliberately never waits. The obvious version — "use segment N-1's text"
    /// — would make segment N block on segment N-1, which turns a concurrent
    /// pipeline back into a serial one and, when N-1 is sitting in a 3.6 s
    /// backoff, adds that delay to every segment behind it. Continuity is a
    /// nice-to-have; concurrency is the entire point of segmenting.
    private func continuityTail(before index: Int, generation: Int) -> String {
        guard adoptCurrentGeneration() == generation else { return "" }
        guard
            let newest = completedTexts.keys.filter({ $0 < index }).max(),
            let text = completedTexts[newest]
        else { return "" }
        return text
    }

    private func recordCompletion(
        index: Int,
        text: String,
        attemptCount: Int,
        generation: Int
    ) {
        guard adoptCurrentGeneration() == generation else { return }
        completedTexts[index] = text
        completedAttemptCounts[index] = attemptCount
    }

    private func recordAttemptCount(index: Int, count: Int, generation: Int) {
        guard adoptCurrentGeneration() == generation else { return }
        completedAttemptCounts[index] = count
    }

    /// Drops continuity state belonging to a dictation that `reset()` ended.
    ///
    /// Done lazily on read/write rather than inside `reset()`, because `reset()`
    /// is synchronous and cannot reach actor state without an ordering race
    /// against segments enqueued immediately afterwards.
    private func adoptCurrentGeneration() -> Int {
        let current = registry.currentGeneration
        if current != completedGeneration {
            completedGeneration = current
            completedTexts.removeAll()
            completedAttemptCounts.removeAll()
        }
        return current
    }

    // MARK: - Prompt assembly

    /// Builds Whisper's `prompt`: the user's vocabulary, then the tail of the
    /// previous segment, truncated to Groq's hard 224-token cap.
    ///
    /// The vocabulary goes first and is trimmed last. It is the part the user
    /// deliberately configured — the spellings of names and jargon that are
    /// wrong in every single dictation without it — whereas the continuity tail
    /// only repairs one seam, and `TranscriptStitcher` already repairs seams
    /// downstream. Over-budget prompts are rejected outright by the API, so this
    /// is a cap, not a preference.
    ///
    /// The tail is trimmed from the front, keeping the words nearest the cut:
    /// those are the ones the next segment continues from.
    static func assemblePrompt(vocabularyPrompt: String, continuityTail: String) -> String {
        let budget = VocabularyRanker.whisperPromptTokenBudget
        let vocabulary = truncated(
            vocabularyPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            to: budget
        )

        var words = continuityTail
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        if words.count > continuityTailWordCount {
            words = Array(words.suffix(continuityTailWordCount))
        }

        while !words.isEmpty {
            let tail = words.joined(separator: " ")
            let candidate = vocabulary.isEmpty
                ? tail
                : vocabulary + promptSeparator + tail
            if VocabularyRanker.estimatedTokens(in: candidate) <= budget {
                return candidate
            }
            words.removeFirst()
        }

        return vocabulary
    }

    /// Trims a vocabulary prompt into `budget` tokens, dropping whole terms
    /// first so the result stays a readable list rather than a severed word.
    private static func truncated(_ text: String, to budget: Int) -> String {
        guard VocabularyRanker.estimatedTokens(in: text) > budget else { return text }

        var fragments = text.components(separatedBy: ", ")
        while fragments.count > 1 {
            fragments.removeLast()
            let candidate = fragments.joined(separator: ", ")
            if VocabularyRanker.estimatedTokens(in: candidate) <= budget {
                return candidate
            }
        }

        // A single term longer than the whole budget can only be cut mid-word.
        var single = fragments.first ?? ""
        while !single.isEmpty, VocabularyRanker.estimatedTokens(in: single) > budget {
            single.removeLast(min(8, single.count))
        }
        return single
    }
}

// MARK: - Registry

/// The in-flight segment table.
///
/// Lock-guarded rather than actor-isolated so that `enqueue` can stay
/// synchronous — the recorder hands a segment over from a non-async context —
/// while `awaitAll()` called immediately afterwards still sees every task. An
/// actor would defer registration to a later executor hop, and the two hops have
/// no guaranteed order.
final class TranscriptionSegmentRegistry: @unchecked Sendable {
    struct Entry {
        let index: Int
        let precedingSilence: TimeInterval
        let task: Task<String?, Never>
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    /// Bumped by `reset()`. Results from an older generation are discarded.
    private var generation = 0

    var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// - Returns: false when the run was reset underneath this segment, in which
    ///   case the caller must cancel the task it just created.
    func register(
        index: Int,
        precedingSilence: TimeInterval,
        task: Task<String?, Never>,
        expectedGeneration: Int
    ) -> Bool {
        lock.lock()
        guard generation == expectedGeneration else {
            lock.unlock()
            return false
        }
        let replaced = entries[index]?.task
        entries[index] = Entry(
            index: index,
            precedingSilence: precedingSilence,
            task: task
        )
        lock.unlock()

        // Re-enqueuing an index replaces it; the stale upload is dead weight.
        replaced?.cancel()
        return true
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.sorted { $0.index < $1.index }
    }

    func cancelAll() {
        lock.lock()
        let cancelled = entries.values.map(\.task)
        entries.removeAll()
        generation &+= 1
        lock.unlock()

        for task in cancelled {
            task.cancel()
        }
    }
}
