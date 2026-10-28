import XCTest
@testable import Captur

/// Record builders shared by every stats test. Kept here rather than in
/// `Tests/Support/Fakes.swift` because that file belongs to the pipeline tests and
/// its doubles are about concurrency, not arithmetic.
enum StatsFixture {

    /// A gregorian calendar pinned to a named zone. Every streak assertion runs
    /// through one of these: `Calendar.current` would make the suite pass or fail
    /// depending on where the machine is standing.
    static func calendar(_ timeZoneID: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// A local wall-clock instant in `calendar`'s zone.
    static func date(
        _ calendar: Calendar,
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    /// Whole-second epoch dates keep the log's `.secondsSince1970` round trip exact.
    static func epochDate(offsetDays: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_784_000_000 + Double(offsetDays) * 86_400)
    }

    /// One record with every stats-relevant quantity spelled out. Defaults are
    /// deliberately boring: 10 words spoken in 30 s with no pipeline latency, so a
    /// test only has to state the quantity it is actually about.
    static func record(
        id: UUID = UUID(),
        startedAt: Date? = nil,
        words: Int = 10,
        speakingDuration: TimeInterval = 30,
        latency: TimeInterval = 0,
        modeID: String = "email",
        bundleID: String? = "com.apple.mail",
        appName: String? = "Mail",
        retryCount: Int = 0,
        editDistance: Double = 0.2,
        costUSD: Double = 0.001,
        finalText: String? = nil,
        outcome: DictationOutcome = .inserted
    ) -> DictationRecord {
        let captureMs = Int((speakingDuration * 1_000).rounded())
        let latencyMs = Int((latency * 1_000).rounded())
        return DictationRecord(
            id: id,
            startedAt: startedAt ?? epochDate(),
            speakingDuration: speakingDuration,
            rawText: "raw",
            finalText: finalText ?? String(repeating: "word ", count: max(0, words)),
            modeID: modeID,
            targetBundleID: bundleID,
            targetAppName: appName,
            wordCount: words,
            rawWordCount: words,
            segmentCount: 1,
            timings: Timings(
                captureMs: captureMs,
                convertMs: 0,
                uploadMs: 0,
                whisperMs: 0,
                llmMs: 0,
                insertMs: 0,
                // Anchored at capture start, exactly as DictationPipeline writes it:
                // speaking time plus everything the user waited through afterwards.
                totalMs: captureMs + latencyMs
            ),
            insertionOutcome: "insertedDirect",
            retryCount: retryCount,
            editDistanceRawToFinal: editDistance,
            audioFileName: "session.m4a",
            audioBytes: 1_024,
            estimatedCostUSD: costUSD,
            vocabularyTermsSent: 3,
            voiceProcessingActive: true,
            outcome: outcome
        )
    }

    /// Twelve records spread over six local days, mixing modes, apps, retries and one
    /// cancellation — the fixture for order-independence and for the rollup cache's
    /// "incremental must equal a full rebuild" assertions.
    ///
    /// Every fractional value is an exact binary fraction so that summing the set in
    /// different orders is bit-identical: a full-struct equality assertion then
    /// catches real ordering bugs instead of floating-point re-association.
    static func mixedRecords(calendar: Calendar) -> [DictationRecord] {
        (0..<12).map { (index: Int) -> DictationRecord in
            let day: Int = 1 + index % 6
            let hour: Int = 9 + index % 5
            let startedAt: Date = date(calendar, 2026, 3, day, hour)
            let words: Int = 10 + index
            let speakingDuration: TimeInterval = 15 + Double(index)
            let latency: TimeInterval = Double(index)
            let modeID: String = index.isMultiple(of: 2) ? "email" : "code"
            let bundleID: String? = index.isMultiple(of: 3) ? nil : "com.apple.mail"
            let retryCount: Int = index % 4 == 0 ? 1 : 0
            let editDistance: Double = Double(index) / 16
            let costUSD: Double = Double(index) / 1_024
            let outcome: DictationOutcome = index == 5 ? .cancelled : .inserted

            return record(
                startedAt: startedAt,
                words: words,
                speakingDuration: speakingDuration,
                latency: latency,
                modeID: modeID,
                bundleID: bundleID,
                retryCount: retryCount,
                editDistance: editDistance,
                costUSD: costUSD,
                outcome: outcome)
        }
    }
}

final class StatsAggregatorTests: XCTestCase {

    private let utc = StatsFixture.calendar("UTC")

    private func summarize(
        _ records: [DictationRecord],
        baselineWPM: Double? = nil,
        calendar: Calendar? = nil,
        now: Date? = nil
    ) -> StatsSummary {
        StatsAggregator.summarize(
            records,
            baselineWPM: baselineWPM,
            calendar: calendar ?? utc,
            now: now ?? StatsFixture.epochDate()
        )
    }

    // MARK: - Empty input

    func testEmptyInputProducesZeroedSummaryWithoutDividingByZero() {
        let summary = summarize([], baselineWPM: nil)

        XCTAssertEqual(summary, StatsSummary.empty)
        XCTAssertEqual(summary.recordCount, 0)
        XCTAssertEqual(summary.dictationCount, 0)
        XCTAssertEqual(summary.totalWords, 0)
        XCTAssertEqual(summary.totalSpeakingSeconds, 0)
        XCTAssertEqual(summary.averageWordsPerMinute, 0)
        XCTAssertNil(summary.timeSavedSeconds)
        XCTAssertEqual(summary.currentStreakDays, 0)
        XCTAssertEqual(summary.longestStreakDays, 0)
        XCTAssertEqual(summary.retryRate, 0)
        XCTAssertEqual(summary.meanEditDistanceRawToFinal, 0)
        XCTAssertEqual(summary.meanRecordingSeconds, 0)
        XCTAssertEqual(summary.meanPipelineLatencySeconds, 0)
        XCTAssertEqual(summary.totalCostUSD, 0)
        XCTAssertEqual(summary.partialFailureCount, 0)
        XCTAssertTrue(summary.byApp.isEmpty)
        XCTAssertTrue(summary.byMode.isEmpty)
        XCTAssertTrue(summary.daily.isEmpty)

        // Every rate is a real 0, never a NaN that renders as "nan wpm".
        XCTAssertFalse(summary.averageWordsPerMinute.isNaN)
        XCTAssertFalse(summary.retryRate.isNaN)
        XCTAssertFalse(summary.meanEditDistanceRawToFinal.isNaN)
    }

    /// A baseline with nothing dictated saves exactly zero seconds. That is a fact,
    /// not a guess, so it is 0 rather than nil — nil means "no baseline".
    func testEmptyInputWithBaselineSavesZeroNotNil() {
        let summary = summarize([], baselineWPM: 40)
        XCTAssertEqual(summary.timeSavedSeconds, 0)
    }

    // MARK: - WPM

    func testWordsPerMinuteFromAKnownRecord() {
        let record = StatsFixture.record(words: 45, speakingDuration: 60)
        let summary = summarize([record])

        XCTAssertEqual(summary.averageWordsPerMinute, 45, accuracy: 0.0001)
        XCTAssertEqual(summary.totalWords, 45)
        XCTAssertEqual(summary.totalSpeakingSeconds, 60, accuracy: 0.0001)
    }

    /// WPM is over SPEAKING time, not wall clock: the same 45 words with 90 s of
    /// pipeline latency bolted on is still 45 WPM.
    func testWordsPerMinuteIgnoresPipelineLatency() {
        let record = StatsFixture.record(words: 45, speakingDuration: 60, latency: 90)
        XCTAssertEqual(summarize([record]).averageWordsPerMinute, 45, accuracy: 0.0001)
    }

    func testAverageWordsPerMinuteIsTheMeanOfPerRecordValues() {
        let records = [
            StatsFixture.record(words: 30, speakingDuration: 60),   // 30 wpm
            StatsFixture.record(words: 90, speakingDuration: 60)    // 90 wpm
        ]
        XCTAssertEqual(summarize(records).averageWordsPerMinute, 60, accuracy: 0.0001)
    }

    /// A record that never recorded (opened, then crashed) has a zero duration and
    /// must not be averaged in as "0 WPM", nor divided by.
    func testRecordsWithoutSpeakingTimeAreExcludedFromTheAverage() {
        let records = [
            StatsFixture.record(words: 40, speakingDuration: 60),
            StatsFixture.record(words: 0, speakingDuration: 0)
        ]
        let summary = summarize(records)
        XCTAssertEqual(summary.averageWordsPerMinute, 40, accuracy: 0.0001)
        XCTAssertFalse(summary.averageWordsPerMinute.isNaN)
    }

    func testCancelledAndFailedRecordsAreExcludedFromTheAverage() {
        let records = [
            StatsFixture.record(words: 60, speakingDuration: 60),
            StatsFixture.record(words: 600, speakingDuration: 60, outcome: .cancelled),
            StatsFixture.record(
                words: 600, speakingDuration: 60, outcome: .failed(reason: "network"))
        ]
        XCTAssertEqual(summarize(records).averageWordsPerMinute, 60, accuracy: 0.0001)
    }

    // MARK: - Time saved

    func testTimeSavedIsNilWithoutABaseline() {
        let records = [StatsFixture.record(words: 100, speakingDuration: 60)]
        XCTAssertNil(summarize(records, baselineWPM: nil).timeSavedSeconds)
    }

    /// A nonsense baseline is treated as no baseline. Anything else divides by zero
    /// and reports an infinite saving.
    func testTimeSavedIsNilForANonPositiveBaseline() {
        let records = [StatsFixture.record(words: 100, speakingDuration: 60)]
        XCTAssertNil(summarize(records, baselineWPM: 0).timeSavedSeconds)
        XCTAssertNil(summarize(records, baselineWPM: -40).timeSavedSeconds)
    }

    /// 40 words at a 40 WPM baseline is 60 s of typing. Speaking took 20 s and the
    /// user then waited 10 s for the pipeline, so the honest saving is 30 s.
    func testTimeSavedSubtractsSpeakingTimeAndPipelineLatency() {
        let record = StatsFixture.record(words: 40, speakingDuration: 20, latency: 10)
        let summary = summarize([record], baselineWPM: 40)

        XCTAssertNotNil(summary.timeSavedSeconds)
        XCTAssertEqual(summary.timeSavedSeconds!, 30, accuracy: 0.0001)
        XCTAssertEqual(summary.meanPipelineLatencySeconds, 10, accuracy: 0.0001)
    }

    /// The latency subtraction is `totalMs - captureMs`, so a slower pipeline on the
    /// same dictation must eat into the saving one second per second.
    func testMorePipelineLatencyReducesTimeSaved() {
        let fast = StatsFixture.record(words: 40, speakingDuration: 20, latency: 5)
        let slow = StatsFixture.record(words: 40, speakingDuration: 20, latency: 25)

        let fastSaved = summarize([fast], baselineWPM: 40).timeSavedSeconds!
        let slowSaved = summarize([slow], baselineWPM: 40).timeSavedSeconds!
        XCTAssertEqual(fastSaved - slowSaved, 20, accuracy: 0.0001)
    }

    /// Speaking time is subtracted exactly once. Using `totalMs` as if it were pure
    /// latency would double-count it and halve the saving.
    func testSpeakingTimeIsNotDoubleCounted() {
        let record = StatsFixture.record(words: 40, speakingDuration: 20, latency: 0)
        XCTAssertEqual(summarize([record], baselineWPM: 40).timeSavedSeconds!, 40, accuracy: 0.0001)
    }

    /// Dictation that was slower than typing shows a negative saving. Clamping it at
    /// zero would quietly flatter the number the whole feature exists to keep honest.
    func testTimeSavedCanBeNegative() {
        let record = StatsFixture.record(words: 10, speakingDuration: 60, latency: 30)
        let saved = summarize([record], baselineWPM: 100).timeSavedSeconds!
        XCTAssertEqual(saved, 6 - 60 - 30, accuracy: 0.0001)
        XCTAssertLessThan(saved, 0)
    }

    func testTimeSavedExcludesCancelledAndFailedRecords() {
        let records = [
            StatsFixture.record(words: 40, speakingDuration: 20, latency: 10),
            StatsFixture.record(
                words: 400, speakingDuration: 20, latency: 10, outcome: .cancelled),
            StatsFixture.record(
                words: 400, speakingDuration: 20, latency: 10,
                outcome: .failed(reason: "groq 500"))
        ]
        XCTAssertEqual(summarize(records, baselineWPM: 40).timeSavedSeconds!, 30, accuracy: 0.0001)
    }

    func testTimeSavedSumsAcrossRecords() {
        let records = [
            StatsFixture.record(words: 40, speakingDuration: 20, latency: 10),
            StatsFixture.record(words: 80, speakingDuration: 40, latency: 20)
        ]
        // 60 s − 30 s + 120 s − 60 s
        XCTAssertEqual(summarize(records, baselineWPM: 40).timeSavedSeconds!, 90, accuracy: 0.0001)
    }

    // MARK: - Streaks

    func testStreakCountsConsecutiveLocalDaysAndIncludesToday() {
        let calendar = StatsFixture.calendar("UTC")
        let records = [
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 10, 9)),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 11, 23)),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 12, 7))
        ]
        let summary = summarize(
            records,
            calendar: calendar,
            now: StatsFixture.date(calendar, 2026, 3, 12, 20))

        XCTAssertEqual(summary.currentStreakDays, 3)
        XCTAssertEqual(summary.longestStreakDays, 3)
    }

    func testSeveralDictationsInOneDayCountAsOneStreakDay() {
        let calendar = StatsFixture.calendar("UTC")
        let records = (0..<5).map {
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 12, 8 + $0))
        }
        let summary = summarize(
            records,
            calendar: calendar,
            now: StatsFixture.date(calendar, 2026, 3, 12, 20))

        XCTAssertEqual(summary.currentStreakDays, 1)
        XCTAssertEqual(summary.daily.count, 1)
        XCTAssertEqual(summary.daily.first?.dictationCount, 5)
    }

    func testStreakBreaksOnAGap() {
        let calendar = StatsFixture.calendar("UTC")
        let records = [
            // A 3-day run that ended, then a gap, then today.
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 1)),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 2)),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 3)),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 12))
        ]
        let summary = summarize(
            records,
            calendar: calendar,
            now: StatsFixture.date(calendar, 2026, 3, 12, 20))

        XCTAssertEqual(summary.currentStreakDays, 1)
        XCTAssertEqual(summary.longestStreakDays, 3)
    }

    /// Nothing today and nothing yesterday is a broken streak, however long the run
    /// before it was.
    func testStreakIsZeroWhenTheLastDictationIsOlderThanYesterday() {
        let calendar = StatsFixture.calendar("UTC")
        let records = [
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 9)),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 10))
        ]
        let summary = summarize(
            records,
            calendar: calendar,
            now: StatsFixture.date(calendar, 2026, 3, 12, 20))

        XCTAssertEqual(summary.currentStreakDays, 0)
        XCTAssertEqual(summary.longestStreakDays, 2)
    }

    /// Today is still in progress, so a run through yesterday is alive, not broken —
    /// otherwise the streak would read 0 every morning until the first dictation.
    func testStreakThroughYesterdaySurvivesADayStillInProgress() {
        let calendar = StatsFixture.calendar("UTC")
        let records = [
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 10)),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 11))
        ]
        let summary = summarize(
            records,
            calendar: calendar,
            now: StatsFixture.date(calendar, 2026, 3, 12, 9))

        XCTAssertEqual(summary.currentStreakDays, 2)
    }

    func testFailedAndCancelledDictationsDoNotSustainAStreak() {
        let calendar = StatsFixture.calendar("UTC")
        let records = [
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 11)),
            StatsFixture.record(
                startedAt: StatsFixture.date(calendar, 2026, 3, 12), outcome: .cancelled),
            StatsFixture.record(
                startedAt: StatsFixture.date(calendar, 2026, 3, 12),
                outcome: .failed(reason: "no key"))
        ]
        let summary = summarize(
            records,
            calendar: calendar,
            now: StatsFixture.date(calendar, 2026, 3, 12, 20))

        // Yesterday's success carries the streak; today has nothing that counts.
        XCTAssertEqual(summary.currentStreakDays, 1)
        XCTAssertEqual(summary.longestStreakDays, 1)
    }

    /// Spring forward: 2026-03-08 in America/New_York is a 23-hour day. Day math done
    /// by dividing seconds by 86 400 loses a day here and breaks the streak.
    func testStreakCountsLocalDaysAcrossASpringForwardBoundary() {
        let calendar = StatsFixture.calendar("America/New_York")
        let records = [
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 7, 23, 30)),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 8, 23, 30)),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 9, 0, 30))
        ]
        let summary = summarize(
            records,
            calendar: calendar,
            now: StatsFixture.date(calendar, 2026, 3, 9, 10))

        XCTAssertEqual(summary.currentStreakDays, 3)
        XCTAssertEqual(summary.longestStreakDays, 3)
        XCTAssertEqual(summary.daily.count, 3)
    }

    /// Fall back: 2026-11-01 in America/New_York is a 25-hour day.
    func testStreakCountsLocalDaysAcrossAFallBackBoundary() {
        let calendar = StatsFixture.calendar("America/New_York")
        let records = [
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 10, 31, 22)),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 11, 1, 1, 30)),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 11, 2, 8))
        ]
        let summary = summarize(
            records,
            calendar: calendar,
            now: StatsFixture.date(calendar, 2026, 11, 2, 20))

        XCTAssertEqual(summary.currentStreakDays, 3)
        XCTAssertEqual(summary.daily.count, 3)
    }

    /// Tokyo is UTC+9, so these three records fall on local days 2, 2 and 4 March but
    /// on UTC days 1, 2 and 3 March. Bucketing in UTC would report a 3-day streak
    /// that never happened.
    func testDaysAreBucketedInTheSuppliedTimeZoneNotUTC() {
        let tokyo = StatsFixture.calendar("Asia/Tokyo")
        let records = [
            StatsFixture.record(startedAt: Date(timeIntervalSince1970: 1_772_395_200)),  // Mar 2 05:00 JST
            StatsFixture.record(startedAt: Date(timeIntervalSince1970: 1_772_416_800)),  // Mar 2 11:00 JST
            StatsFixture.record(startedAt: Date(timeIntervalSince1970: 1_772_568_000))   // Mar 4 05:00 JST
        ]
        let summary = summarize(
            records,
            calendar: tokyo,
            now: Date(timeIntervalSince1970: 1_772_571_600))                             // Mar 4 06:00 JST

        XCTAssertEqual(summary.daily.count, 2)
        XCTAssertEqual(summary.currentStreakDays, 1)
        XCTAssertEqual(summary.longestStreakDays, 1)

        // The same instants seen from UTC really do land on three consecutive days —
        // which is exactly the wrong answer, and proves the zone is doing the work.
        let fromUTC = summarize(
            records,
            calendar: StatsFixture.calendar("UTC"),
            now: Date(timeIntervalSince1970: 1_772_571_600))
        XCTAssertEqual(fromUTC.daily.count, 3)
        XCTAssertEqual(fromUTC.longestStreakDays, 3)
    }

    // MARK: - Word totals and outcomes

    func testFailedAndCancelledRecordsAreExcludedFromWordTotals() {
        let records = [
            StatsFixture.record(words: 10),
            StatsFixture.record(words: 10, outcome: .cancelled),
            StatsFixture.record(words: 10, outcome: .failed(reason: "network"))
        ]
        let summary = summarize(records)

        XCTAssertEqual(summary.totalWords, 10)
        XCTAssertEqual(summary.dictationCount, 1)
        XCTAssertEqual(summary.recordCount, 3, "every record is still in the window")
    }

    func testSpeakingSecondsOnlyCountSuccessfulDictations() {
        let records = [
            StatsFixture.record(speakingDuration: 30),
            StatsFixture.record(speakingDuration: 90, outcome: .cancelled)
        ]
        XCTAssertEqual(summarize(records).totalSpeakingSeconds, 30, accuracy: 0.0001)
    }

    // MARK: - Quality signals

    /// Retry rate is over EVERY record: a dictation that was retried and then failed
    /// is the most important kind of retry there is.
    func testRetryRateIncludesFailedAndCancelledRecords() {
        let records = [
            StatsFixture.record(retryCount: 0),
            StatsFixture.record(retryCount: 0),
            StatsFixture.record(retryCount: 2, outcome: .cancelled),
            StatsFixture.record(retryCount: 1, outcome: .failed(reason: "timeout"))
        ]
        XCTAssertEqual(summarize(records).retryRate, 0.5, accuracy: 0.0001)
    }

    func testRetryRateIsZeroWhenNothingWasRetried() {
        let records = [StatsFixture.record(retryCount: 0), StatsFixture.record(retryCount: 0)]
        XCTAssertEqual(summarize(records).retryRate, 0, accuracy: 0.0001)
    }

    /// Edit distance is only meaningful where there was a transcript to reshape. A
    /// failed record's empty text would otherwise pull the mean toward zero and make
    /// the mode look more faithful than it is.
    func testMeanEditDistanceCoversSuccessfulRecordsOnly() {
        let records = [
            StatsFixture.record(editDistance: 0.4),
            StatsFixture.record(editDistance: 0.2),
            StatsFixture.record(editDistance: 0, outcome: .failed(reason: "network"))
        ]
        XCTAssertEqual(summarize(records).meanEditDistanceRawToFinal, 0.3, accuracy: 0.0001)
    }

    /// Recording length is a fact about the microphone, so an abandoned recording
    /// counts. A record that never recorded at all does not.
    func testMeanRecordingLengthIncludesCancelledRecordings() {
        let records = [
            StatsFixture.record(speakingDuration: 20),
            StatsFixture.record(speakingDuration: 40, outcome: .cancelled),
            StatsFixture.record(speakingDuration: 0, outcome: .failed(reason: "no mic"))
        ]
        XCTAssertEqual(summarize(records).meanRecordingSeconds, 30, accuracy: 0.0001)
    }

    /// Groq bills for a failed insertion just the same, so cost is cumulative over
    /// every record.
    func testCostIsCumulativeAcrossEveryOutcome() {
        let records = [
            StatsFixture.record(costUSD: 0.002),
            StatsFixture.record(costUSD: 0.003, outcome: .cancelled),
            StatsFixture.record(costUSD: 0.005, outcome: .failed(reason: "timeout"))
        ]
        XCTAssertEqual(summarize(records).totalCostUSD, 0.010, accuracy: 0.000001)
    }

    /// A partially failed dictation is written as `.inserted` with a failure marker in
    /// the text, so the marker is the only signal there is. It counts as a dictation
    /// (the text did reach the cursor) and is surfaced separately.
    func testPartialFailureMarkerIsCountedWithoutHidingTheWords() {
        let partial = StatsFixture.record(
            words: 8,
            finalText: "first half \(TranscriptStitcher.failureMarker) second half")
        let clean = StatsFixture.record(words: 8, finalText: "all of it made it")
        let summary = summarize([partial, clean])

        XCTAssertEqual(summary.partialFailureCount, 1)
        XCTAssertEqual(summary.dictationCount, 2)
        XCTAssertEqual(summary.totalWords, 16)
    }

    // MARK: - Grouping

    func testGroupsWordsAndCountsByAppAndMode() {
        let records = [
            StatsFixture.record(
                words: 100, modeID: "email", bundleID: "com.apple.mail", appName: "Mail"),
            StatsFixture.record(
                words: 50, modeID: "code", bundleID: "com.apple.mail", appName: "Mail"),
            StatsFixture.record(
                words: 70, modeID: "code", bundleID: "com.tinyspeck.slack", appName: "Slack")
        ]
        let summary = summarize(records)

        // Sorted by words descending, so the UI's hero row needs no sort of its own.
        XCTAssertEqual(summary.byApp.map(\.key), ["com.apple.mail", "com.tinyspeck.slack"])
        XCTAssertEqual(summary.byApp.map(\.wordCount), [150, 70])
        XCTAssertEqual(summary.byApp.map(\.dictationCount), [2, 1])
        XCTAssertEqual(summary.byApp.first?.displayName, "Mail")

        XCTAssertEqual(summary.byMode.map(\.key), ["code", "email"])
        XCTAssertEqual(summary.byMode.map(\.wordCount), [120, 100])
    }

    /// A dictation with no frontmost app is its own bucket with a nil key: the model
    /// does not invent a name for it, the UI decides how to label it.
    func testRecordsWithoutATargetAppGroupUnderANilKey() {
        let records = [
            StatsFixture.record(words: 10, bundleID: nil, appName: nil),
            StatsFixture.record(words: 20, bundleID: "com.apple.mail", appName: "Mail")
        ]
        let summary = summarize(records)

        XCTAssertEqual(summary.byApp.count, 2)
        let unknown = summary.byApp.first { $0.key == nil }
        XCTAssertNotNil(unknown)
        XCTAssertEqual(unknown?.wordCount, 10)
        XCTAssertNil(unknown?.displayName)
    }

    func testGroupsExcludeFailedAndCancelledRecords() {
        let records = [
            StatsFixture.record(words: 10, bundleID: "com.apple.mail"),
            StatsFixture.record(words: 999, bundleID: "com.apple.mail", outcome: .cancelled)
        ]
        let summary = summarize(records)

        XCTAssertEqual(summary.byApp.count, 1)
        XCTAssertEqual(summary.byApp.first?.wordCount, 10)
        XCTAssertEqual(summary.byApp.first?.dictationCount, 1)
    }

    // MARK: - Daily series

    func testDailySeriesIsAscendingAndCountsOnlySuccessfulDictations() {
        let calendar = StatsFixture.calendar("UTC")
        let records = [
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 12), words: 30),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 10), words: 10),
            StatsFixture.record(startedAt: StatsFixture.date(calendar, 2026, 3, 10), words: 20),
            StatsFixture.record(
                startedAt: StatsFixture.date(calendar, 2026, 3, 11), words: 99,
                outcome: .cancelled)
        ]
        let summary = summarize(
            records,
            calendar: calendar,
            now: StatsFixture.date(calendar, 2026, 3, 12, 20))

        XCTAssertEqual(summary.daily.count, 2)
        XCTAssertEqual(summary.daily.map(\.wordCount), [30, 30])
        XCTAssertEqual(summary.daily.map(\.dictationCount), [2, 1])
        XCTAssertEqual(
            summary.daily.map(\.dayStart),
            [StatsFixture.date(calendar, 2026, 3, 10, 0),
             StatsFixture.date(calendar, 2026, 3, 12, 0)])
    }

    // MARK: - Order independence

    /// The rollup cache folds records in arrival order and the log returns them in
    /// file order; neither may change a single number.
    ///
    /// Every fractional fixture value is an exact binary fraction (`/16`, `/1024`) so
    /// that a genuine ordering bug fails this test rather than floating-point
    /// re-association.
    func testSummaryDoesNotDependOnRecordOrder() {
        let records = StatsFixture.mixedRecords(calendar: StatsFixture.calendar("Europe/Berlin"))
        let calendar = StatsFixture.calendar("Europe/Berlin")
        let now = StatsFixture.date(calendar, 2026, 3, 7, 12)

        let forward = StatsAggregator.summarize(
            records, baselineWPM: 55, calendar: calendar, now: now)
        let reversed = StatsAggregator.summarize(
            Array(records.reversed()), baselineWPM: 55, calendar: calendar, now: now)

        XCTAssertEqual(forward, reversed)
    }
}
