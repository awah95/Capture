import XCTest
@testable import Captur

final class ActivityCalendarTests: XCTestCase {
    func testCalendarProducesNinetyOneLocalDaysAndZeroFillsGapsAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        calendar.locale = Locale(identifier: "en_US")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 20, hour: 12)))
        let activeDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 8)))
        let active = StatsDay(dayStart: calendar.startOfDay(for: activeDate),
                              dictationCount: 2, wordCount: 93)

        let days = ActivityCalendar.days(from: [active], endingAt: now, calendar: calendar)

        XCTAssertEqual(days.count, 91)
        XCTAssertEqual(Set(days.map(\.date)).count, 91)
        XCTAssertEqual(days.last?.date, calendar.startOfDay(for: now))
        XCTAssertEqual(days.first(where: { $0.date == active.dayStart })?.dictationCount, 2)
        XCTAssertEqual(days.first(where: { $0.date == active.dayStart })?.wordCount, 93)
        XCTAssertEqual(days.filter { $0.dictationCount == 0 }.count, 90)

        for pair in zip(days, days.dropFirst()) {
            XCTAssertEqual(calendar.dateComponents([.day], from: pair.0.date, to: pair.1.date).day, 1)
        }
        let dstIndex = try XCTUnwrap(days.firstIndex(where: { $0.date == active.dayStart }))
        XCTAssertEqual(days[dstIndex + 1].date.timeIntervalSince(days[dstIndex].date), 23 * 60 * 60,
                       "The sequence must use calendar days, not fixed 24-hour steps.")
    }

    func testCalendarEndsTodayAndDoesNotExposeFutureBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 1, hour: 8)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1,
                                                   to: calendar.startOfDay(for: now)))
        let days = ActivityCalendar.days(
            from: [StatsDay(dayStart: tomorrow, dictationCount: 99, wordCount: 999)],
            endingAt: now, calendar: calendar)

        XCTAssertEqual(days.last?.date, calendar.startOfDay(for: now))
        XCTAssertFalse(days.contains { $0.date > calendar.startOfDay(for: now) })
        XCTAssertEqual(days.reduce(0) { $0 + $1.wordCount }, 0)
    }

    func testIntensityIsBoundedAndZeroIsAlwaysEmpty() {
        XCTAssertEqual(ActivityCalendar.level(value: 0, metric: .dictations), 0)
        XCTAssertEqual(ActivityCalendar.level(value: 1, metric: .dictations), 1)
        XCTAssertEqual(ActivityCalendar.level(value: 3, metric: .dictations), 2)
        XCTAssertEqual(ActivityCalendar.level(value: 7, metric: .dictations), 3)
        XCTAssertEqual(ActivityCalendar.level(value: 8, metric: .dictations), 4)
        XCTAssertEqual(ActivityCalendar.level(value: 99, metric: .words), 1)
        XCTAssertEqual(ActivityCalendar.level(value: 100, metric: .words), 2)
        XCTAssertEqual(ActivityCalendar.level(value: 500, metric: .words), 4)
    }

    func testDisplayGridPadsWithoutChangingTheNinetyOneRealDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 2 // Monday
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 20, hour: 12)))
        let days = ActivityCalendar.days(from: [], endingAt: now, calendar: calendar)

        let grid = ActivityCalendar.grid(days: days, calendar: calendar)

        XCTAssertEqual(grid.days, days)
        XCTAssertEqual(grid.weekdayLabels, ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertTrue(grid.columns.allSatisfy { $0.count == 7 })
        let firstWeekday = calendar.component(.weekday, from: try XCTUnwrap(days.first?.date))
        let expectedLeading = (firstWeekday - calendar.firstWeekday + 7) % 7
        XCTAssertEqual(grid.columns.first?.prefix(expectedLeading).filter { $0 == nil }.count,
                       expectedLeading)
        let expectedTrailing = (7 - (expectedLeading + ActivityCalendar.dayCount) % 7) % 7
        XCTAssertEqual(grid.columns.last?.suffix(expectedTrailing).filter { $0 == nil }.count,
                       expectedTrailing)
        XCTAssertEqual(grid.columns.flatMap { $0 }.compactMap { $0 }.count, 91)
    }

    func testWeekdayRowsStayFixedWhenTodayAdvances() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let firstNow = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 20, hour: 12)))
        let secondNow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstNow))
        let firstGrid = ActivityCalendar.grid(
            days: ActivityCalendar.days(from: [], endingAt: firstNow, calendar: calendar),
            calendar: calendar)
        let secondGrid = ActivityCalendar.grid(
            days: ActivityCalendar.days(from: [], endingAt: secondNow, calendar: calendar),
            calendar: calendar)

        func row(of date: Date, in grid: ActivityCalendarGrid) -> Int? {
            for column in grid.columns {
                if let index = column.firstIndex(where: { $0?.date == date }) { return index }
            }
            return nil
        }

        for day in firstGrid.days.dropFirst() {
            XCTAssertEqual(row(of: day.date, in: firstGrid), row(of: day.date, in: secondGrid))
        }
    }

    func testGridNavigationNeverWrapsOrEntersPadding() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 2
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 20, hour: 12)))
        let grid = ActivityCalendar.grid(
            days: ActivityCalendar.days(from: [], endingAt: now, calendar: calendar),
            calendar: calendar)

        let top = try XCTUnwrap(grid.columns[1][0]?.date)
        XCTAssertEqual(grid.destination(from: top, moving: .up), top,
                       "Up from the first row must not wrap to the previous column.")

        let bottom = try XCTUnwrap(grid.columns[0][6]?.date)
        XCTAssertEqual(grid.destination(from: bottom, moving: .down), bottom,
                       "Down from the last row must not wrap to the next column.")

        XCTAssertNil(grid.columns[0][0])
        XCTAssertEqual(grid.destination(from: top, moving: .left), top,
                       "Left toward leading padding must stay on the real date.")

        let validLeft = try XCTUnwrap(grid.columns[0][6]?.date)
        let validRight = try XCTUnwrap(grid.columns[1][6]?.date)
        XCTAssertEqual(grid.destination(from: validRight, moving: .left), validLeft,
                       "Horizontal movement keeps the weekday row when both cells are real.")

        let last = try XCTUnwrap(grid.days.last?.date)
        XCTAssertEqual(grid.destination(from: last, moving: .right), last,
                       "Right must not enter trailing padding or create a future date.")
    }

    func testMonthLabelAppearsOnTheColumnContainingTheMonthBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 2
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 20, hour: 12)))
        let grid = ActivityCalendar.grid(
            days: ActivityCalendar.days(from: [], endingAt: now, calendar: calendar),
            calendar: calendar)
        let januaryFirst = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 1)))
        let boundaryColumn = try XCTUnwrap(grid.coordinate(of: januaryFirst)?.column)
        let january = try XCTUnwrap(grid.days.first { $0.date == januaryFirst })

        XCTAssertEqual(grid.monthLabel(forColumn: boundaryColumn), "Jan")
        XCTAssertNotEqual(grid.columns[boundaryColumn].compactMap { $0 }.first?.monthKey,
                          january.monthKey,
                          "The test must prove a mid-column boundary, not a top-row boundary.")
    }
}
