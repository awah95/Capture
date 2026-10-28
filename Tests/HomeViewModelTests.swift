import AppKit
import XCTest
@testable import Captur

/// Home's view model, spec §10.1, and the main window's build/release lifecycle.
///
/// Record fixtures come from `StatsFixture` (`StatsAggregatorTests.swift`) rather than a
/// second copy of the same builder: it already spells out every stats-relevant quantity,
/// and two record builders drifting apart is how a stats test starts asserting about a
/// record shape the aggregator never sees. The doubles below are local on purpose —
/// `Tests/Support/Fakes.swift` belongs to the pipeline tests.
@MainActor
final class HomeViewModelTests: XCTestCase {

    private let utc = StatsFixture.calendar("UTC")

    /// Mid-month so a "this month" window has room on both sides of it.
    private func march(_ day: Int, _ hour: Int = 12) -> Date {
        StatsFixture.date(utc, 2026, 3, day, hour)
    }

    private func model(
        records: [DictationRecord] = [],
        loadError: Error? = nil,
        baselineWPM: Double? = nil,
        resolveMode: @escaping (String) -> ModeBadge? = { _ in nil },
        actions: HomeActions = HomeActions(startTypingTest: {}),
        now: Date? = nil
    ) -> HomeViewModel {
        HomeViewModel(
            loadRecords: {
                if let loadError { throw loadError }
                return records
            },
            baselineWPM: { baselineWPM },
            resolveMode: resolveMode,
            actions: actions,
            calendar: utc,
            now: { now ?? self.march(20) })
    }

    // MARK: - Recent list: the cap and the order

    /// 25 records, inserted deliberately out of order. The assertion is on the
    /// *identities* of the 20 that survive, not on the count: an off-by-one at the cap
    /// and a sort that keeps the wrong end of the list both give 20 rows.
    func testRecentIsCappedAtTwentyNewestFirst() async {
        // Day 1…25 of March, appended to the log in a shuffled-but-fixed order.
        let byDay = (1...25).map { day in
            StatsFixture.record(startedAt: march(day), words: day)
        }
        let logOrder = [12, 0, 24, 7, 3, 19, 1, 22, 15, 8, 2, 20, 5, 13, 23, 4,
                        17, 9, 6, 21, 10, 16, 11, 18, 14].map { byDay[$0] }

        let model = model(records: logOrder, now: march(26))
        await model.refresh()

        XCTAssertEqual(model.recent.count, HomeViewModel.recentLimit)
        // Days 25 down to 6: the six oldest are the ones dropped.
        XCTAssertEqual(model.recent.map(\.id), (6...25).reversed().map { byDay[$0 - 1].id })
        XCTAssertEqual(model.recent.first?.startedAt, march(25))
        XCTAssertEqual(model.recent.last?.startedAt, march(6))
    }

    /// `Array.sorted` is not documented as stable, so equal timestamps need a total
    /// order of their own. The log is append-only, so the later line is the newer
    /// dictation.
    func testRecentTieBreaksSoTheLastAppendedRecordLeads() async {
        let same = march(10)
        let first = StatsFixture.record(startedAt: same, words: 1)
        let second = StatsFixture.record(startedAt: same, words: 2)
        let third = StatsFixture.record(startedAt: same, words: 3)

        let model = model(records: [first, second, third])
        await model.refresh()

        XCTAssertEqual(model.recent.map(\.id), [third.id, second.id, first.id])
    }

    // MARK: - Nothing spoken is lost (spec §4.1)

    func testCancelledRecordsAppearAndAreMarked() async {
        let cancelled = StatsFixture.record(
            startedAt: march(11), outcome: .cancelled)
        let inserted = StatsFixture.record(startedAt: march(10))

        let model = model(records: [inserted, cancelled])
        await model.refresh()

        XCTAssertEqual(model.recent.count, 2)
        let row = try? XCTUnwrap(model.recent.first)
        XCTAssertEqual(row?.id, cancelled.id)
        XCTAssertEqual(row?.status, .cancelled)
        XCTAssertEqual(row?.badge, RecentDictation.cancelledBadge)
        // …and the successful one carries no badge, or the marking says nothing.
        XCTAssertNil(model.recent.last?.badge)
    }

    func testFailedRecordsAppearWithTheirReasonAsTheBadge() async {
        let failed = StatsFixture.record(
            startedAt: march(11), outcome: .failed(reason: "No speech was heard"))

        let model = model(records: [failed])
        await model.refresh()

        XCTAssertEqual(model.recent.first?.status, .failed(reason: "No speech was heard"))
        XCTAssertEqual(model.recent.first?.badge, "No speech was heard")
    }

    /// A record the stitcher had to paper over is `.inserted`, so the marker in its text
    /// is the only signal it lost a segment.
    func testAPartiallyLostDictationIsMarkedEvenThoughItSucceeded() async {
        let partial = StatsFixture.record(
            startedAt: march(11),
            finalText: "the first half \(TranscriptStitcher.failureMarker) and the rest")

        let model = model(records: [partial])
        await model.refresh()

        XCTAssertEqual(model.recent.first?.status, .inserted)
        XCTAssertTrue(model.recent.first?.isPartial == true)
        XCTAssertEqual(model.recent.first?.badge, RecentDictation.partialBadge)
    }

    /// A cancelled dictation usually has no final text. Showing the raw transcript
    /// instead — and saying that is what it is — is the difference between keeping the
    /// §4.1 promise and a row that reads as an empty one.
    func testACancelledRowFallsBackToRawTextAndSaysSo() async {
        let cancelled = StatsFixture.record(
            startedAt: march(11), finalText: "", outcome: .cancelled)

        let model = model(records: [cancelled])
        await model.refresh()

        XCTAssertEqual(model.recent.first?.preview, "raw")
        XCTAssertEqual(model.recent.first?.previewSource, .raw)
    }

    func testAPreviewIsTheFirstLineOnly() async {
        let record = StatsFixture.record(
            startedAt: march(11), finalText: "  first line \n second line\nthird")

        let model = model(records: [record])
        await model.refresh()

        XCTAssertEqual(model.recent.first?.preview, "first line")
        XCTAssertEqual(model.recent.first?.previewSource, .final)
    }

    // MARK: - The hero must never invent a number

    /// The single most important honesty rule in the stats surface: with no typing
    /// baseline the hero exposes the prompt state, not a figure.
    func testTheHeroExposesThePromptStateWithNoTypingBaseline() async {
        let model = model(
            records: [StatsFixture.record(startedAt: march(10), words: 500)],
            baselineWPM: nil)
        await model.refresh()

        XCTAssertEqual(model.hero, .needsTypingTest)
        XCTAssertNil(model.heroFigure,
                     "With no baseline there is no figure — not zero, not a placeholder.")
        XCTAssertNil(model.monthSummary.timeSavedSeconds)
    }

    /// A baseline of zero (or a negative one) is not a baseline. It must reach the same
    /// prompt state rather than dividing by it.
    func testANonPositiveBaselineIsTreatedAsNoBaseline() async {
        let model = model(
            records: [StatsFixture.record(startedAt: march(10), words: 500)],
            baselineWPM: 0)
        await model.refresh()

        XCTAssertEqual(model.hero, .needsTypingTest)
        XCTAssertNil(model.heroFigure)
    }

    func testTheHeroShowsTimeSavedOnceThereIsABaseline() async {
        // 120 words at a 40 wpm baseline is 180 s of typing; the dictation spent 30 s
        // speaking and nothing waiting, so 150 s were saved.
        let model = model(
            records: [StatsFixture.record(
                startedAt: march(10), words: 120, speakingDuration: 30, latency: 0)],
            baselineWPM: 40)
        await model.refresh()

        XCTAssertEqual(model.hero, .saved(seconds: 150))
        XCTAssertEqual(model.heroFigure, "2m")
    }

    /// A dictation slower than typing did not save time, and the hero says so. Clamping
    /// at zero would flatter the one number this feature exists to keep honest.
    func testTheHeroDoesNotClampANegativeSaving() async {
        let model = model(
            records: [StatsFixture.record(
                startedAt: march(10), words: 10, speakingDuration: 120, latency: 60)],
            baselineWPM: 40)
        await model.refresh()

        guard case .saved(let seconds) = model.hero else {
            return XCTFail("Expected a figure, got \(model.hero)")
        }
        XCTAssertLessThan(seconds, 0)
        XCTAssertEqual(model.heroFigure?.first, "−")
    }

    /// Spec §10.1: the hero is time saved **this month**. A record from February must
    /// not be in it.
    func testTheHeroCountsOnlyTheCurrentMonth() async {
        let lastMonth = StatsFixture.record(
            startedAt: StatsFixture.date(utc, 2026, 2, 20), words: 1_000)
        let thisMonth = StatsFixture.record(
            startedAt: march(10), words: 120, speakingDuration: 30, latency: 0)

        let model = model(records: [lastMonth, thisMonth], baselineWPM: 40)
        await model.refresh()

        XCTAssertEqual(model.monthSummary.totalWords, 120)
        XCTAssertEqual(model.hero, .saved(seconds: 150))
        // The recent list is NOT windowed — the left pane is "recent", not "this month".
        XCTAssertEqual(model.recent.count, 2)
    }

    /// The window is half-open. `DateInterval.contains` includes its end, so a record
    /// stamped exactly midnight on the 1st would be counted in both months.
    func testAMidnightRecordOnTheFirstBelongsToOneMonthOnly() async {
        let boundary = StatsFixture.date(utc, 2026, 4, 1, 0)
        let model = model(
            records: [StatsFixture.record(startedAt: boundary, words: 77)],
            now: march(31, 23))
        await model.refresh()

        XCTAssertEqual(model.monthSummary.totalWords, 0,
                       "Midnight on 1 April is April, not the end of March.")
    }

    func testTheMonthWindowCoversExactlyTheCalendarMonth() {
        let window = HomeViewModel.monthWindow(of: march(20), calendar: utc)

        XCTAssertEqual(window.start, StatsFixture.date(utc, 2026, 3, 1, 0))
        XCTAssertEqual(window.end, StatsFixture.date(utc, 2026, 4, 1, 0))
    }

    func testMonthToDateEndsAtTheNextLocalMidnight() {
        let window = HomeViewModel.monthToDateWindow(of: march(20, 12), calendar: utc)

        XCTAssertEqual(window.start, StatsFixture.date(utc, 2026, 3, 1, 0))
        XCTAssertEqual(window.end, StatsFixture.date(utc, 2026, 3, 21, 0))
    }

    func testPreviousMonthComparisonUsesTheImmediatelyPrecedingCalendarMonth() async {
        let records = [
            StatsFixture.record(startedAt: StatsFixture.date(utc, 2026, 2, 10), words: 50),
            StatsFixture.record(startedAt: march(10), words: 75),
            StatsFixture.record(startedAt: StatsFixture.date(utc, 2026, 1, 10), words: 9_999)
        ]
        let model = model(records: records)

        await model.refresh()

        XCTAssertEqual(model.wordsComparison.current, 75)
        XCTAssertEqual(model.wordsComparison.previous, 50)
        XCTAssertEqual(model.wordsComparison.percentChange, 0.5)
        XCTAssertEqual(model.previousMonthSummary.dictationCount, 1)
    }

    func testAZeroPreviousPeriodDoesNotInventAPercentageChange() async {
        let model = model(records: [StatsFixture.record(startedAt: march(10), words: 75)])

        await model.refresh()

        XCTAssertNil(model.wordsComparison.percentChange)
        XCTAssertEqual(model.wordsComparison.accessibilityDescription,
                       "No comparable previous-period value")
    }

    func testSubPercentComparisonDoesNotRoundIntoZeroPercentMore() {
        let comparison = PeriodComparison(current: 1_001, previous: 1_000)

        XCTAssertEqual(comparison.accessibilityDescription,
                       "Less than 1 percent more than the same days last month")
    }

    func testPreviousComparisonUsesTheSameElapsedLocalDays() {
        let window = HomeViewModel.previousMonthWindow(of: march(20), calendar: utc)

        XCTAssertEqual(window.start, StatsFixture.date(utc, 2026, 2, 1, 0))
        XCTAssertEqual(window.end, StatsFixture.date(utc, 2026, 2, 21, 0))
    }

    func testActivityAndInsightsOnlyUseSuccessfulRecordEvidence() async {
        let successful = StatsFixture.record(
            startedAt: march(10), words: 120, bundleID: "com.example.editor", appName: "Editor")
        let failed = StatsFixture.record(
            startedAt: march(11), words: 900,
            bundleID: "com.example.fake", appName: "Fake",
            outcome: .failed(reason: "offline"))
        let model = model(records: [successful, failed])

        await model.refresh()

        XCTAssertEqual(model.activityDays.count, ActivityCalendar.dayCount)
        XCTAssertEqual(model.activityDays.reduce(0) { $0 + $1.wordCount }, 120)
        XCTAssertTrue(model.insights.contains { $0.id == "busiest" && $0.detail.contains("120 words") })
        XCTAssertTrue(model.insights.contains { $0.id == "destination" && $0.title == "Editor" })
        XCTAssertFalse(model.insights.contains { $0.title == "Fake" })
    }

    func testPaceInsightReportsOnlyRecordsEligibleForWPM() async {
        let timed = StatsFixture.record(
            startedAt: march(10), words: 60, speakingDuration: 30)
        let zeroDuration = StatsFixture.record(
            startedAt: march(11), words: 800, speakingDuration: 0)
        let model = model(records: [timed, zeroDuration])

        await model.refresh()

        let pace = model.insights.first { $0.id == "pace" }
        XCTAssertEqual(pace?.detail, "Average of 1 timed dictation this month.")
        XCTAssertFalse(pace?.detail.contains("2") == true)
    }

    func testCurrentStreakContinuesAcrossCalendarMonthBoundary() async {
        let februaryLast = StatsFixture.record(
            startedAt: StatsFixture.date(utc, 2026, 2, 28), words: 10)
        let marchFirst = StatsFixture.record(
            startedAt: StatsFixture.date(utc, 2026, 3, 1), words: 10)
        let model = model(records: [februaryLast, marchFirst], now: march(1))

        await model.refresh()

        XCTAssertEqual(model.monthSummary.currentStreakDays, 1,
                       "The month-scoped summary cannot see February.")
        XCTAssertEqual(model.currentStreakDays, 2,
                       "Overview's streak must use full history across the boundary.")
    }

    // MARK: - Empty, and unreadable

    func testAnEmptyLogInventsNothingAnywhere() async {
        let model = model(records: [])
        await model.refresh()

        XCTAssertFalse(model.hasRecords)
        XCTAssertTrue(model.hasLoadedSuccessfully)
        XCTAssertTrue(model.recent.isEmpty)
        XCTAssertEqual(model.monthSummary, .empty)
        XCTAssertEqual(model.hero, .needsTypingTest)
        XCTAssertNil(model.heroFigure)
        XCTAssertTrue(model.wordShares.isEmpty)
        XCTAssertEqual(model.activityDays.count, ActivityCalendar.dayCount)
        XCTAssertTrue(model.activityDays.allSatisfy { $0.wordCount == 0 && $0.dictationCount == 0 })
        XCTAssertTrue(model.insights.isEmpty)
        // The week is still seven days: an absent day is drawn as zero, not omitted.
        XCTAssertEqual(model.week.count, WordsPerDaySeries.dayCount)
        XCTAssertEqual(model.week.map(\.wordCount), [0, 0, 0, 0, 0, 0, 0])
        XCTAssertNil(model.loadFailure)
    }

    func testAnUnreadableLogIsReportedRatherThanShownAsZero() async {
        let model = model(records: [], loadError: FakeFailure.boom("disk gone"))
        await model.refresh()

        XCTAssertNotNil(model.loadFailure)
        XCTAssertFalse(model.hasLoadedSuccessfully)
        XCTAssertTrue(model.recent.isEmpty)
        XCTAssertFalse(model.hasRecords,
                       "An unreadable log is not evidence that there are no dictations.")
        XCTAssertTrue(model.activityDays.isEmpty,
                      "A failed first read must not manufacture 91 zero-activity days.")
    }

    func testRefreshClearsAPreviousFailure() async {
        var shouldFail = true
        let model = HomeViewModel(
            loadRecords: {
                if shouldFail { throw FakeFailure.boom("transient") }
                return [StatsFixture.record(startedAt: self.march(10))]
            },
            baselineWPM: { nil },
            actions: HomeActions(startTypingTest: {}),
            calendar: utc,
            now: { self.march(20) })

        await model.refresh()
        XCTAssertNotNil(model.loadFailure)

        shouldFail = false
        await model.refresh()
        XCTAssertNil(model.loadFailure)
        XCTAssertTrue(model.hasRecords)
    }

    // MARK: - Injected seams

    /// The typing test is Task 26. Home only starts it.
    func testStartingTheTypingTestGoesThroughTheInjectedClosure() {
        var started = 0
        let model = model(actions: HomeActions(startTypingTest: { started += 1 }))

        model.actions.startTypingTest()

        XCTAssertEqual(started, 1)
    }

    func testTheModeGlyphComesFromTheInjectedResolver() async {
        let model = model(
            records: [StatsFixture.record(startedAt: march(10), modeID: "email")],
            resolveMode: { id in
                id == "email" ? ModeBadge(name: "Email", symbol: "envelope") : nil
            })
        await model.refresh()

        XCTAssertEqual(model.recent.first?.mode?.symbol, "envelope")
        XCTAssertEqual(model.recent.first?.mode?.name, "Email")
    }

    /// With no resolver (Modes is Task 23) the row must degrade to no glyph rather than
    /// to a wrong one.
    func testAnUnresolvedModeLeavesTheGlyphAbsent() async {
        let model = model(records: [StatsFixture.record(startedAt: march(10))])
        await model.refresh()

        XCTAssertNil(model.recent.first?.mode)
        XCTAssertEqual(model.recent.first?.modeID, "email")
    }

    func testWhereTheWordsGoUsesTheMonthWindowAndCapsAtFourPlusOther() async {
        let records = (0..<6).map { index in
            StatsFixture.record(
                startedAt: march(10),
                words: 60 - index * 10,
                bundleID: "app.\(index)",
                appName: "App \(index)")
        } + [StatsFixture.record(
            startedAt: StatsFixture.date(utc, 2026, 2, 5), words: 9_999,
            bundleID: "app.lastmonth", appName: "Last Month")]

        let model = model(records: records)
        await model.refresh()

        XCTAssertEqual(model.wordShares.count, 5)
        XCTAssertEqual(model.wordShares.map(\.label),
                       ["App 0", "App 1", "App 2", "App 3", AppBreakdown.otherLabel])
        XCTAssertFalse(model.wordShares.contains { $0.label == "Last Month" })
    }

    // MARK: - Formatting

    func testTimeSavedFormattingIsHonestAtEveryScale() {
        XCTAssertEqual(TimeSavedFormat.short(0), "0m")
        XCTAssertEqual(TimeSavedFormat.short(29), "0m")
        XCTAssertEqual(TimeSavedFormat.short(60), "1m")
        XCTAssertEqual(TimeSavedFormat.short(48 * 60), "48m")
        XCTAssertEqual(TimeSavedFormat.short(60 * 60), "1h")
        XCTAssertEqual(TimeSavedFormat.short(72 * 60), "1h 12m")
        // A minus sign, not a hyphen, and never dropped.
        XCTAssertEqual(TimeSavedFormat.short(-180), "−3m")
    }

    // MARK: - The window: built lazily, released on close (spec §15)

    /// A stand-in for `MainWindowController` so the lifecycle is testable without an
    /// `NSWindow` — and, more to the point, without launching a second Captur.
    private final class FakeHost: MainWindowHosting {
        var presentCount = 0
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func present() { presentCount += 1 }
    }

    func testTheWindowIsNotBuiltUntilItIsOpened() {
        var built = 0
        let presenter = MainWindowPresenter { close in
            built += 1
            return FakeHost(close: close)
        }

        XCTAssertFalse(presenter.isBuilt)
        XCTAssertEqual(built, 0)
    }

    func testRepeatedOpensReuseTheSameWindow() {
        var built = 0
        var hosts: [FakeHost] = []
        let presenter = MainWindowPresenter { close in
            built += 1
            let host = FakeHost(close: close)
            hosts.append(host)
            return host
        }

        presenter.open()
        presenter.open()

        XCTAssertEqual(built, 1)
        XCTAssertEqual(hosts.first?.presentCount, 2)
        XCTAssertTrue(presenter.isBuilt)
    }

    /// The release is the spec §15 requirement, so the assertion is on the reference
    /// actually going away — not merely on a flag flipping.
    func testClosingTheWindowReleasesIt() {
        var built = 0
        weak var weakHost: FakeHost?
        var close: (() -> Void)?

        let presenter = MainWindowPresenter { onClose in
            built += 1
            let host = FakeHost(close: onClose)
            weakHost = host
            close = onClose
            return host
        }

        presenter.open()
        XCTAssertNotNil(weakHost)

        close?()

        XCTAssertNil(weakHost, "Closing must drop the last strong reference to the window.")
        XCTAssertFalse(presenter.isBuilt)

        presenter.open()
        XCTAssertEqual(built, 2, "A closed window is rebuilt, not resurrected.")
    }

    func testTheWindowIsTheSizeTheSpecAsksFor() {
        XCTAssertEqual(MainWindowController.contentSize, NSSize(width: 1080, height: 740))
    }
}
