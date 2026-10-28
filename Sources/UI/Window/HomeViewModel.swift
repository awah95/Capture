import Foundation
import Observation

// MARK: - Rows

/// What Home needs to know about a mode to draw its glyph.
///
/// A value type rather than a `Mode`, because Modes is Task 23 and Home has no business
/// depending on the whole editable model to print one symbol.
struct ModeBadge: Equatable, Sendable {
    let name: String
    let symbol: String
}

/// One row of Home's recent list, spec §10.1.
///
/// Every outcome is here — inserted, cancelled, failed — because spec §4.1 promises that
/// nothing spoken is ever lost, and a list that quietly drops the cancelled ones breaks
/// that promise in the one place the user would look to check it. What differs is the
/// marking, not the presence.
struct RecentDictation: Identifiable, Equatable {

    enum Status: Equatable {
        case inserted
        case cancelled
        case failed(reason: String)
    }

    /// Which text the row is previewing. A cancelled dictation usually has no final text,
    /// and showing the raw transcript *labelled as raw* is the difference between keeping
    /// the §4.1 promise and a row that reads as empty.
    enum PreviewSource: Equatable {
        case final
        case raw
        case none
    }

    static let cancelledBadge = "Cancelled"
    /// An `.inserted` record that carries `TranscriptStitcher.failureMarker`: a segment
    /// was permanently lost even though the rest reached the cursor. The record's own
    /// outcome says success, so this marker is the only signal it exists.
    static let partialBadge = "Partial"

    let id: UUID
    let startedAt: Date
    let status: Status
    let isPartial: Bool
    let preview: String?
    let previewSource: PreviewSource
    let modeID: String
    /// nil until Modes (Task 23) is wired in — no glyph rather than a wrong one.
    let mode: ModeBadge?
    let appName: String?
    let bundleID: String?
    let wordCount: Int
    /// The whole record, so the expanded row can show raw-vs-final and timings without a
    /// second trip through the log actor.
    let record: DictationRecord

    /// The one-word marking on the row, or nil for an ordinary success. A failure carries
    /// its own reason: "Failed" alone tells the user nothing they can act on, and the
    /// reason is already in the record.
    var badge: String? {
        switch status {
        case .cancelled: return Self.cancelledBadge
        case .failed(let reason): return reason.isEmpty ? "Failed" : reason
        case .inserted: return isPartial ? Self.partialBadge : nil
        }
    }

    /// The app the text went to, or nil. Never "Unknown" — see `AppBreakdown.noAppLabel`
    /// for where that name is decided.
    var appLabel: String? {
        if let appName, !appName.isEmpty { return appName }
        return bundleID
    }

    init(record: DictationRecord, mode: ModeBadge?) {
        id = record.id
        startedAt = record.startedAt
        switch record.outcome {
        case .inserted: status = .inserted
        case .cancelled: status = .cancelled
        case .failed(let reason): status = .failed(reason: reason)
        }
        isPartial = record.outcome == .inserted
            && record.finalText.contains(TranscriptStitcher.failureMarker)

        if let line = Self.firstLine(of: record.finalText) {
            preview = line
            previewSource = .final
        } else if let line = Self.firstLine(of: record.rawText) {
            preview = line
            previewSource = .raw
        } else {
            preview = nil
            previewSource = .none
        }

        modeID = record.modeID
        self.mode = mode
        appName = AppDisplayName.label(bundleID: record.targetBundleID,
                                       recordedName: record.targetAppName)
        bundleID = record.targetBundleID
        wordCount = record.wordCount
        self.record = record
    }

    /// The first line with anything on it. A transcript that opens with a blank line
    /// would otherwise preview as nothing at all.
    private static func firstLine(of text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

// MARK: - Hero

/// The time-saved hero, spec §10.1 and §11.2.
///
/// Two states, not one number with a sentinel. `timeSavedSeconds` is nil until the typing
/// test has been run, and the type makes the prompt state impossible to skip: there is no
/// `TimeInterval` to read in that case, so no call site can accidentally print zero.
enum TimeSavedHero: Equatable {
    /// No typing baseline. Spec §11.2: the UI says so rather than inventing an
    /// average-typist number the user never produced.
    case needsTypingTest
    /// May be negative. A dictation slower than typing did not save time, and clamping it
    /// would flatter the one number this feature exists to keep honest.
    case saved(seconds: TimeInterval)
}

/// Formats a saving for the hero.
enum TimeSavedFormat {

    /// Hours and minutes, minutes alone under an hour. Seconds are never shown: the
    /// underlying figure is a sum of estimates, and "3 m 14 s saved" claims a precision
    /// it does not have.
    ///
    /// A negative saving keeps a real minus sign (U+2212), not a hyphen — at 48 pt a
    /// hyphen reads as a dash in the layout rather than as part of the number.
    static func short(_ seconds: TimeInterval) -> String {
        let sign = seconds < 0 ? "\u{2212}" : ""
        let totalMinutes = Int((abs(seconds) / 60).rounded(.down))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours == 0 { return "\(sign)\(minutes)m" }
        if minutes == 0 { return "\(sign)\(hours)h" }
        return "\(sign)\(hours)h \(minutes)m"
    }
}

// MARK: - Overview analytics

/// A comparison with the immediately preceding calendar period. A zero previous value
/// has no percentage change: calling a first observed value “100% up” would be invented.
struct PeriodComparison: Equatable {
    let current: Double
    let previous: Double

    var percentChange: Double? {
        guard previous != 0 else { return nil }
        return (current - previous) / abs(previous)
    }

    var accessibilityDescription: String {
        guard let percentChange else { return "No comparable previous-period value" }
        if percentChange == 0 { return "Unchanged from the same days last month" }
        let direction = percentChange > 0 ? "more" : "less"
        let magnitude = abs(percentChange * 100)
        if magnitude < 1 {
            return "Less than 1 percent \(direction) than the same days last month"
        }
        return "\(Int(magnitude.rounded())) percent \(direction) than the same days last month"
    }
}

struct OverviewInsight: Identifiable, Equatable {
    let id: String
    let symbol: String
    let eyebrow: String
    let title: String
    let detail: String
}

// MARK: - Actions

/// Everything Home can ask the rest of the app to do.
///
/// All injected, and the optional ones are genuinely optional: a nil closure means the
/// button is not rendered, rather than rendered and inert. Task 22 (History) owns
/// playback, retry and delete for real; Home borrows them if they are handed over.
struct HomeActions {
    /// Task 26 owns the 60-second typing test itself. Home only starts it.
    var startTypingTest: () -> Void
    /// The link to the full stats page (spec §10.1). Absent until that screen exists.
    var showFullStats: (() -> Void)?
    var playAudio: ((DictationRecord) -> Void)?
    var retry: ((UUID) -> Void)?
    var delete: ((UUID) -> Void)?

    init(
        startTypingTest: @escaping () -> Void,
        showFullStats: (() -> Void)? = nil,
        playAudio: ((DictationRecord) -> Void)? = nil,
        retry: ((UUID) -> Void)? = nil,
        delete: ((UUID) -> Void)? = nil
    ) {
        self.startTypingTest = startTypingTest
        self.showFullStats = showFullStats
        self.playAudio = playAudio
        self.retry = retry
        self.delete = delete
    }
}

// MARK: - View model

/// Everything behind `HomeView`, spec §10.1.
///
/// Every dependency is a closure or a value, so the whole screen is constructible in a
/// test with no filesystem, no record log and no typing baseline store. Nothing here
/// polls: `refresh()` is called when the pane appears and when the composition root says
/// a dictation finished (see `docs/wiring/task21-wiring.md`). A `Timer` refreshing this
/// would be a defect under spec §15, not a convenience.
@MainActor
@Observable
final class HomeViewModel {

    /// Spec §10.1 says "recent", and 20 is what recent means here: enough to cover a
    /// morning's work, short enough that the pane is a glance rather than a search.
    /// History (Task 22) is where the whole log lives.
    static let recentLimit = 20

    // MARK: State

    private(set) var recent: [RecentDictation] = []
    /// The current calendar month through today — spec §10.1's "time saved this month". Windowed
    /// summaries go through `StatsAggregator` directly rather than `StatsRollupCache`,
    /// which caches totals for the WHOLE log and would be poisoned by a filtered window.
    private(set) var monthSummary: StatsSummary = .empty
    private(set) var previousMonthSummary: StatsSummary = .empty
    private(set) var week: [WordsPerDay] = []
    private(set) var wordShares: [WordShare] = []
    private(set) var activityDays: [ActivityDay] = []
    private(set) var activityGrid: ActivityCalendarGrid = .empty
    private(set) var insights: [OverviewInsight] = []
    private(set) var currentStreakDays = 0
    /// True only when records were actually read. An unreadable log is not evidence that
    /// there are no dictations, so the empty state must not claim it is.
    private(set) var hasRecords = false
    /// Distinguishes a successfully-read empty log from the unmeasured state before the
    /// first read (or after its failure). Neither may be presented as measured zeroes.
    private(set) var hasLoadedSuccessfully = false
    private(set) var isLoading = false
    private(set) var loadFailure: String?

    let actions: HomeActions

    // MARK: Dependencies

    private let loadRecords: () async throws -> [DictationRecord]
    private let baselineWPM: () -> Double?
    private let resolveMode: (String) -> ModeBadge?
    private let summarize: ([DictationRecord], Double?, Calendar, Date) -> StatsSummary
    private let calendar: Calendar
    private let now: () -> Date

    init(
        loadRecords: @escaping () async throws -> [DictationRecord],
        baselineWPM: @escaping () -> Double?,
        resolveMode: @escaping (String) -> ModeBadge? = { _ in nil },
        actions: HomeActions,
        summarize: @escaping ([DictationRecord], Double?, Calendar, Date) -> StatsSummary
            = { records, wpm, calendar, now in
                StatsAggregator.summarize(records, baselineWPM: wpm, calendar: calendar, now: now)
            },
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.loadRecords = loadRecords
        self.baselineWPM = baselineWPM
        self.resolveMode = resolveMode
        self.actions = actions
        self.summarize = summarize
        self.calendar = calendar
        self.now = now
    }

    // MARK: Derived

    /// Spec §10.1 + §11.2. The prompt state is reached whenever there is no honest
    /// figure — which includes a baseline of zero, because dividing by it would report an
    /// infinite saving.
    var hero: TimeSavedHero {
        guard let seconds = monthSummary.timeSavedSeconds else { return .needsTypingTest }
        return .saved(seconds: seconds)
    }

    /// The figure, or **nil in the prompt state**. Nil rather than "0m" or "—": a
    /// formatter that can produce a number from no measurement is the bug this whole
    /// surface is arranged to avoid.
    var heroFigure: String? {
        guard case .saved(let seconds) = hero else { return nil }
        return TimeSavedFormat.short(seconds)
    }

    var wordsComparison: PeriodComparison {
        PeriodComparison(current: Double(monthSummary.totalWords),
                         previous: Double(previousMonthSummary.totalWords))
    }

    var dictationsComparison: PeriodComparison {
        PeriodComparison(current: Double(monthSummary.dictationCount),
                         previous: Double(previousMonthSummary.dictationCount))
    }

    var timeSavedComparison: PeriodComparison? {
        guard let current = monthSummary.timeSavedSeconds,
              let previous = previousMonthSummary.timeSavedSeconds,
              previous > 0 else { return nil }
        return PeriodComparison(current: current, previous: previous)
    }

    /// The month the hero covers, as a half-open interval. Exposed so the window can be
    /// asserted rather than inferred from the numbers it produces.
    static func monthWindow(of date: Date, calendar: Calendar) -> DateInterval {
        window(of: .month, containing: date, calendar: calendar)
    }

    static func monthToDateWindow(of date: Date, calendar: Calendar) -> DateInterval {
        let month = monthWindow(of: date, calendar: calendar)
        let today = calendar.startOfDay(for: date)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? month.end
        return DateInterval(start: month.start, end: min(tomorrow, month.end))
    }

    /// The same number of local calendar days in the preceding month. Comparing the
    /// first five days of this month with all of last month would be mathematically true
    /// but operationally misleading. A short preceding month clamps at its month end.
    static func previousMonthWindow(of date: Date, calendar: Calendar) -> DateInterval {
        let current = monthWindow(of: date, calendar: calendar)
        guard let previousDate = calendar.date(byAdding: .month, value: -1, to: current.start) else {
            return DateInterval(start: current.start, end: current.start)
        }
        let previous = monthWindow(of: previousDate, calendar: calendar)
        let currentDay = calendar.startOfDay(for: date)
        let elapsedDays = (calendar.dateComponents([.day], from: current.start, to: currentDay).day ?? 0) + 1
        let alignedEnd = calendar.date(byAdding: .day, value: elapsedDays, to: previous.start)
            ?? previous.end
        return DateInterval(start: previous.start, end: min(alignedEnd, previous.end))
    }

    /// The week the words-per-day chart covers. Not derived from the month: the current
    /// week straddles the month boundary twice a year and more, and taking the week's days
    /// out of a month-windowed summary would draw those days as zero.
    static func weekWindow(of date: Date, calendar: Calendar) -> DateInterval {
        window(of: .weekOfYear, containing: date, calendar: calendar)
    }

    private static func window(
        of component: Calendar.Component,
        containing date: Date,
        calendar: Calendar
    ) -> DateInterval {
        guard let interval = calendar.dateInterval(of: component, for: date) else {
            let day = calendar.startOfDay(for: date)
            return DateInterval(start: day, end: day)
        }
        return interval
    }

    /// Half-open, deliberately. `DateInterval.contains` includes its end, so a record
    /// stamped exactly midnight on the 1st would be counted in both months.
    private static func records(
        _ records: [DictationRecord],
        in window: DateInterval
    ) -> [DictationRecord] {
        records.filter { $0.startedAt >= window.start && $0.startedAt < window.end }
    }

    // MARK: Loading

    /// Re-reads the log and recomputes everything on screen.
    ///
    /// Deliberately not cancellable and deliberately not incremental: reading the log is
    /// milliseconds, and the two ways this could be clever — a diff against the previous
    /// read, or a cached summary for a filtered window — are both how a stats screen
    /// starts showing yesterday's numbers.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let records: [DictationRecord]
        do {
            records = try await loadRecords()
        } catch {
            // The previous rows are left alone. A transient read failure should not blank
            // a list the user is looking at, and it must not be reported as "no
            // dictations yet" either.
            loadFailure = error.localizedDescription
            return
        }

        loadFailure = nil
        hasLoadedSuccessfully = true
        hasRecords = !records.isEmpty
        recent = Self.recentRows(from: records, limit: Self.recentLimit, resolveMode: resolveMode)

        let today = now()

        // The recent list is NOT windowed: the left pane is "recent", not "this month".
        // An empty right column beside a full left one on the 1st of the month is the
        // honest reading of "time saved this month".
        let thisMonth = Self.records(
            records, in: Self.monthToDateWindow(of: today, calendar: calendar))
        let baseline = effectiveBaselineWPM()
        monthSummary = summarize(thisMonth, baseline, calendar, today)
        let previousMonth = Self.records(
            records, in: Self.previousMonthWindow(of: today, calendar: calendar))
        previousMonthSummary = summarize(previousMonth, baseline, calendar, today)
        wordShares = AppBreakdown.shares(from: monthSummary.byApp)

        // The contribution map has its own 91-day domain. It is derived from the same
        // successful-record daily buckets as every other word and dictation total.
        let allSummary = summarize(records, nil, calendar, today)
        currentStreakDays = allSummary.currentStreakDays
        activityDays = ActivityCalendar.days(
            from: allSummary.daily, endingAt: today, calendar: calendar)
        activityGrid = ActivityCalendar.grid(days: activityDays, calendar: calendar)
        let paceSampleCount = thisMonth.filter {
            $0.outcome == .inserted && $0.speakingDuration > 0
        }.count
        insights = Self.makeInsights(
            summary: monthSummary, paceSampleCount: paceSampleCount, calendar: calendar)

        // The week gets its own summary rather than being sliced out of the month's. The
        // current week straddles the month boundary at both ends of most months, and the
        // days on the far side of it would otherwise be drawn as zero — a chart claiming
        // the user said nothing on days they did.
        let thisWeek = Self.records(
            records, in: Self.weekWindow(of: today, calendar: calendar))
        let weekSummary = summarize(thisWeek, nil, calendar, today)
        week = WordsPerDaySeries.currentWeek(
            containing: today, calendar: calendar, from: weekSummary.daily)
    }

    private static func makeInsights(
        summary: StatsSummary,
        paceSampleCount: Int,
        calendar: Calendar
    ) -> [OverviewInsight] {
        guard summary.dictationCount > 0 else { return [] }
        var result: [OverviewInsight] = []

        if summary.averageWordsPerMinute > 0, paceSampleCount > 0 {
            result.append(OverviewInsight(
                id: "pace", symbol: "gauge.with.dots.needle.50percent", eyebrow: "Speaking pace",
                title: "\(Int(summary.averageWordsPerMinute.rounded())) words per minute",
                detail: "Average of \(paceSampleCount) \(paceSampleCount == 1 ? "timed dictation" : "timed dictations") this month."))
        }

        if let busiest = summary.daily.max(by: {
            if $0.wordCount == $1.wordCount { return $0.dayStart < $1.dayStart }
            return $0.wordCount < $1.wordCount
        }), busiest.wordCount > 0 {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? .current
            formatter.setLocalizedDateFormatFromTemplate("EEEE, MMM d")
            result.append(OverviewInsight(
                id: "busiest", symbol: "chart.bar.fill", eyebrow: "Busiest day",
                title: formatter.string(from: busiest.dayStart),
                detail: "\(busiest.wordCount) words across \(busiest.dictationCount) \(busiest.dictationCount == 1 ? "dictation" : "dictations")."))
        }

        if let leading = summary.byApp.first, leading.wordCount > 0 {
            let name = AppDisplayName.label(bundleID: leading.key, recordedName: leading.displayName)
                ?? leading.key ?? AppBreakdown.noAppLabel
            result.append(OverviewInsight(
                id: "destination", symbol: "arrow.up.forward.app.fill", eyebrow: "Top destination",
                title: name,
                detail: "\(leading.wordCount) words across \(leading.dictationCount) \(leading.dictationCount == 1 ? "dictation" : "dictations") this month."))
        }

        return result
    }

    /// A non-positive baseline is not a baseline. `StatsAggregator` already treats it as
    /// absent; passing it through unchanged would rely on that being true somewhere else.
    private func effectiveBaselineWPM() -> Double? {
        guard let wpm = baselineWPM(), wpm > 0 else { return nil }
        return wpm
    }

    /// Newest first, capped, with a **total order** so the result cannot depend on
    /// `sorted`'s unspecified stability.
    ///
    /// The tie-break is log position, descending: the log is append-only, so the later
    /// line is the later dictation. Two dictations can share a `startedAt` — the log
    /// stores whole-second dates, and a retry writes a record with the original's start
    /// time.
    static func recentRows(
        from records: [DictationRecord],
        limit: Int,
        resolveMode: (String) -> ModeBadge?
    ) -> [RecentDictation] {
        records.enumerated()
            .sorted { left, right in
                if left.element.startedAt != right.element.startedAt {
                    return left.element.startedAt > right.element.startedAt
                }
                return left.offset > right.offset
            }
            .prefix(limit)
            .map { RecentDictation(record: $0.element, mode: resolveMode($0.element.modeID)) }
    }

    // MARK: Copy

    /// Relative time for a row, e.g. "12 min ago". The list is a glance, and an absolute
    /// timestamp makes the reader do the subtraction.
    func relativeTime(of date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now())
    }
}
