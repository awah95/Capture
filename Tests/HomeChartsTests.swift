import SwiftUI
import XCTest
@testable import Captur

/// The chart maths behind Home's stats column, spec §11.3.
///
/// The charts are hand-rolled `Canvas` drawings, so every number that decides where a
/// mark lands is a pure function and is asserted here. A chart whose layout is only
/// verifiable by eye cannot be regression-tested at all, which is the whole reason this
/// file exists rather than a screenshot.
final class HomeChartsTests: XCTestCase {

    private let size = CGSize(width: 280, height: 120)

    // MARK: - Domain: proportional, and anchored at zero

    /// "Proportional figures" means a bar twice the value is twice the length, starting
    /// at zero. An axis that starts at the minimum value to use the space is a lie.
    func testTheDomainAlwaysIncludesZero() {
        let geometry = BarChartGeometry.make(values: [50, 55, 60], size: size)

        XCTAssertEqual(geometry.y(for: 0), geometry.baselineY, accuracy: 0.0001)
        XCTAssertEqual(geometry.baselineY, size.height, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(geometry.upperBound, 60)
    }

    func testBarLengthIsProportionalToValue() {
        let geometry = BarChartGeometry.make(values: [10, 20, 40], size: size)
        let lengths = geometry.bars.map { $0.rect.height }

        XCTAssertEqual(lengths[1], lengths[0] * 2, accuracy: 0.0001)
        XCTAssertEqual(lengths[2], lengths[0] * 4, accuracy: 0.0001)
        XCTAssertEqual(geometry.bars.map { $0.rect.maxY },
                       [geometry.baselineY, geometry.baselineY, geometry.baselineY])
    }

    func testTheUpperBoundIsANiceNumberThatNeverCropsAMark() {
        XCTAssertEqual(BarChartGeometry.niceUpperBound(0), 1)
        XCTAssertEqual(BarChartGeometry.niceUpperBound(-5), 1)
        XCTAssertEqual(BarChartGeometry.niceUpperBound(60), 60)
        XCTAssertEqual(BarChartGeometry.niceUpperBound(61), 70)
        XCTAssertEqual(BarChartGeometry.niceUpperBound(130), 150)
        XCTAssertEqual(BarChartGeometry.niceUpperBound(1), 1)

        for value in stride(from: 0.0, through: 5_000.0, by: 7.0) {
            let bound = BarChartGeometry.niceUpperBound(value)
            XCTAssertGreaterThan(bound, 0, "A zero bound would divide by zero at \(value)")
            XCTAssertGreaterThanOrEqual(bound, value, "A mark would be clipped at \(value)")
        }
    }

    func testAxisTicksRunFromZeroToTheUpperBound() {
        let geometry = BarChartGeometry.make(values: [10, 30], size: size)

        XCTAssertEqual(geometry.ticks.first, 0)
        XCTAssertEqual(geometry.ticks.last, geometry.upperBound)
        XCTAssertEqual(geometry.ticks.count, 3, "0, midpoint, top — the axis is recessive.")
    }

    // MARK: - Bar geometry, spec §11.3

    func testBarsAreCappedAtTwentyFourPointsWithATwoPointSurfaceGap() {
        // Seven slots in a wide canvas: uncapped, each bar would be ~68 pt.
        let geometry = BarChartGeometry.make(
            values: Array(repeating: 10, count: 7), size: CGSize(width: 480, height: 100))

        for bar in geometry.bars {
            XCTAssertEqual(bar.rect.width, BarChartGeometry.maximumBarWidth, accuracy: 0.0001)
        }

        // Narrow enough that the cap does not bind: the gap is what survives.
        let tight = BarChartGeometry.make(
            values: Array(repeating: 10, count: 7), size: CGSize(width: 100, height: 100))
        let pitch = 100.0 / 7.0
        XCTAssertEqual(tight.bars[0].rect.width,
                       pitch - BarChartGeometry.surfaceGap, accuracy: 0.0001)
        XCTAssertEqual(tight.bars[1].rect.minX - tight.bars[0].rect.maxX,
                       BarChartGeometry.surfaceGap, accuracy: 0.0001)
    }

    func testBarsAreCentredInTheirSlotSoTheSeriesReadsEvenlySpaced() {
        let geometry = BarChartGeometry.make(
            values: [1, 1, 1, 1], size: CGSize(width: 400, height: 100))
        let centres = geometry.bars.map(\.rect.midX)

        XCTAssertEqual(centres, [50, 150, 250, 350])
    }

    // MARK: - Empty and near-empty data must not crash

    func testAnEmptySeriesProducesNoBarsAndNoDivisionByZero() {
        let geometry = BarChartGeometry.make(values: [], size: size)

        XCTAssertTrue(geometry.bars.isEmpty)
        XCTAssertGreaterThan(geometry.upperBound, 0)
        XCTAssertNil(geometry.extremeIndex)
        XCTAssertEqual(geometry.y(for: 0), geometry.baselineY, accuracy: 0.0001)
    }

    func testASingleBarFillsTheCanvasWithoutOverflowingIt() {
        let geometry = BarChartGeometry.make(values: [42], size: size)

        XCTAssertEqual(geometry.bars.count, 1)
        XCTAssertGreaterThan(geometry.bars[0].rect.height, 0)
        XCTAssertLessThanOrEqual(geometry.bars[0].rect.height, size.height + 0.0001)
        XCTAssertEqual(geometry.extremeIndex, 0)
    }

    func testAnAllZeroSeriesDrawsNothingAndLabelsNothing() {
        let geometry = BarChartGeometry.make(values: [0, 0, 0, 0, 0, 0, 0], size: size)

        XCTAssertEqual(geometry.bars.count, 7)
        XCTAssertEqual(geometry.bars.map { $0.rect.height }, Array(repeating: 0, count: 7))
        XCTAssertNil(geometry.extremeIndex,
                     "There is no extreme value in a week with no words.")
        for bar in geometry.bars {
            XCTAssertFalse(bar.isExtreme)
        }
    }

    func testAZeroDayBetweenTwoDaysWithWordsIsAZeroHeightBarNotAGap() {
        let geometry = BarChartGeometry.make(values: [30, 0, 30], size: size)

        XCTAssertEqual(geometry.bars.count, 3)
        XCTAssertEqual(geometry.bars[1].rect.height, 0)
        // The hit target survives even though nothing is painted: hovering an empty day
        // must still say "0 words", not nothing at all.
        XCTAssertGreaterThan(geometry.bars[1].hitRect.height, 0)
    }

    func testAZeroSizedCanvasProducesNoBarsRatherThanNegativeOnes() {
        let geometry = BarChartGeometry.make(values: [10, 20], size: .zero)

        XCTAssertTrue(geometry.bars.isEmpty)
        XCTAssertGreaterThan(geometry.upperBound, 0)
    }

    // MARK: - Direct-label the extreme only

    func testExactlyOneMarkIsDirectLabelled() {
        let geometry = BarChartGeometry.make(values: [10, 90, 30, 90], size: size)

        XCTAssertEqual(geometry.bars.filter(\.isExtreme).count, 1)
        XCTAssertEqual(geometry.extremeIndex, 1, "A tie goes to the earlier mark.")
    }

    // MARK: - Hover tooltip on every mark

    func testHoverHitsTheColumnNotJustThePaintedBar() {
        let geometry = BarChartGeometry.make(values: [5, 100], size: size)
        let shortBar = geometry.bars[0]

        // A point near the top of the canvas, horizontally over the short bar.
        let hit = geometry.bar(at: CGPoint(x: shortBar.rect.midX, y: 4))
        XCTAssertEqual(hit?.index, 0)

        // And every mark is reachable, which is what "on every mark" means.
        for bar in geometry.bars {
            XCTAssertEqual(geometry.bar(at: CGPoint(x: bar.rect.midX, y: size.height / 2))?.index,
                           bar.index)
        }
    }

    func testHoverOutsideTheCanvasHitsNothing() {
        let geometry = BarChartGeometry.make(values: [5, 100], size: size)

        XCTAssertNil(geometry.bar(at: CGPoint(x: -10, y: 10)))
        XCTAssertNil(geometry.bar(at: CGPoint(x: size.width + 10, y: 10)))
    }

    // MARK: - Words per day, current week

    private func calendar(_ zone: String, firstWeekday: Int = 1) -> Calendar {
        var calendar = StatsFixture.calendar(zone)
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    func testTheWeekIsAlwaysSevenAscendingDays() {
        let utc = calendar("UTC")
        let series = WordsPerDaySeries.currentWeek(
            containing: StatsFixture.date(utc, 2026, 3, 18),
            calendar: utc,
            from: [])

        XCTAssertEqual(series.count, WordsPerDaySeries.dayCount)
        XCTAssertEqual(series.map(\.dayStart).sorted(), series.map(\.dayStart))
        // 18 March 2026 is a Wednesday; with firstWeekday = Sunday the week opens on
        // the 15th.
        XCTAssertEqual(series.first?.dayStart, StatsFixture.date(utc, 2026, 3, 15, 0))
        XCTAssertEqual(series.last?.dayStart, StatsFixture.date(utc, 2026, 3, 21, 0))
    }

    func testTheWeekRespectsFirstWeekday() {
        let monday = calendar("UTC", firstWeekday: 2)
        let series = WordsPerDaySeries.currentWeek(
            containing: StatsFixture.date(monday, 2026, 3, 18),
            calendar: monday,
            from: [])

        XCTAssertEqual(series.first?.dayStart, StatsFixture.date(monday, 2026, 3, 16, 0))
    }

    func testAbsentDaysAreZeroFilledRatherThanOmitted() {
        let utc = calendar("UTC")
        let days = [
            StatsDay(dayStart: StatsFixture.date(utc, 2026, 3, 16, 0),
                     dictationCount: 2, wordCount: 30),
            StatsDay(dayStart: StatsFixture.date(utc, 2026, 3, 18, 0),
                     dictationCount: 1, wordCount: 40)
        ]
        let series = WordsPerDaySeries.currentWeek(
            containing: StatsFixture.date(utc, 2026, 3, 18),
            calendar: utc,
            from: days)

        XCTAssertEqual(series.map(\.wordCount), [0, 30, 0, 40, 0, 0, 0])
        XCTAssertEqual(series.map(\.dictationCount), [0, 2, 0, 1, 0, 0, 0])
    }

    func testDaysOutsideTheWeekAreIgnored() {
        let utc = calendar("UTC")
        let days = [
            StatsDay(dayStart: StatsFixture.date(utc, 2026, 3, 8, 0),
                     dictationCount: 9, wordCount: 900),
            StatsDay(dayStart: StatsFixture.date(utc, 2026, 3, 16, 0),
                     dictationCount: 1, wordCount: 10)
        ]
        let series = WordsPerDaySeries.currentWeek(
            containing: StatsFixture.date(utc, 2026, 3, 18),
            calendar: utc,
            from: days)

        XCTAssertEqual(series.map(\.wordCount).reduce(0, +), 10)
    }

    /// Day steps go through `Calendar`, never through 86 400 seconds: the day a region
    /// springs forward is 23 hours long, and second arithmetic silently loses it.
    func testTheWeekSurvivesADaylightSavingTransition() {
        // US DST begins Sunday 8 March 2026.
        let newYork = calendar("America/New_York")
        let series = WordsPerDaySeries.currentWeek(
            containing: StatsFixture.date(newYork, 2026, 3, 10, 12),
            calendar: newYork,
            from: [])

        XCTAssertEqual(series.count, 7)
        XCTAssertEqual(Set(series.map(\.dayStart)).count, 7)
        XCTAssertEqual(series.first?.dayStart, StatsFixture.date(newYork, 2026, 3, 8, 0))
        XCTAssertEqual(series.last?.dayStart, StatsFixture.date(newYork, 2026, 3, 14, 0))
        for day in series {
            XCTAssertEqual(newYork.startOfDay(for: day.dayStart), day.dayStart)
        }
    }

    func testWeekdayLabelsAreShortAndInTheChartsCalendar() {
        let utc = calendar("UTC")
        let series = WordsPerDaySeries.currentWeek(
            containing: StatsFixture.date(utc, 2026, 3, 18),
            calendar: utc,
            from: [])

        XCTAssertEqual(series.map(\.label), ["S", "M", "T", "W", "T", "F", "S"])
    }

    // MARK: - Where the words go

    private func group(_ key: String?, _ name: String?, words: Int, count: Int = 1) -> StatsGroup {
        StatsGroup(key: key, displayName: name, dictationCount: count, wordCount: words)
    }

    func testTopFourAppsPlusOther() {
        let groups = [
            group("a", "Alpha", words: 100),
            group("b", "Bravo", words: 80),
            group("c", "Charlie", words: 60),
            group("d", "Delta", words: 40),
            group("e", "Echo", words: 15),
            group("f", "Foxtrot", words: 5)
        ]
        let shares = AppBreakdown.shares(from: groups)

        XCTAssertEqual(shares.count, 5)
        XCTAssertEqual(shares.map(\.label),
                       ["Alpha", "Bravo", "Charlie", "Delta", AppBreakdown.otherLabel])
        XCTAssertEqual(shares.last?.wordCount, 20)
        XCTAssertTrue(shares.last?.isOther == true)
        XCTAssertEqual(shares.map(\.fraction).reduce(0, +), 1, accuracy: 0.0001)
    }

    /// The off-by-one at the cap: exactly four groups is four rows, and exactly five is
    /// four plus Other — not five rows, and not three plus Other.
    func testTheOtherBucketOnlyExistsWhenSomethingIsInIt() {
        let four = (0..<4).map { group("k\($0)", "App \($0)", words: 10 - $0) }
        XCTAssertEqual(AppBreakdown.shares(from: four).count, 4)
        XCTAssertFalse(AppBreakdown.shares(from: four).contains { $0.isOther })

        let five = four + [group("k4", "App 4", words: 1)]
        let shares = AppBreakdown.shares(from: five)
        XCTAssertEqual(shares.count, 5)
        XCTAssertTrue(shares.last?.isOther == true)
        XCTAssertEqual(shares.last?.wordCount, 1)
    }

    func testASingleGroupIsOneHundredPercentAndDoesNotDivideByZero() {
        let shares = AppBreakdown.shares(from: [group("a", "Alpha", words: 42)])

        XCTAssertEqual(shares.count, 1)
        XCTAssertEqual(shares[0].fraction, 1, accuracy: 0.0001)
    }

    func testNoWordsAtAllGivesNoSharesAndNoNaN() {
        XCTAssertTrue(AppBreakdown.shares(from: []).isEmpty)

        // Groups can exist with zero words (a dictation of nothing but filler the mode
        // stripped). They are not rows in a words chart.
        let shares = AppBreakdown.shares(from: [group("a", "Alpha", words: 0)])
        XCTAssertTrue(shares.isEmpty)
        for share in shares {
            XCTAssertFalse(share.fraction.isNaN)
        }
    }

    /// The aggregator refuses to invent "Unknown" for the no-frontmost-app bucket; the
    /// UI is where that name is decided, so this is where it is asserted.
    func testTheNoAppBucketIsNamedHereAndTheBundleIDStandsInForAMissingName() {
        let shares = AppBreakdown.shares(from: [
            group(nil, nil, words: 30),
            group("com.example.thing", nil, words: 20)
        ])

        XCTAssertEqual(shares.map(\.label), [AppBreakdown.noAppLabel, "com.example.thing"])
    }

    // MARK: - Palette: dark mode is chosen, not flipped

    func testSequentialStepsAreSingleHueAndMonotonic() {
        for steps in [ChartPalette.lightSteps, ChartPalette.darkSteps] {
            XCTAssertEqual(steps.count, 5)
            XCTAssertEqual(steps, steps.sorted(by: >), "A sequential ramp only goes one way.")
        }
    }

    /// "Dark mode gets its own selected steps validated against the dark surface, not an
    /// inverted flip." Both halves of that are assertable.
    func testDarkStepsAreTheirOwnRampAndNotAnInvertedLightOne() {
        XCTAssertNotEqual(ChartPalette.darkSteps, ChartPalette.lightSteps)
        XCTAssertNotEqual(ChartPalette.darkSteps, ChartPalette.lightSteps.reversed())
        XCTAssertGreaterThan(
            ChartPalette.darkSteps.last!, ChartPalette.lightSteps.last!,
            "The faintest step has to lift off a dark surface, so its floor is higher.")
    }

    func testAnOutOfRangeRankClampsRatherThanCrashes() {
        XCTAssertEqual(ChartPalette.opacity(rank: 99, of: 3, scheme: .light),
                       ChartPalette.lightSteps.last!)
        XCTAssertEqual(ChartPalette.opacity(rank: -4, of: 3, scheme: .dark),
                       ChartPalette.darkSteps.first!)
        XCTAssertEqual(ChartPalette.opacity(rank: 0, of: 1, scheme: .light),
                       ChartPalette.lightSteps.first!)
    }

    // MARK: - The split, spec §10.1

    func testTheSplitIsSixtyFortyAtTheWindowsNaturalWidth() {
        let split = HomeLayout.split(width: 900)

        XCTAssertEqual(split.recent, 540, accuracy: 0.0001)
        XCTAssertEqual(split.stats, 360, accuracy: 0.0001)
    }

    func testTheStatsColumnKeepsItsMinimumBeforeTheRecentListDoes() {
        let split = HomeLayout.split(width: 620)

        XCTAssertEqual(split.stats, HomeLayout.minimumStatsWidth, accuracy: 0.0001)
        XCTAssertEqual(split.recent + split.stats, 620, accuracy: 0.0001)
    }

    func testAWindowTooNarrowForBothMinimumsFallsBackToProportionsNotNegatives() {
        for width in [0.0, 60.0, 300.0, 500.0] {
            let split = HomeLayout.split(width: width)
            XCTAssertGreaterThanOrEqual(split.recent, 0, "width \(width)")
            XCTAssertGreaterThanOrEqual(split.stats, 0, "width \(width)")
            XCTAssertEqual(split.recent + split.stats, width, accuracy: 0.0001)
        }
    }

    // MARK: - Sidebar

    /// Spec §10's list is "Home · History · Modes · Vocabulary · Settings", and this
    /// test pinned exactly that — but §10 predates the stats page. **LV8 names the
    /// screens that must exist and Stats is one of them**: "Screenshot Home, History,
    /// Modes, Vocabulary, Settings, Stats, and the first-run checklist in light and
    /// dark." The gate is the later, more specific document, so Stats is a tab.
    ///
    /// It sits second rather than last because it is the other half of what Home shows;
    /// spec §11 treats the two as one story told at two depths.
    func testTheSidebarIsEverySpecScreenInOrder() {
        XCTAssertEqual(SidebarView.Tab.allCases.map(\.title),
                       ["Overview", "Analytics", "Captures", "Modes", "Vocabulary", "Settings"])
        for tab in SidebarView.Tab.allCases {
            XCTAssertFalse(tab.symbol.isEmpty)
        }
    }

    @MainActor
    func testProgrammaticWindowNavigationSelectsDestinationsAndRequestsTypingTest() {
        let navigation = MainWindowNavigation()
        XCTAssertEqual(navigation.selection, .home)

        navigation.show(.history)
        XCTAssertEqual(navigation.selection, .history)

        navigation.startTypingTest()
        XCTAssertEqual(navigation.selection, .stats)
        XCTAssertEqual(navigation.typingTestRequestID, 1)
        XCTAssertTrue(navigation.consumeTypingTestRequest())
        XCTAssertFalse(navigation.consumeTypingTestRequest(),
                       "rebuilding Stats must not replay an old request")

        navigation.startTypingTest()
        XCTAssertEqual(navigation.typingTestRequestID, 2)
        XCTAssertTrue(navigation.consumeTypingTestRequest())
    }
}
