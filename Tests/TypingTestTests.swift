import XCTest
@testable import Captur

/// The 60-second typing test, spec §11.2.
///
/// The formula is exact and the guards around it matter more than the formula: a test
/// that can be abandoned into a baseline, or re-run without moving its date, produces a
/// "time saved" number nobody measured. Every assertion here is one of those guards.
@MainActor
final class TypingTestTests: XCTestCase {

    /// Whole seconds keep the store's `.secondsSince1970` round trip exact, so a
    /// persisted baseline can be compared for equality rather than approximately.
    private let startedAt = Date(timeIntervalSince1970: 1_784_000_000)

    /// Collects what the session tried to persist, so a test can assert that a run saved
    /// **nothing** — which is the only way to check the abandon rules.
    private final class BaselineSpy {
        private(set) var saved: [TypingBaseline] = []
        func save(_ baseline: TypingBaseline) { saved.append(baseline) }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-typing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A prompt of one repeated character, so "how many characters are correct" is
    /// arithmetic rather than a reading exercise.
    private func flatPrompt(_ count: Int = 4_000) -> String {
        String(repeating: "a", count: count)
    }

    /// Feeds `text` in hand-sized chunks. The session refuses a jump no hand could
    /// produce (see the paste test), so a test that wants 300 characters typed has to
    /// type them rather than assign them.
    private func typeAll(_ text: String, into session: TypingTestSession) {
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            index = min(index + TypingTest.maximumKeystrokeGrowth, characters.count)
            session.type(String(characters[0..<index]))
        }
    }

    private func makeSession(
        prompt: String,
        clock: @escaping () -> Date,
        save: @escaping (TypingBaseline) -> Void = { _ in }
    ) -> TypingTestSession {
        TypingTestSession(prompt: prompt, now: clock, saveBaseline: save)
    }

    // MARK: - The formula

    /// `(correctCharacters / 5) / minutes`. 300 correct characters in one minute is
    /// 60 wpm — the definition, not an approximation of it.
    func testWordsPerMinuteIsCorrectCharactersOverFiveThenMinutes() throws {
        let score = try XCTUnwrap(
            TypingTestScore.score(
                typed: String(repeating: "a", count: 300),
                prompt: flatPrompt(),
                seconds: 60))

        XCTAssertEqual(score.correctCharacters, 300)
        XCTAssertEqual(score.wordsPerMinute, 60, accuracy: 0.0001)
    }

    /// The divisor is minutes, not "the test length", so the formula is checked at a
    /// length the product never uses.
    func testTheRateIsPerMinuteAtAnyDuration() throws {
        let score = try XCTUnwrap(
            TypingTestScore.score(
                typed: String(repeating: "a", count: 150),
                prompt: flatPrompt(),
                seconds: 30))
        XCTAssertEqual(score.wordsPerMinute, 60, accuracy: 0.0001)
    }

    /// Only correct characters count. A minute of typing the wrong thing is zero words
    /// per minute, and it is a real measurement rather than a missing one.
    func testZeroCorrectCharactersScoresZero() throws {
        let score = try XCTUnwrap(
            TypingTestScore.score(
                typed: String(repeating: "z", count: 400),
                prompt: flatPrompt(),
                seconds: 60))

        XCTAssertEqual(score.correctCharacters, 0)
        XCTAssertEqual(score.wordsPerMinute, 0, accuracy: 0.0001)
        XCTAssertEqual(score.accuracy, 0, accuracy: 0.0001)
        XCTAssertEqual(score.grossWordsPerMinute, 80, accuracy: 0.0001)
    }

    func testEveryCharacterCorrectScoresTheGrossRate() throws {
        let score = try XCTUnwrap(
            TypingTestScore.score(
                typed: String(repeating: "a", count: 400),
                prompt: flatPrompt(),
                seconds: 60))

        XCTAssertEqual(score.accuracy, 1, accuracy: 0.0001)
        XCTAssertEqual(score.wordsPerMinute, score.grossWordsPerMinute, accuracy: 0.0001)
    }

    /// Nobody finishes the passage in 60 seconds. Accuracy is measured against the
    /// **prefix the typist reached**; against the whole passage a flawless typist scores
    /// a few per cent and the baseline collapses.
    func testAccuracyIsMeasuredAgainstThePromptPrefixReached() throws {
        let prompt = TypingTest.passage
        let typed = String(prompt.prefix(100))

        let score = try XCTUnwrap(
            TypingTestScore.score(typed: typed, prompt: prompt, seconds: 60))

        XCTAssertEqual(score.correctCharacters, 100)
        XCTAssertEqual(score.accuracy, 1, accuracy: 0.0001)
        XCTAssertEqual(score.wordsPerMinute, 20, accuracy: 0.0001)
    }

    /// Position matters: a character typed where a different one belongs is wrong even
    /// though it appears elsewhere in the passage.
    func testCharactersAreComparedByPosition() throws {
        let score = try XCTUnwrap(
            TypingTestScore.score(typed: "abcd", prompt: "abdc", seconds: 60))
        XCTAssertEqual(score.correctCharacters, 2)
        XCTAssertEqual(score.typedCharacters, 4)
        XCTAssertEqual(score.accuracy, 0.5, accuracy: 0.0001)
    }

    /// Typing past the end of the passage cannot be correct — there is nothing there to
    /// match — but it still counts as typing, so the gross rate rises and accuracy falls.
    func testCharactersTypedPastTheEndOfThePromptAreNotCorrect() throws {
        let score = try XCTUnwrap(
            TypingTestScore.score(typed: "abcdef", prompt: "abc", seconds: 60))
        XCTAssertEqual(score.correctCharacters, 3)
        XCTAssertEqual(score.typedCharacters, 6)
        XCTAssertEqual(score.accuracy, 0.5, accuracy: 0.0001)
    }

    // MARK: - Refusing to invent a number

    func testTypingNothingProducesNoScore() {
        XCTAssertNil(TypingTestScore.score(typed: "", prompt: flatPrompt(), seconds: 60))
    }

    func testANonPositiveDurationProducesNoScore() {
        XCTAssertNil(TypingTestScore.score(typed: "aaa", prompt: flatPrompt(), seconds: 0))
        XCTAssertNil(TypingTestScore.score(typed: "aaa", prompt: flatPrompt(), seconds: -60))
    }

    // MARK: - The 60 seconds

    func testTheTestIsExactlySixtySeconds() {
        XCTAssertEqual(TypingTest.durationSeconds, 60, accuracy: 0.0001)
    }

    /// The clock starts on the first keystroke, not on a button, so the user's reaction
    /// time is not charged to their typing speed.
    func testTheFirstKeystrokeStartsTheClock() {
        var clock = startedAt
        let session = makeSession(prompt: flatPrompt(), clock: { clock })

        XCTAssertEqual(session.phase, .ready)
        XCTAssertNil(session.deadline)

        clock = startedAt.addingTimeInterval(9)
        session.type("a")

        XCTAssertEqual(session.phase, .running(startedAt: clock))
        XCTAssertEqual(session.deadline, clock.addingTimeInterval(60))
    }

    /// The passage has to be longer than anyone can type in a minute, or a fast typist
    /// runs out of prompt and every character after that scores as wrong.
    func testThePassageCannotBeFinishedInSixtySeconds() {
        // 200 wpm — beyond any sustained human rate — is 1 000 characters a minute.
        XCTAssertGreaterThan(TypingTest.passage.count, 1_400)
    }

    // MARK: - Finishing

    func testFinishingAtTheDeadlineScoresAndSavesTheBaseline() throws {
        var clock = startedAt
        let spy = BaselineSpy()
        let session = makeSession(prompt: flatPrompt(), clock: { clock }, save: spy.save)

        typeAll(String(repeating: "a", count: 250), into: session)
        clock = startedAt.addingTimeInterval(60)

        let baseline = try XCTUnwrap(session.finish(at: clock))

        XCTAssertEqual(spy.saved.count, 1)
        XCTAssertEqual(baseline.measuredAt, clock)
        XCTAssertEqual(baseline.durationSeconds, 60, accuracy: 0.0001)
        XCTAssertEqual(session.score?.wordsPerMinute ?? -1, 50, accuracy: 0.0001)
    }

    /// The score is over **exactly** 60 seconds however late the deadline task actually
    /// wakes: a run scored over 60.4 seconds is a different measurement from the one the
    /// user was told they were taking.
    func testAnOverdueFinishIsStillScoredOverExactlySixtySeconds() throws {
        var clock = startedAt
        let session = makeSession(prompt: flatPrompt(), clock: { clock })

        typeAll(String(repeating: "a", count: 300), into: session)
        clock = startedAt.addingTimeInterval(64.5)

        let baseline = try XCTUnwrap(session.finish(at: clock))
        XCTAssertEqual(baseline.durationSeconds, 60, accuracy: 0.0001)
        XCTAssertEqual(session.score?.wordsPerMinute ?? -1, 60, accuracy: 0.0001)
    }

    /// The baseline handed to `StatsAggregator` is `netWordsPerMinute`, and it has to be
    /// the measured rate. It is stored as a rounded gross rate times accuracy, so it
    /// tracks the exact figure to within the half-word-per-minute that rounding costs.
    func testTheStoredBaselineCarriesTheMeasuredRate() throws {
        var clock = startedAt
        let session = makeSession(prompt: flatPrompt(), clock: { clock })

        // 400 typed, 300 of them correct: 80 wpm gross, 75 % accurate, 60 wpm net.
        typeAll(String(repeating: "a", count: 300) + String(repeating: "z", count: 100), into: session)
        clock = startedAt.addingTimeInterval(60)

        let baseline = try XCTUnwrap(session.finish(at: clock))
        let score = try XCTUnwrap(session.score)

        XCTAssertEqual(baseline.wordsPerMinute, 80)
        XCTAssertEqual(baseline.accuracy, 0.75, accuracy: 0.0001)
        XCTAssertEqual(baseline.netWordsPerMinute, score.wordsPerMinute, accuracy: 0.5)
    }

    // MARK: - Abandoning changes nothing

    /// Half a test is not a slow test. Finishing early scores nothing, saves nothing, and
    /// leaves the run where it was.
    func testFinishingBeforeTheDeadlineScoresNothing() {
        var clock = startedAt
        let spy = BaselineSpy()
        let session = makeSession(prompt: flatPrompt(), clock: { clock }, save: spy.save)

        typeAll(String(repeating: "a", count: 300), into: session)
        clock = startedAt.addingTimeInterval(30)

        XCTAssertNil(session.finish(at: clock))
        XCTAssertTrue(spy.saved.isEmpty)
        XCTAssertEqual(session.phase, .running(startedAt: startedAt))
    }

    func testAbandoningMidWaySavesNothingAndResetsTheRun() {
        var clock = startedAt
        let spy = BaselineSpy()
        let session = makeSession(prompt: flatPrompt(), clock: { clock }, save: spy.save)

        typeAll(String(repeating: "a", count: 300), into: session)
        clock = startedAt.addingTimeInterval(30)
        session.abandon()

        XCTAssertTrue(spy.saved.isEmpty)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.typed, "")
        XCTAssertNil(session.deadline)
    }

    /// An abandoned run must not disturb a baseline that is already good — the whole
    /// point of "abandoning it mid-way changes nothing".
    func testAbandoningLeavesAnExistingBaselineAlone() throws {
        let directory = try makeDirectory()
        let store = TypingBaselineStore(baseURL: directory)
        var clock = startedAt

        let first = makeSession(prompt: flatPrompt(), clock: { clock }, save: store.save)
        typeAll(String(repeating: "a", count: 300), into: first)
        clock = startedAt.addingTimeInterval(60)
        _ = first.finish(at: clock)
        let good = try XCTUnwrap(store.baseline)

        let second = makeSession(prompt: flatPrompt(), clock: { clock }, save: store.save)
        typeAll(String(repeating: "a", count: 1_000), into: second)
        clock = clock.addingTimeInterval(20)
        XCTAssertNil(second.finish(at: clock))
        second.abandon()

        XCTAssertEqual(store.baseline, good)
        XCTAssertEqual(TypingBaselineStore(baseURL: directory).baseline, good)
    }

    /// Typing everything and then deleting it is an empty run, not a baseline of zero.
    func testAFullMinuteWithNothingTypedSavesNothing() {
        var clock = startedAt
        let spy = BaselineSpy()
        let session = makeSession(prompt: flatPrompt(), clock: { clock }, save: spy.save)

        session.type("a")
        session.type("")
        clock = startedAt.addingTimeInterval(60)

        XCTAssertNil(session.finish(at: clock))
        XCTAssertTrue(spy.saved.isEmpty)
        XCTAssertEqual(session.phase, .ready)
    }

    // MARK: - Re-running

    /// Spec §11.2: the test is re-runnable and stored **with its date**. The second run
    /// replaces both the rate and the date, on disk as well as in memory.
    func testARerunReplacesTheBaselineAndItsDate() throws {
        let directory = try makeDirectory()
        let store = TypingBaselineStore(baseURL: directory)

        var clock = startedAt
        let slow = makeSession(prompt: flatPrompt(), clock: { clock }, save: store.save)
        typeAll(String(repeating: "a", count: 150), into: slow)
        let firstDeadline = startedAt.addingTimeInterval(60)
        clock = firstDeadline
        _ = slow.finish(at: clock)

        XCTAssertEqual(store.baseline?.wordsPerMinute, 30)
        XCTAssertEqual(store.baseline?.measuredAt, firstDeadline)

        clock = startedAt.addingTimeInterval(86_400)
        let start = clock
        let fast = makeSession(prompt: flatPrompt(), clock: { clock }, save: store.save)
        typeAll(String(repeating: "a", count: 350), into: fast)
        let secondDeadline = start.addingTimeInterval(60)
        clock = secondDeadline
        _ = fast.finish(at: clock)

        XCTAssertEqual(store.baseline?.wordsPerMinute, 70)
        XCTAssertEqual(store.baseline?.measuredAt, secondDeadline)

        let reopened = TypingBaselineStore(baseURL: directory)
        XCTAssertEqual(reopened.baseline?.wordsPerMinute, 70)
        XCTAssertEqual(reopened.baseline?.measuredAt, secondDeadline)
    }

    // MARK: - Input rules

    /// Pasting the passage would store a four-figure baseline and silently destroy every
    /// time-saved number on the stats page. A jump no hand can produce is refused.
    func testPastingTheWholePassageIsRefused() {
        var clock = startedAt
        let session = makeSession(prompt: TypingTest.passage, clock: { clock })

        session.type(TypingTest.passage)

        XCTAssertEqual(session.typed, "")
        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.didRefuseInput)

        clock = startedAt.addingTimeInterval(1)
        session.type("T")
        XCTAssertEqual(session.typed, "T")
        XCTAssertFalse(session.didRefuseInput)
    }

    /// Deleting is always allowed, however much of it there is: backspace is typing.
    func testDeletingIsNeverRefused() {
        let session = makeSession(prompt: flatPrompt(), clock: { self.startedAt })
        session.type("abc")
        session.type("")
        XCTAssertEqual(session.typed, "")
        XCTAssertFalse(session.didRefuseInput)
    }

    func testTypingAfterTheTestHasFinishedIsIgnored() {
        var clock = startedAt
        let session = makeSession(prompt: flatPrompt(), clock: { clock })
        typeAll(String(repeating: "a", count: 100), into: session)
        clock = startedAt.addingTimeInterval(60)
        _ = session.finish(at: clock)

        typeAll(String(repeating: "a", count: 110), into: session)
        XCTAssertEqual(session.typed.count, 100)
    }

    // MARK: - Progress, for the view's countdown

    func testRemainingSecondsCountsDownAndFloorsAtZero() {
        var clock = startedAt
        let session = makeSession(prompt: flatPrompt(), clock: { clock })

        XCTAssertNil(session.remainingSeconds(at: clock))

        session.type("a")
        XCTAssertEqual(try XCTUnwrap(session.remainingSeconds(at: clock)), 60, accuracy: 0.0001)

        clock = startedAt.addingTimeInterval(45)
        XCTAssertEqual(try XCTUnwrap(session.remainingSeconds(at: clock)), 15, accuracy: 0.0001)

        clock = startedAt.addingTimeInterval(75)
        XCTAssertEqual(try XCTUnwrap(session.remainingSeconds(at: clock)), 0, accuracy: 0.0001)
    }

    // MARK: - What the view paints

    /// The passage is drawn in three runs — right so far, wrong from here, not yet typed.
    /// Splitting it wrongly is the difference between a legible test and a red screen.
    func testTheProgressSplitMarksTheFirstMistake() {
        let split = TypingTestSession.split(typed: "abXd", prompt: "abcdefgh")
        XCTAssertEqual(split.correct, "ab")
        XCTAssertEqual(split.wrong, "cd")
        XCTAssertEqual(split.remaining, "efgh")
    }

    func testTheProgressSplitHasNoWrongRunWhenEverythingMatches() {
        let split = TypingTestSession.split(typed: "abc", prompt: "abcdef")
        XCTAssertEqual(split.correct, "abc")
        XCTAssertEqual(split.wrong, "")
        XCTAssertEqual(split.remaining, "def")
    }

    func testTheProgressSplitSurvivesTypingPastTheEnd() {
        let split = TypingTestSession.split(typed: "abcdef", prompt: "abc")
        XCTAssertEqual(split.correct, "abc")
        XCTAssertEqual(split.wrong, "")
        XCTAssertEqual(split.remaining, "")
    }
}
