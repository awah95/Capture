import XCTest
@testable import Captur

/// The full stats page, spec §10, §11.2 and §11.3.
///
/// Everything asserted here is a refusal: refusing to show a number that was not
/// measured, refusing to name a bucket the model left unnamed, refusing to divide by an
/// empty window. The charts themselves are `BarChartGeometry`'s problem and are covered
/// by `HomeChartsTests`; what is new here is the series that feeds them.
@MainActor
final class StatsViewModelTests: XCTestCase {

    private let calendar = StatsFixture.calendar("UTC")

    /// Midday UTC, so "today" and "the day before" are unambiguous whatever the machine's
    /// zone is.
    private func today() -> Date {
        StatsFixture.date(calendar, 2026, 6, 15, 12, 0)
    }

    private func day(_ offset: Int, hour: Int = 12) -> Date {
        calendar.date(byAdding: .day, value: offset, to: StatsFixture.date(calendar, 2026, 6, 15, hour, 0))!
    }

    private func makeModel(
        records: [DictationRecord] = [],
        loadFailure: Error? = nil,
        baseline: TypingBaseline? = nil,
        resolveMode: @escaping (String) -> ModeBadge? = { _ in nil },
        window: StatsViewModel.Window = .allTime
    ) -> StatsViewModel {
        StatsViewModel(
            loadRecords: {
                if let loadFailure { throw loadFailure }
                return records
            },
            readBaseline: { baseline },
            resolveMode: resolveMode,
            makeTypingTestSession: {
                TypingTestSession(prompt: TypingTest.passage, now: { Date() }, saveBaseline: { _ in })
            },
            window: window,
            calendar: calendar,
            now: { self.today() })
    }

    private func baseline(wpm: Int, accuracy: Double = 1, at date: Date) -> TypingBaseline {
        TypingBaseline(
            wordsPerMinute: wpm, accuracy: accuracy, measuredAt: date, durationSeconds: 60)
    }

    // MARK: - Empty and near-empty

    /// An empty log is a zeroed page, not a crashed one: every rate has an empty
    /// denominator and not one of them may come out NaN.
    func testAnEmptyLogProducesAZeroedPageWithNoDivisionByZero() async {
        let model = makeModel()
        await model.refresh()

        XCTAssertFalse(model.hasRecords)
        XCTAssertNil(model.loadFailure)
        XCTAssertEqual(model.summary, .empty)
        XCTAssertTrue(model.appShares.isEmpty)
        XCTAssertTrue(model.modeShares.isEmpty)
        XCTAssertTrue(model.buckets.isEmpty)

        XCTAssertTrue(model.summary.averageWordsPerMinute.isFinite)
        XCTAssertTrue(model.summary.retryRate.isFinite)
        XCTAssertTrue(model.summary.meanEditDistanceRawToFinal.isFinite)
        XCTAssertTrue(model.summary.meanRecordingSeconds.isFinite)
        XCTAssertTrue(model.summary.meanPipelineLatencySeconds.isFinite)
    }

    func testUsageBreakdownGroupsProviderModelStageTokensAndUnknownCosts() async {
        var first = StatsFixture.record()
        first.usageEntries = [
            DictationUsageEntry(
                stage: .refinement,
                providerID: "openRouter",
                requestedModelID: "google/gemini-3.8-flash",
                actualModelID: "google/gemini-3.8-flash",
                promptTokens: 100,
                completionTokens: 20,
                reasoningTokens: 5,
                cachedTokens: 10,
                costUSD: Decimal(string: "0.001"),
                costKind: .billed,
                generationID: "one")
        ]
        var second = StatsFixture.record()
        second.usageEntries = [
            DictationUsageEntry(
                stage: .refinement,
                providerID: "openRouter",
                requestedModelID: "google/gemini-3.8-flash",
                actualModelID: "google/gemini-3.8-flash",
                promptTokens: 40,
                completionTokens: 8,
                reasoningTokens: 2,
                cachedTokens: nil,
                costUSD: nil,
                costKind: .unknown,
                generationID: nil)
        ]

        let model = makeModel(records: [first, second])
        await model.refresh()

        let row = try? XCTUnwrap(model.usageBreakdown.first)
        XCTAssertEqual(row?.requestCount, 2)
        XCTAssertEqual(row?.promptTokens, 140)
        XCTAssertEqual(row?.completionTokens, 28)
        XCTAssertEqual(row?.reasoningTokens, 7)
        XCTAssertEqual(row?.costUSD, Decimal(string: "0.001"))
        XCTAssertEqual(row?.unknownCostCount, 1)

        let spend = model.qualitySignals.first(where: { $0.label == "AI spend" })
        XCTAssertEqual(spend?.value, "At least $0.001")
        XCTAssertEqual(spend?.detail, "1 request with unknown cost")
    }

    func testUsageBreakdownShowsAdditiveLocalAudioWithoutDoublingWords() async {
        var record = StatsFixture.record(words: 4, speakingDuration: 10)
        record.usageEntries = [
            DictationUsageEntry(
                stage: .transcription,
                providerID: TranscriptionProvider.localUnified.rawValue,
                requestedModelID: "parakeet-live",
                actualModelID: "parakeet-live",
                promptTokens: nil, completionTokens: nil, reasoningTokens: nil,
                cachedTokens: nil, costUSD: .zero, costKind: .noCharge,
                generationID: nil, audioSeconds: 10,
                transcriptionPath: .liveStream, isRetry: false,
                outcome: .succeeded),
            DictationUsageEntry(
                stage: .transcription,
                providerID: TranscriptionProvider.localUnified.rawValue,
                requestedModelID: "parakeet-batch",
                actualModelID: "parakeet-batch",
                promptTokens: nil, completionTokens: nil, reasoningTokens: nil,
                cachedTokens: nil, costUSD: .zero, costKind: .noCharge,
                generationID: nil, audioSeconds: 10, outputWordCount: 4,
                latencyMs: 120, transcriptionPath: .finalBatchRecheck,
                isRetry: false, outcome: .succeeded),
        ]

        let rows = StatsViewModel.usageBreakdown(from: [record])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.audioSeconds }, 20, accuracy: 0.0001)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.outputWordCount }, 4)
        XCTAssertEqual(rows.compactMap(\.latencyP50Ms), [120])
    }

    func testLegacyEmptyUsageArrayStillRetainsUnattributedTranscriptionVolume() {
        var record = StatsFixture.record(words: 7, speakingDuration: 14, costUSD: 0)
        record.usageEntries = []

        let row = StatsViewModel.usageBreakdown(from: [record]).first

        XCTAssertEqual(row?.providerID, "legacy")
        XCTAssertEqual(row?.modelID, "Unattributed")
        XCTAssertEqual(row?.audioSeconds, 14)
        XCTAssertEqual(row?.outputWordCount, 7)
    }

    /// Spec §10.6: *"Stats, fewer than 3 dictations: 'A few more dictations and this gets
    /// interesting.'"* Fewer than three — three is enough.
    func testTheEmptyStateAppearsBelowThreeDictationsAndNotAtThree() async {
        for count in 0...2 {
            let model = makeModel(records: (0..<count).map { _ in StatsFixture.record() })
            await model.refresh()
            XCTAssertTrue(model.showsTooFewDictations, "\(count) dictations should still be too few")
        }

        let model = makeModel(records: (0..<3).map { _ in StatsFixture.record() })
        await model.refresh()
        XCTAssertFalse(model.showsTooFewDictations)
    }

    /// It counts dictations that reached the cursor. Five failures are not five
    /// dictations, and a page of zeros drawn from them would be a page about nothing.
    func testTheEmptyStateCountsSuccessfulDictationsNotRecords() async {
        let records = (0..<5).map { _ in
            StatsFixture.record(outcome: .failed(reason: "no key"))
        }
        let model = makeModel(records: records)
        await model.refresh()

        XCTAssertTrue(model.showsTooFewDictations)
        XCTAssertEqual(model.summary.recordCount, 5)
        XCTAssertEqual(model.summary.dictationCount, 0)
    }

    /// The corpus decides, not the window. A quiet week does not hide a page built from
    /// two years of dictations.
    func testTheEmptyStateLooksAtTheWholeLogNotTheSelectedWindow() async {
        let records = (0..<40).map { index in
            StatsFixture.record(startedAt: day(-90 - index))
        }
        let model = makeModel(records: records, window: .week)
        await model.refresh()

        XCTAssertFalse(model.showsTooFewDictations)
        XCTAssertEqual(model.summary.dictationCount, 0, "nothing in the last 7 days")
    }

    /// A read failure is reported. It is never shown as "no dictations yet": those are
    /// different facts and only one of them is good news.
    func testAReadFailureIsReportedRatherThanShownAsAnEmptyLog() async {
        let model = makeModel(loadFailure: CocoaError(.fileReadNoSuchFile))
        await model.refresh()

        XCTAssertNotNil(model.loadFailure)
        XCTAssertFalse(model.hasRecords)
        XCTAssertFalse(model.showsTooFewDictations, "a failed read is not a small corpus")
    }

    // MARK: - The hero, and the number that is not there

    /// `timeSavedSeconds == nil` is the prompt state. Not "0m", not a dash — there is no
    /// `TimeInterval` to print, and no call site may invent one.
    func testNoTypingBaselineShowsThePromptRatherThanZero() async {
        let model = makeModel(records: (0..<5).map { _ in StatsFixture.record() })
        await model.refresh()

        XCTAssertEqual(model.hero, .needsTypingTest)
        XCTAssertNil(model.heroFigure)
        XCTAssertNil(model.summary.timeSavedSeconds)
        XCTAssertNil(model.baselineSummary)
    }

    func testABaselineTurnsTheHeroIntoAFigure() async {
        let records = [StatsFixture.record(words: 100, speakingDuration: 30, latency: 5)]
        let model = makeModel(
            records: records, baseline: baseline(wpm: 40, at: day(-2)))
        await model.refresh()

        // 100 words at 40 wpm is 150 s of typing, minus 30 s spoken and 5 s waited.
        XCTAssertEqual(try XCTUnwrap(model.summary.timeSavedSeconds), 115, accuracy: 0.0001)
        XCTAssertEqual(model.hero, .saved(seconds: 115))
        XCTAssertEqual(model.heroFigure, "1m")
    }

    /// A baseline of zero is not a baseline: dividing by it would report an infinite
    /// saving, so the page falls back to the prompt.
    func testAZeroBaselineIsTreatedAsNoBaseline() async {
        let model = makeModel(
            records: [StatsFixture.record()], baseline: baseline(wpm: 0, at: day(-2)))
        await model.refresh()

        XCTAssertEqual(model.hero, .needsTypingTest)
        XCTAssertNil(model.summary.timeSavedSeconds)
    }

    /// Spec §11.2 stores the baseline *with its date* so a stale one can be re-run. The
    /// page has to show that date, or the staleness is invisible.
    func testTheBaselineSummaryCarriesTheRateAndTheDate() async throws {
        let measuredAt = day(-30)
        let model = makeModel(
            records: [StatsFixture.record()],
            baseline: baseline(wpm: 62, accuracy: 0.9, at: measuredAt))
        await model.refresh()

        let summary = try XCTUnwrap(model.baselineSummary)
        XCTAssertEqual(summary.wordsPerMinute, 56, "62 gross at 90 % is 56 net")
        XCTAssertEqual(summary.measuredAt, measuredAt)
    }

    // MARK: - Windows

    func testTheWindowFiltersRecords() async {
        let records = [
            StatsFixture.record(startedAt: day(0), words: 10),
            StatsFixture.record(startedAt: day(-3), words: 20),
            StatsFixture.record(startedAt: day(-20), words: 40),
            StatsFixture.record(startedAt: day(-200), words: 80),
        ]

        let allTime = makeModel(records: records, window: .allTime)
        await allTime.refresh()
        XCTAssertEqual(allTime.summary.totalWords, 150)

        let month = makeModel(records: records, window: .month)
        await month.refresh()
        XCTAssertEqual(month.summary.totalWords, 70)

        let week = makeModel(records: records, window: .week)
        await week.refresh()
        XCTAssertEqual(week.summary.totalWords, 30)
    }

    /// The window is half-open at both ends: a dictation at the first instant of the
    /// window is in it, one at the instant after the end is not.
    func testTheWindowIsHalfOpen() throws {
        let interval = try XCTUnwrap(
            StatsViewModel.window(.week, calendar: calendar, now: today()))

        XCTAssertEqual(interval.start, calendar.startOfDay(for: day(-6)))
        XCTAssertEqual(interval.end, calendar.startOfDay(for: day(1)))
        XCTAssertNil(StatsViewModel.window(.allTime, calendar: calendar, now: today()))
    }

    func testSelectingAWindowRecomputesThePage() async {
        let records = [
            StatsFixture.record(startedAt: day(0), words: 10),
            StatsFixture.record(startedAt: day(-20), words: 40),
        ]
        let model = makeModel(records: records, window: .allTime)
        await model.refresh()
        XCTAssertEqual(model.summary.totalWords, 50)

        await model.select(.week)
        XCTAssertEqual(model.window, .week)
        XCTAssertEqual(model.summary.totalWords, 10)
    }

    // MARK: - Volume over time

    /// A day with nothing in it is a fact about that day. `StatsSummary.daily` omits it;
    /// the chart series puts it back, or the reader compares a different set of days from
    /// the one they think they are comparing.
    func testAZeroDayBetweenTwoNonZeroDaysIsDrawn() async {
        let records = [
            StatsFixture.record(startedAt: day(-2), words: 30),
            StatsFixture.record(startedAt: day(0), words: 50),
        ]
        let model = makeModel(records: records, window: .week)
        await model.refresh()

        XCTAssertEqual(model.buckets.count, 7)
        XCTAssertEqual(model.buckets.map(\.wordCount), [0, 0, 0, 0, 30, 0, 50])
    }

    func testASingleDayOfDictationProducesOneNonZeroBucket() async {
        let records = (0..<4).map { _ in StatsFixture.record(startedAt: day(0), words: 25) }
        let model = makeModel(records: records, window: .week)
        await model.refresh()

        XCTAssertEqual(model.buckets.count, 7)
        XCTAssertEqual(model.buckets.last?.wordCount, 100)
        XCTAssertEqual(model.buckets.last?.dictationCount, 4)
        XCTAssertEqual(model.buckets.dropLast().reduce(0) { $0 + $1.wordCount }, 0)
    }

    /// A year of daily bars is 365 marks in 300 points. Past the daily limit the series
    /// buckets by week, and past the weekly limit by month — the same data, at a
    /// resolution the reader can actually see.
    func testALongWindowBucketsByWeekAndThenByMonth() {
        XCTAssertEqual(VolumeSeries.bucket(spanningDays: 7), .day)
        XCTAssertEqual(VolumeSeries.bucket(spanningDays: VolumeSeries.dailyLimitDays), .day)
        XCTAssertEqual(VolumeSeries.bucket(spanningDays: VolumeSeries.dailyLimitDays + 1), .week)
        XCTAssertEqual(VolumeSeries.bucket(spanningDays: VolumeSeries.weeklyLimitDays), .week)
        XCTAssertEqual(VolumeSeries.bucket(spanningDays: VolumeSeries.weeklyLimitDays + 1), .month)
    }

    func testWeeklyBucketsSumTheDaysInsideThem() {
        let interval = DateInterval(
            start: calendar.startOfDay(for: day(-90)),
            end: calendar.startOfDay(for: day(1)))
        let daily = [
            StatsDay(dayStart: calendar.startOfDay(for: day(-1)), dictationCount: 1, wordCount: 10),
            StatsDay(dayStart: calendar.startOfDay(for: day(-2)), dictationCount: 1, wordCount: 20),
            StatsDay(dayStart: calendar.startOfDay(for: day(-60)), dictationCount: 1, wordCount: 5),
        ]

        let buckets = VolumeSeries.buckets(in: interval, calendar: calendar, from: daily)

        XCTAssertEqual(buckets.reduce(0) { $0 + $1.wordCount }, 35)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.dictationCount }, 3)
        XCTAssertGreaterThan(buckets.count, 1)
        XCTAssertTrue(buckets.map(\.start).sorted() == buckets.map(\.start), "ascending")
    }

    /// An interval with nothing in it is no bars, not a bar of zero height that the
    /// reader has to squint at.
    func testAnEmptyIntervalProducesNoBuckets() {
        let instant = calendar.startOfDay(for: today())
        XCTAssertTrue(
            VolumeSeries.buckets(
                in: DateInterval(start: instant, end: instant),
                calendar: calendar,
                from: []).isEmpty)
    }

    // MARK: - Where the words go

    func testAppSharesComeFromTheTaskTwentyOneBreakdown() async {
        let records = [
            StatsFixture.record(words: 80, bundleID: "com.apple.mail", appName: "Mail"),
            StatsFixture.record(words: 20, bundleID: "com.tinyspeck.slack", appName: "Slack"),
        ]
        let model = makeModel(records: records)
        await model.refresh()

        XCTAssertEqual(model.appShares.map(\.label), ["Mail", "Slack"])
        XCTAssertEqual(model.appShares.first?.fraction ?? 0, 0.8, accuracy: 0.0001)
    }

    /// One app with every word is 100 %, and the chart has to survive it rather than
    /// treat the single-group case as a special one.
    func testOneAppAtOneHundredPercent() async {
        let model = makeModel(records: [StatsFixture.record(words: 40)])
        await model.refresh()

        XCTAssertEqual(model.appShares.count, 1)
        XCTAssertEqual(model.appShares[0].fraction, 1, accuracy: 0.0001)
    }

    /// `StatsGroup.key` is optional because the aggregator refuses to name a dictation
    /// with nothing in front of it. The page keeps that refusal — never "Unknown".
    func testADictationWithNoFrontmostAppIsLabelledHonestly() async {
        let model = makeModel(
            records: [StatsFixture.record(words: 10, bundleID: nil, appName: nil)])
        await model.refresh()

        XCTAssertEqual(model.appShares.first?.label, AppBreakdown.noAppLabel)
        XCTAssertNotEqual(model.appShares.first?.label, "Unknown")
    }

    func testModeSharesUseTheResolvedModeName() async {
        let records = [
            StatsFixture.record(words: 60, modeID: "email"),
            StatsFixture.record(words: 40, modeID: "code"),
        ]
        let model = makeModel(records: records, resolveMode: { id in
            id == "email" ? ModeBadge(name: "Email", symbol: "envelope") : nil
        })
        await model.refresh()

        XCTAssertEqual(model.modeShares.map(\.label), ["Email", "code"])
    }

    /// An unresolvable mode falls back to its ID — still an identifier the owner can act
    /// on — and a record with no mode at all is named for what it is.
    func testAnUnresolvableModeFallsBackToItsIDAndAnAbsentOneIsNamedHonestly() {
        XCTAssertEqual(
            StatsViewModel.modeLabel("scratch", resolveMode: { _ in nil }), "scratch")
        XCTAssertEqual(
            StatsViewModel.modeLabel("", resolveMode: { _ in nil }), StatsViewModel.noModeLabel)
        XCTAssertEqual(
            StatsViewModel.modeLabel(nil, resolveMode: { _ in nil }), StatsViewModel.noModeLabel)
        XCTAssertNotEqual(StatsViewModel.noModeLabel, "Unknown")
    }

    // MARK: - Quality signals

    func testQualitySignalsReadTheAggregatorAndAreFormattedAsText() async throws {
        let records = [
            StatsFixture.record(
                words: 100, speakingDuration: 30, latency: 5,
                retryCount: 1, editDistance: 0.25, costUSD: 0.004),
            StatsFixture.record(
                words: 100, speakingDuration: 30, latency: 5,
                retryCount: 0, editDistance: 0.25, costUSD: 0.004),
        ]
        let model = makeModel(records: records)
        await model.refresh()

        let values = Dictionary(
            uniqueKeysWithValues: model.qualitySignals.map { ($0.label, $0.value) })
        XCTAssertEqual(values["Retry rate"], "50%")
        XCTAssertEqual(values["Words the mode changed"], "25%")
        XCTAssertEqual(values["Mean recording"], "30s")
        XCTAssertEqual(values["Mean wait after speaking"], "5s")
        XCTAssertEqual(values["AI spend"], "$0.008")
        XCTAssertEqual(values["Partial failures"], "0")
    }

    /// Zero records in the window is zero of zero. The signals are withheld rather than
    /// printed as a confident 0 %.
    func testQualitySignalsAreWithheldWhenTheWindowHasNoRecords() async {
        let model = makeModel(
            records: [StatsFixture.record(startedAt: day(-200))], window: .week)
        await model.refresh()

        XCTAssertEqual(model.summary.recordCount, 0)
        XCTAssertTrue(model.qualitySignals.isEmpty)
    }

    // MARK: - Speed group

    func testTheSpeedFiguresReadTheAggregator() async throws {
        let records = [
            StatsFixture.record(startedAt: day(0), words: 60, speakingDuration: 30),
            StatsFixture.record(startedAt: day(-1), words: 30, speakingDuration: 30),
        ]
        let model = makeModel(records: records)
        await model.refresh()

        let values = Dictionary(uniqueKeysWithValues: model.speedFigures.map { ($0.label, $0.value) })
        // 120 wpm and 60 wpm, averaged per record as spec §11.2 defines it.
        XCTAssertEqual(values["Speaking"], "90 wpm")
        XCTAssertEqual(values["Words"], "90")
        XCTAssertEqual(values["Dictations"], "2")
        XCTAssertEqual(values["Streak"], "2 days")
    }

    // MARK: - The typing test seam

    func testStartingTheTypingTestBuildsASessionAndEndingItRefreshes() async {
        let model = makeModel(records: [StatsFixture.record()])
        await model.refresh()
        XCTAssertNil(model.typingTest)

        model.startTypingTest()
        XCTAssertNotNil(model.typingTest)
        XCTAssertEqual(model.typingTest?.prompt, TypingTest.passage)

        await model.endTypingTest()
        XCTAssertNil(model.typingTest)
    }
}
