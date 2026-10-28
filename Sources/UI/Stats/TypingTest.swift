import Foundation
import Observation

// MARK: - Constants and copy

/// The 60-second typing test, spec §11.2.
///
/// The test exists for one reason: `timeSavedSeconds` divides by a typing speed, and
/// there is no honest way to guess one. Everything here is arranged so the number that
/// reaches `TypingBaselineStore` is a measurement the user actually produced.
enum TypingTest {

    /// Spec §11.2: "a built-in 60-second typing test". Sixty **exactly** — the score is
    /// always computed over this, never over how long the deadline task happened to take
    /// to wake up.
    static let durationSeconds: TimeInterval = 60

    /// The largest growth in one update that a hand can produce. Anything bigger is a
    /// paste, and a pasted passage would store a four-figure baseline that silently
    /// destroys every time-saved figure on the stats page.
    ///
    /// Deliberately generous: 24 characters in one `TextEditor` update covers a fast
    /// burst and an IME committing a phrase, and is still two orders of magnitude short
    /// of the passage.
    static let maximumKeystrokeGrowth = 24

    /// What the user types from.
    ///
    /// Three properties are load-bearing rather than stylistic. It is **longer than
    /// anyone can type in a minute** (a 200 wpm typist covers 1 000 characters), so a
    /// fast typist never runs out of prompt and starts scoring correct keystrokes as
    /// wrong. It uses **no apostrophes, quotes or dashes**, so the passage cannot be
    /// failed by a keyboard layout or by macOS substituting a smart quote for a straight
    /// one. And it says what the test is for, because the one minute it costs is easier
    /// to give when the reason is on screen.
    static let passage = """
        The keyboard is a strange instrument. It rewards practice in a way that almost \
        nothing else on a desk does, and yet most people never practise it on purpose. \
        They simply type, for years, at whatever speed they happened to arrive at, and \
        they assume that is their speed. It usually is not. A minute of honest \
        measurement will tell you more about how you work than an afternoon of guessing.

        This test is one minute long. Type the passage in front of you as accurately as \
        you can. Do not rush past a mistake to make the number look better, because the \
        score counts only the characters you got right, and a fast run full of errors \
        will come out slower than a careful one. If you lose your place, keep going from \
        where the cursor is. The clock does not stop, and it does not need to.

        What the result is for is simple. Your dictation speed is easy to measure, \
        because the app already knows how long you spoke and how many words came out. \
        Your typing speed is the other half of that comparison, and there is no honest \
        way to guess it. Some people type ninety words a minute. Some type thirty. The \
        difference decides whether speaking is worth the trouble at all, so the app \
        refuses to assume.

        Run it again whenever something changes. A new keyboard, a new desk, a wrist \
        that has stopped hurting, a year of practice. The old number is kept only until \
        a new one replaces it, and the date is stored beside it so you can see how stale \
        it has become. Nothing here is a competition with anyone else.
        """
}

// MARK: - Score

/// One scored run, spec §11.2.
///
/// **WPM is `(correctCharacters / 5) / minutes`** — the standard net rate, where a "word"
/// is five characters and only characters typed correctly count towards it. This is not
/// the same definition as `DictationRecordDraft.wordsPerMinute`, which counts tokenized
/// words over speaking time, and the difference is deliberate: dictation produces words
/// and typing produces keystrokes, and the only fair comparison between them is one that
/// charges the typist for their mistakes.
///
/// Pure, and `seconds` is a parameter rather than a reading of a clock, so the whole
/// scoring model is testable without a test waiting sixty seconds.
struct TypingTestScore: Equatable, Sendable {

    /// The standard "word" for typing speed. Five characters, spaces included.
    static let charactersPerWord = 5.0

    let typedCharacters: Int
    /// Characters that match the passage **at the position they were typed**. A letter
    /// that appears later in the passage but not here is wrong, which is the only
    /// definition under which the count can be computed as the user types.
    let correctCharacters: Int
    let seconds: TimeInterval

    /// The measurement: `(correctCharacters / 5) / minutes`.
    var wordsPerMinute: Double {
        rate(of: correctCharacters)
    }

    /// Every keystroke, right or wrong. Shown beside the net rate so a user who typed
    /// fast and badly can see which half of the number to work on.
    var grossWordsPerMinute: Double {
        rate(of: typedCharacters)
    }

    /// 0…1 of the characters typed that were the right ones. Zero when nothing was
    /// typed — but a score with nothing typed cannot be built, so that branch only
    /// guards the arithmetic.
    var accuracy: Double {
        typedCharacters > 0 ? Double(correctCharacters) / Double(typedCharacters) : 0
    }

    private func rate(of characters: Int) -> Double {
        guard seconds > 0 else { return 0 }
        return (Double(characters) / Self.charactersPerWord) / (seconds / 60)
    }

    /// Scores a run, or returns **nil when there is nothing to score**: a non-positive
    /// duration, or nothing typed. A run that measured nothing is not a baseline of zero;
    /// it is the absence of a baseline, and `TypingBaseline` makes the same distinction
    /// for the same reason.
    static func score(typed: String, prompt: String, seconds: TimeInterval) -> TypingTestScore? {
        guard seconds > 0 else { return nil }

        let typedCharacters = Array(typed)
        guard !typedCharacters.isEmpty else { return nil }

        // Compared against the PREFIX the typist reached, position by position. Scoring
        // against the whole passage would report a flawless typist who covered a fifth of
        // it as 20 % accurate — and characters typed past the end of the passage have
        // nothing to match, so they can never be correct.
        let promptCharacters = Array(prompt)
        var correct = 0
        for index in 0..<min(typedCharacters.count, promptCharacters.count)
        where typedCharacters[index] == promptCharacters[index] {
            correct += 1
        }

        return TypingTestScore(
            typedCharacters: typedCharacters.count,
            correctCharacters: correct,
            seconds: seconds)
    }

    /// The record `TypingBaselineStore` persists.
    ///
    /// The store's `netWordsPerMinute` — the value `StatsAggregator` divides by — is
    /// `wordsPerMinute * accuracy`, so the gross rate goes in the rate field and the
    /// accuracy beside it, and their product is this score's `wordsPerMinute`. The stored
    /// rate is an `Int`, so the reconstructed net rate can differ from the measured one by
    /// up to half a word per minute; `TypingTestTests` pins that bound. Storing the net
    /// rate instead would make the store's own `netWordsPerMinute` discount accuracy
    /// twice.
    func baseline(at date: Date) -> TypingBaseline {
        TypingBaseline(
            wordsPerMinute: Int(grossWordsPerMinute.rounded()),
            accuracy: min(1, max(0, accuracy)),
            measuredAt: date,
            durationSeconds: seconds)
    }
}

// MARK: - Session

/// One run of the test: the state machine between "nothing typed yet" and "a baseline was
/// saved".
///
/// **The clock is injected and the finish time is a parameter.** Nothing here reads
/// `Date()` on its own behalf and nothing here schedules anything, which is what lets the
/// whole 60-second rule be tested in microseconds — and what keeps the countdown out of a
/// polling timer (spec §15). `TypingTestView` owns the single `Task.sleep` that wakes at
/// the deadline; see `docs/wiring/task26-wiring.md`.
@MainActor
@Observable
final class TypingTestSession {

    enum Phase: Equatable {
        case ready
        /// The clock started on the first keystroke, not on a button: charging the user's
        /// reaction time to their typing speed would understate every baseline.
        case running(startedAt: Date)
        case finished(TypingTestScore)
    }

    let prompt: String
    let duration: TimeInterval

    private(set) var phase: Phase = .ready
    private(set) var typed = ""
    /// True for exactly as long as the last input was refused, so the view can say why
    /// nothing happened instead of appearing broken.
    private(set) var didRefuseInput = false

    private let now: () -> Date
    private let saveBaseline: (TypingBaseline) -> Void

    init(
        prompt: String = TypingTest.passage,
        duration: TimeInterval = TypingTest.durationSeconds,
        now: @escaping () -> Date,
        saveBaseline: @escaping (TypingBaseline) -> Void
    ) {
        self.prompt = prompt
        self.duration = duration
        self.now = now
        self.saveBaseline = saveBaseline
    }

    /// The live baseline store as the composition root sees it.
    static func live(
        store: TypingBaselineStore,
        prompt: String = TypingTest.passage
    ) -> TypingTestSession {
        TypingTestSession(prompt: prompt, now: Date.init) { [weak store] baseline in
            store?.save(baseline)
        }
    }

    // MARK: Derived

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var startedAt: Date? {
        if case .running(let date) = phase { return date }
        return nil
    }

    /// When the run ends, or nil while it has not started. The view's countdown is
    /// anchored to this and nothing else, so the digits on screen and the number that
    /// gets scored cannot disagree.
    var deadline: Date? {
        startedAt?.addingTimeInterval(duration)
    }

    var score: TypingTestScore? {
        if case .finished(let score) = phase { return score }
        return nil
    }

    /// Floored at zero: a countdown that goes negative while the deadline task is waking
    /// up would render as a minus sign in the largest text on the sheet.
    func remainingSeconds(at date: Date) -> TimeInterval? {
        guard let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(date))
    }

    // MARK: Typing

    /// Applies the whole new contents of the input field.
    ///
    /// Growth beyond `TypingTest.maximumKeystrokeGrowth` is refused outright rather than
    /// truncated: a truncated paste is still not something the user typed. Deletion is
    /// never refused, however large — backspace is typing.
    func type(_ text: String) {
        guard !isFinished else { return }

        guard text.count - typed.count <= TypingTest.maximumKeystrokeGrowth else {
            didRefuseInput = true
            return
        }
        didRefuseInput = false

        if case .ready = phase {
            // An empty update while nothing has been typed is not a keystroke, so it does
            // not start the clock.
            guard !text.isEmpty else { return }
            phase = .running(startedAt: now())
        }

        typed = text
    }

    private var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    // MARK: Ending

    /// Ends a run that reached its deadline: scores it over **exactly** `duration` and
    /// saves the baseline.
    ///
    /// Returns nil — and saves nothing — when the run has not reached the deadline. That
    /// is the rule that makes "abandoning it mid-way changes nothing" true even if the
    /// view calls this on its way out: half a test is not a slow test, and a 30-second
    /// sample stored as a 60-second one is a baseline the user never produced.
    ///
    /// `date` is a parameter rather than a reading of the clock so the caller passes the
    /// deadline it actually waited for. Scoring over `duration` and not over
    /// `date - startedAt` means an overdue wake-up cannot quietly change what was
    /// measured.
    @discardableResult
    func finish(at date: Date) -> TypingBaseline? {
        guard case .running(let startedAt) = phase else { return nil }
        guard date.timeIntervalSince(startedAt) >= duration else { return nil }

        guard let score = TypingTestScore.score(
            typed: typed, prompt: prompt, seconds: duration)
        else {
            // A full minute with nothing left in the field. There is no baseline of zero,
            // so the run simply did not happen.
            reset()
            return nil
        }

        phase = .finished(score)
        let baseline = score.baseline(at: date)
        saveBaseline(baseline)
        return baseline
    }

    /// The user left. Nothing is scored and nothing is saved — including when a good
    /// baseline is already on disk, which stays exactly as it was.
    func abandon() {
        reset()
    }

    /// Clears a finished run so the sheet can be used again without being rebuilt.
    func restart() {
        reset()
    }

    private func reset() {
        phase = .ready
        typed = ""
        didRefuseInput = false
    }

    // MARK: What the view paints

    /// The passage split into the three runs the view colours: right so far, wrong from
    /// the first mistake to the cursor, and not yet reached.
    ///
    /// Three `Text` runs rather than a per-character `AttributedString`: this is rebuilt
    /// on every keystroke, and attributing 1 600 characters sixty times a second is work
    /// nobody sees. Splitting at the FIRST mistake — rather than marking each wrong
    /// character — also reads better: it points at where the user went wrong instead of
    /// speckling the paragraph.
    struct ProgressSplit: Equatable {
        var correct: String
        var wrong: String
        var remaining: String
    }

    static func split(typed: String, prompt: String) -> ProgressSplit {
        let typedCharacters = Array(typed)
        let promptCharacters = Array(prompt)
        let reached = min(typedCharacters.count, promptCharacters.count)

        var matched = 0
        while matched < reached, typedCharacters[matched] == promptCharacters[matched] {
            matched += 1
        }

        return ProgressSplit(
            correct: String(promptCharacters[0..<matched]),
            wrong: String(promptCharacters[matched..<reached]),
            remaining: String(promptCharacters[reached...]))
    }

    var progressSplit: ProgressSplit {
        Self.split(typed: typed, prompt: prompt)
    }
}
