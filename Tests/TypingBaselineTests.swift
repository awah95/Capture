import XCTest
@testable import Captur

@MainActor
final class TypingBaselineTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-baseline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func words(_ count: Int) -> String {
        (0..<count).map { "word\($0)" }.joined(separator: " ")
    }

    /// Whole seconds keep the `.secondsSince1970` round trip exact, so a persisted
    /// baseline can be compared for equality rather than approximately.
    private let measuredAt = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Scoring

    func testGrossWordsPerMinuteFromAKnownSample() throws {
        let sample = words(50)
        let baseline = try XCTUnwrap(
            TypingBaseline.measured(typed: sample, prompt: sample, duration: 60, at: measuredAt))

        XCTAssertEqual(baseline.wordsPerMinute, 50)
        XCTAssertEqual(baseline.durationSeconds, 60, accuracy: 0.0001)
        XCTAssertEqual(baseline.measuredAt, measuredAt)
    }

    /// The rate is per minute however long the test actually ran, so a 30-second
    /// sample is not silently reported as half speed.
    func testRateIsPerMinuteRegardlessOfTestLength() throws {
        let sample = words(25)
        let baseline = try XCTUnwrap(
            TypingBaseline.measured(typed: sample, prompt: sample, duration: 30, at: measuredAt))
        XCTAssertEqual(baseline.wordsPerMinute, 50)
    }

    func testAccuracyIsOneForAPerfectCopy() throws {
        let sample = words(20)
        let baseline = try XCTUnwrap(
            TypingBaseline.measured(typed: sample, prompt: sample, duration: 60, at: measuredAt))
        XCTAssertEqual(baseline.accuracy, 1.0, accuracy: 0.0001)
    }

    func testAccuracyFallsWithMistypedWords() throws {
        let baseline = try XCTUnwrap(
            TypingBaseline.measured(
                typed: "one two zzz yyy",
                prompt: "one two three four",
                duration: 60,
                at: measuredAt))
        XCTAssertEqual(baseline.accuracy, 0.5, accuracy: 0.0001)
    }

    /// Nobody finishes the prompt in 60 seconds. Accuracy is measured against the part
    /// of the prompt the typist actually reached — comparing against the whole thing
    /// would report a perfect typist as 20% accurate.
    func testAccuracyComparesAgainstThePromptPrefixReached() throws {
        let prompt = words(200)
        let typed = words(40)
        let baseline = try XCTUnwrap(
            TypingBaseline.measured(typed: typed, prompt: prompt, duration: 60, at: measuredAt))

        XCTAssertEqual(baseline.accuracy, 1.0, accuracy: 0.0001)
        XCTAssertEqual(baseline.wordsPerMinute, 40)
    }

    /// The number handed to the stats aggregator is accuracy-adjusted: typing you have
    /// to go back and fix is not typing at that speed.
    func testNetRateDiscountsInaccuracy() throws {
        let baseline = try XCTUnwrap(
            TypingBaseline.measured(
                typed: "one two zzz yyy",
                prompt: "one two three four",
                duration: 30,
                at: measuredAt))

        XCTAssertEqual(baseline.wordsPerMinute, 8)
        XCTAssertEqual(baseline.netWordsPerMinute, 4, accuracy: 0.0001)
    }

    // MARK: - Refusing to invent a number

    func testZeroDurationProducesNoBaseline() {
        XCTAssertNil(
            TypingBaseline.measured(
                typed: words(10), prompt: words(10), duration: 0, at: measuredAt))
        XCTAssertNil(
            TypingBaseline.measured(
                typed: words(10), prompt: words(10), duration: -60, at: measuredAt))
    }

    func testTypingNothingProducesNoBaseline() {
        XCTAssertNil(
            TypingBaseline.measured(typed: "", prompt: words(10), duration: 60, at: measuredAt))
        XCTAssertNil(
            TypingBaseline.measured(typed: "   \n", prompt: words(10), duration: 60, at: measuredAt))
    }

    // MARK: - Store

    func testNoBaselineUntilTheTestIsRun() throws {
        let store = TypingBaselineStore(baseURL: try makeDirectory())
        XCTAssertNil(store.baseline)
        XCTAssertNil(store.baselineWPM)
    }

    func testRecordingABaselinePersistsAcrossInstances() throws {
        let directory = try makeDirectory()
        let store = TypingBaselineStore(baseURL: directory)
        let sample = words(50)

        let recorded = try XCTUnwrap(
            store.record(typed: sample, prompt: sample, duration: 60, at: measuredAt))
        XCTAssertEqual(store.baseline, recorded)

        let reopened = TypingBaselineStore(baseURL: directory)
        XCTAssertEqual(reopened.baseline, recorded)
        XCTAssertEqual(reopened.baseline?.measuredAt, measuredAt)
        XCTAssertEqual(reopened.baselineWPM, recorded.netWordsPerMinute)
    }

    /// The test is re-runnable and stored with its date, so a second run replaces the
    /// first rather than accumulating.
    func testRerunningReplacesTheBaselineAndItsDate() throws {
        let directory = try makeDirectory()
        let store = TypingBaselineStore(baseURL: directory)
        let slow = words(30)
        let fast = words(70)
        let later = measuredAt.addingTimeInterval(86_400)

        _ = store.record(typed: slow, prompt: slow, duration: 60, at: measuredAt)
        _ = store.record(typed: fast, prompt: fast, duration: 60, at: later)

        XCTAssertEqual(store.baseline?.wordsPerMinute, 70)
        XCTAssertEqual(store.baseline?.measuredAt, later)
        XCTAssertEqual(TypingBaselineStore(baseURL: directory).baseline?.wordsPerMinute, 70)
    }

    func testAFailedMeasurementLeavesTheExistingBaselineAlone() throws {
        let store = TypingBaselineStore(baseURL: try makeDirectory())
        let sample = words(50)
        _ = store.record(typed: sample, prompt: sample, duration: 60, at: measuredAt)

        XCTAssertNil(store.record(typed: "", prompt: sample, duration: 60, at: measuredAt))
        XCTAssertEqual(store.baseline?.wordsPerMinute, 50)
    }

    func testClearRemovesTheBaseline() throws {
        let directory = try makeDirectory()
        let store = TypingBaselineStore(baseURL: directory)
        let sample = words(50)
        _ = store.record(typed: sample, prompt: sample, duration: 60, at: measuredAt)

        store.clear()
        XCTAssertNil(store.baseline)
        XCTAssertNil(TypingBaselineStore(baseURL: directory).baseline)
    }

    /// An unreadable baseline file reads as "no baseline", never as a guessed one, and
    /// the bytes are left on disk for inspection.
    func testCorruptFileReadsAsNoBaselineAndIsNotDeleted() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("typing-baseline.json")
        try Data("{ not json".utf8).write(to: url)

        let store = TypingBaselineStore(baseURL: directory)
        XCTAssertNil(store.baseline)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - The honesty contract, end to end

    /// The whole reason `timeSavedSeconds` is optional: until the typing test is run
    /// there is no baseline, and the stats screen must say so rather than pick a number.
    func testTimeSavedStaysNilUntilTheTypingTestIsRun() throws {
        let directory = try makeDirectory()
        let store = TypingBaselineStore(baseURL: directory)
        let records = [StatsFixture.record(words: 100, speakingDuration: 30, latency: 5)]
        let calendar = StatsFixture.calendar("UTC")

        let before = StatsAggregator.summarize(
            records,
            baselineWPM: store.baselineWPM,
            calendar: calendar,
            now: StatsFixture.epochDate())
        XCTAssertNil(before.timeSavedSeconds)

        let sample = words(40)
        _ = store.record(typed: sample, prompt: sample, duration: 60, at: measuredAt)

        let after = StatsAggregator.summarize(
            records,
            baselineWPM: store.baselineWPM,
            calendar: calendar,
            now: StatsFixture.epochDate())
        // 100 words at 40 wpm is 150 s of typing, minus 30 s spoken and 5 s waited.
        XCTAssertEqual(try XCTUnwrap(after.timeSavedSeconds), 115, accuracy: 0.0001)
    }
}
