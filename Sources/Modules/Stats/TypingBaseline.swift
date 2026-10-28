import Foundation
import Observation
import os

/// The result of one 60-second typing test: how fast the user types when they are not
/// dictating, which is the only thing "time saved" can honestly be measured against.
///
/// There is no default value and no fallback. Until a test has been run there is no
/// baseline, `StatsSummary.timeSavedSeconds` is nil, and the UI says so (spec §11.2,
/// §10 empty states) rather than inventing an average-typist number the user never
/// produced.
struct TypingBaseline: Codable, Equatable, Sendable {

    /// Words typed per minute, measured over the same tokenizer and the same
    /// words-over-elapsed-time definition as dictation WPM
    /// (`DictationRecordDraft.wordsPerMinute`). Comparing two numbers computed two
    /// different ways would make the saving meaningless.
    let wordsPerMinute: Int

    /// 0…1 word-level agreement with the part of the prompt the typist reached.
    let accuracy: Double

    /// When the test was run. Stored so the UI can offer to re-run a stale baseline —
    /// typing speed on a new keyboard is not the speed measured two years ago.
    let measuredAt: Date

    /// How long the test actually ran. Kept because a 12-second test and a 60-second
    /// test are not equally good evidence, even at the same rate.
    let durationSeconds: TimeInterval

    /// The rate handed to the stats aggregator: gross speed discounted by accuracy.
    /// Typing you would have to go back and fix is not typing at that speed, and the
    /// comparison has to be against text the user would actually have shipped.
    var netWordsPerMinute: Double { Double(wordsPerMinute) * accuracy }

    /// Scores one completed typing test, or returns **nil when there is nothing to
    /// score** — a zero or negative duration, or no words typed. A test that measured
    /// nothing is not a baseline of zero; it is the absence of a baseline.
    ///
    /// - Parameters:
    ///   - typed: what the user actually typed.
    ///   - prompt: the passage they were typing from.
    ///   - duration: how long the test ran, in seconds.
    static func measured(
        typed: String,
        prompt: String,
        duration: TimeInterval,
        at date: Date
    ) -> TypingBaseline? {
        guard duration > 0 else { return nil }

        let typedWords = TextMetrics.words(in: typed)
        guard !typedWords.isEmpty else { return nil }

        let rate = DictationRecordDraft.wordsPerMinute(
            words: typedWords.count, speakingDuration: duration)

        // Compare against the PREFIX of the prompt the typist reached. Nobody finishes
        // the passage in 60 seconds, so scoring against the whole thing would report a
        // flawless typist as mostly wrong.
        let promptPrefix = TextMetrics.words(in: prompt)
            .prefix(typedWords.count)
            .joined(separator: " ")
        let distance = TextMetrics.normalizedEditDistance(
            promptPrefix, typedWords.joined(separator: " "))

        return TypingBaseline(
            wordsPerMinute: rate,
            accuracy: min(1, max(0, 1 - distance)),
            measuredAt: date,
            durationSeconds: duration)
    }
}

/// Persists the single typing baseline in `typing-baseline.json`.
///
/// One record, versioned, atomically written — the same shape as `CaptureStore`'s
/// index, without the audio reconciliation it has no need for. A missing file and an
/// unreadable file both read as "no baseline", which is a state the UI already has to
/// handle, so neither is an error worth surfacing. The bytes are never deleted: a
/// corrupt file is left on disk for inspection and simply overwritten by the next
/// successful test.
@MainActor
@Observable
final class TypingBaselineStore {

    private(set) var baseline: TypingBaseline?

    /// What `StatsAggregator.summarize(_:baselineWPM:...)` should be given: the
    /// accuracy-adjusted rate, or nil while there is no baseline.
    var baselineWPM: Double? { baseline?.netWordsPerMinute }

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.awah.captur", category: "stats")

    private static let fileVersion = 1

    private struct StoredFile: Codable {
        var version: Int
        var baseline: TypingBaseline
    }

    /// `baseURL` is the directory holding the file. Tests inject a temporary
    /// directory; production uses Application Support/Captur.
    init(baseURL: URL? = nil) {
        let base = baseURL ?? AppPaths.supportDirectory()
        fileURL = base.appendingPathComponent("typing-baseline.json")
        baseline = load()
    }

    /// Scores a completed test and stores it if it measured anything. Returns what was
    /// stored, or nil if the test produced no baseline — in which case any existing
    /// baseline is left exactly as it was, since a mistyped or abandoned re-run is not
    /// a reason to lose a good measurement.
    @discardableResult
    func record(
        typed: String,
        prompt: String,
        duration: TimeInterval,
        at date: Date = Date()
    ) -> TypingBaseline? {
        guard let measured = TypingBaseline.measured(
            typed: typed, prompt: prompt, duration: duration, at: date)
        else { return nil }

        save(measured)
        return measured
    }

    /// Replaces the baseline. The test is re-runnable, so the newest measurement wins
    /// outright rather than being averaged into the old one.
    func save(_ baseline: TypingBaseline) {
        self.baseline = baseline
        do {
            let data = try Self.encoder.encode(
                StoredFile(version: Self.fileVersion, baseline: baseline))
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Kept in memory so the current session still shows a real saving; the
            // next successful test re-attempts the write.
            logger.error(
                "Failed to save typing baseline: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forgets the baseline, returning the app to "run the typing test to see time
    /// saved". Time saved goes back to nil rather than to zero.
    func clear() {
        baseline = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() -> TypingBaseline? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let stored = try Self.decoder.decode(StoredFile.self, from: data)
            // A file from a future version describes a measurement this build cannot
            // interpret. Ignoring it shows the empty state; guessing at it would show
            // a number nobody computed.
            guard stored.version <= Self.fileVersion else { return nil }
            return stored.baseline
        } catch {
            logger.info(
                "Ignoring unreadable typing baseline: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Epoch seconds, matching `DictationRecordLog`: an exact date round trip.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
