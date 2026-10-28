import Foundation
import Observation

// MARK: - Rows

/// One small labelled number on the stats page.
///
/// A value type rather than a formatted string in the view, so every figure on the screen
/// can be asserted by name in a test. `value` is already formatted: the rule this page is
/// built around is that a number reaches the screen only when something measured it, and
/// the decision about whether it did belongs here rather than in a `Text`.
struct StatsFigure: Identifiable, Equatable {
    let label: String
    let value: String
    var detail: String?

    var id: String { label }
}

struct UsageBreakdownRow: Identifiable, Equatable {
    let stage: DictationUsageStage
    let providerID: String
    let modelID: String
    let requestCount: Int
    let promptTokens: Int
    let completionTokens: Int
    let reasoningTokens: Int
    let costUSD: Decimal
    let unknownCostCount: Int
    let audioSeconds: TimeInterval
    let outputWordCount: Int
    let retryCount: Int
    let successCount: Int
    let failureCount: Int
    let transcriptionPaths: [DictationTranscriptionPath]
    let latencyP50Ms: Int?
    let latencyP95Ms: Int?

    var id: String { "\(stage.rawValue)/\(providerID)/\(modelID)" }
}

/// The typing baseline as the page shows it: the rate the aggregator actually divides by,
/// and the date it was measured — spec §11.2 stores the date so a stale baseline can be
/// spotted and re-run.
struct TypingBaselineSummary: Equatable {
    /// `TypingBaseline.netWordsPerMinute`, rounded. The accuracy-adjusted rate, which is
    /// the number `StatsAggregator` uses, not the gross one.
    let wordsPerMinute: Int
    let accuracy: Double
    let measuredAt: Date
}

// MARK: - Formatting

/// Every number-to-string decision on the stats page, in one place so a test can pin the
/// ones that are easy to get subtly wrong.
enum StatsFormat {

    /// Whole seconds under a minute, then minutes and seconds. Never fractions: these are
    /// means over a handful of samples and "18.4 s" claims a precision they do not have.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }

    /// Three decimal places under a dollar, two above it. A month of lightweight AI
    /// usage can be cents, and "$0.01" for eleven dollars of spend is the wrong rounding in
    /// the wrong direction.
    static func money(_ usd: Double) -> String {
        usd < 1
            ? String(format: "$%.3f", usd)
            : String(format: "$%.2f", usd)
    }

    static func rate(_ wordsPerMinute: Double) -> String {
        "\(Int(wordsPerMinute.rounded())) wpm"
    }

    static func count(_ value: Int) -> String { "\(value)" }

    static func days(_ value: Int) -> String {
        value == 1 ? "1 day" : "\(value) days"
    }

    /// Long enough to read as a date rather than as another figure.
    static func date(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("d MMM y")
        return formatter.string(from: date)
    }
}

// MARK: - View model

/// Everything behind `StatsView`, spec §10, §11.2 and §11.3.
///
/// Modelled on `HomeViewModel` and deliberately: every dependency is a closure or a value,
/// so the whole page is constructible in a test with no filesystem, no record log and no
/// typing baseline store. Nothing polls — `refresh()` runs when the pane appears, when the
/// window changes, and when the composition root says a dictation finished. A `Timer`
/// refreshing this would be a defect under spec §15, not a convenience.
///
/// Like Home, this reloads the whole log rather than caching it or diffing against the
/// previous read. Reading is milliseconds, and both of the clever alternatives are how a
/// stats screen starts showing yesterday's numbers.
@MainActor
@Observable
final class StatsViewModel {

    // MARK: Window

    /// The window the page covers. Rolling day counts rather than calendar periods: the
    /// question a stats page answers is "lately", and a calendar month reads as an empty
    /// page on the 1st.
    enum Window: String, CaseIterable, Identifiable, Sendable {
        case week
        case month
        case allTime

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: return "7 days"
            case .month: return "30 days"
            case .allTime: return "All time"
            }
        }

        /// How many days the window spans, or nil for all of them.
        var days: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .allTime: return nil
            }
        }
    }

    /// Spec §10.6: *"Stats, fewer than 3 dictations: 'A few more dictations and this gets
    /// interesting.'"* Fewer than three — at three the page is drawn.
    static let minimumDictations = 3

    /// A mode ID the record never carried. Named for what it is, in the same spirit as
    /// `AppBreakdown.noAppLabel`: the aggregator refuses to invent "Unknown" and so does
    /// this page.
    static let noModeLabel = "No mode recorded"

    // MARK: State

    private(set) var window: Window
    private(set) var summary: StatsSummary = .empty
    private(set) var buckets: [VolumeBucket] = []
    private(set) var appShares: [WordShare] = []
    private(set) var modeShares: [WordShare] = []
    private(set) var usageBreakdown: [UsageBreakdownRow] = []
    private(set) var baselineSummary: TypingBaselineSummary?
    /// Successful dictations in the WHOLE log, whatever window is selected. The empty
    /// state is a fact about the corpus, not about the last seven days — otherwise a quiet
    /// week hides a page built from two years of dictations.
    private(set) var totalDictationCount = 0
    /// True only when records were actually read. An unreadable log is not evidence that
    /// there are no dictations, so the empty state must not claim it is.
    private(set) var hasRecords = false
    private(set) var isLoading = false
    private(set) var loadFailure: String?

    /// The live typing test, or nil when it is not on screen. `StatsView` presents a sheet
    /// while this is non-nil, which is also what keeps the test's countdown task scoped to
    /// the view rather than to the app.
    private(set) var typingTest: TypingTestSession?

    // MARK: Dependencies

    private let loadRecords: () async throws -> [DictationRecord]
    private let readBaseline: () -> TypingBaseline?
    private let resolveMode: (String) -> ModeBadge?
    private let makeTypingTestSession: () -> TypingTestSession
    private let summarize: ([DictationRecord], Double?, Calendar, Date) -> StatsSummary
    let calendar: Calendar
    private let now: () -> Date

    /// Reads the app's own health log. Injected rather than reached for, so the section
    /// can be tested against fabricated sessions — including crashed ones, which are
    /// otherwise only observable by crashing.
    private let loadSessions: () async -> [SessionRecord]

    init(
        loadRecords: @escaping () async throws -> [DictationRecord],
        readBaseline: @escaping () -> TypingBaseline?,
        resolveMode: @escaping (String) -> ModeBadge? = { _ in nil },
        makeTypingTestSession: @escaping () -> TypingTestSession,
        window: Window = .month,
        summarize: @escaping ([DictationRecord], Double?, Calendar, Date) -> StatsSummary
            = { records, wpm, calendar, now in
                StatsAggregator.summarize(records, baselineWPM: wpm, calendar: calendar, now: now)
            },
        loadSessions: @escaping () async -> [SessionRecord] = { [] },
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.loadRecords = loadRecords
        self.readBaseline = readBaseline
        self.resolveMode = resolveMode
        self.makeTypingTestSession = makeTypingTestSession
        self.window = window
        self.summarize = summarize
        self.loadSessions = loadSessions
        self.calendar = calendar
        self.now = now
    }

    // MARK: Derived — performance and health

    /// Resource use, stability and the latency breakdown.
    ///
    /// Computed over **every** record and session, not the selected window, and the
    /// section says so. A p50 needs at least twenty samples (§15) and windowing a
    /// low-volume week would produce percentiles built on three dictations — which is an
    /// anecdote wearing a statistic's clothes.
    private(set) var health: HealthSummary = .empty

    // MARK: Derived — the hero

    /// Spec §11.2. The prompt state is reached whenever there is no honest figure — which
    /// includes a baseline of zero, because dividing by it would report an infinite
    /// saving.
    var hero: TimeSavedHero {
        guard let seconds = summary.timeSavedSeconds else { return .needsTypingTest }
        return .saved(seconds: seconds)
    }

    /// The figure, or **nil in the prompt state**. Nil rather than "0m" or "—": a
    /// formatter that can produce a number from no measurement is the bug this whole
    /// surface is arranged to avoid.
    var heroFigure: String? {
        guard case .saved(let seconds) = hero else { return nil }
        return TimeSavedFormat.short(seconds)
    }

    var heroDetail: String? {
        guard summary.dictationCount > 0 else { return nil }
        return "\(summary.totalWords) words over \(summary.dictationCount) dictations"
            + " · \(window.title.lowercased())"
    }

    /// Spec §10.6. A read failure is NOT this state: those are different facts and only
    /// one of them is good news.
    var showsTooFewDictations: Bool {
        loadFailure == nil && totalDictationCount < Self.minimumDictations
    }

    // MARK: Derived — the four groups

    /// Group one: speed and time saved. The hero is separate; these are the figures
    /// beside it.
    var speedFigures: [StatsFigure] {
        var figures: [StatsFigure] = [
            StatsFigure(label: "Speaking", value: StatsFormat.rate(summary.averageWordsPerMinute),
                        detail: "mean over timed successful dictations"),
        ]

        if let baselineSummary {
            figures.append(StatsFigure(
                label: "Typing",
                value: StatsFormat.rate(Double(baselineSummary.wordsPerMinute)),
                detail: "measured \(StatsFormat.date(baselineSummary.measuredAt, calendar: calendar))"))
        }

        figures.append(contentsOf: [
            StatsFigure(label: "Words", value: StatsFormat.count(summary.totalWords)),
            StatsFigure(label: "Dictations", value: StatsFormat.count(summary.dictationCount)),
            StatsFigure(label: "Speaking time",
                        value: StatsFormat.duration(summary.totalSpeakingSeconds)),
            StatsFigure(label: "Streak", value: StatsFormat.days(summary.currentStreakDays),
                        detail: "longest \(StatsFormat.days(summary.longestStreakDays))"),
        ])
        return figures
    }

    /// Group four: quality signals, spec §11.2.
    ///
    /// **Withheld entirely when the window holds no records.** Every one of these is a
    /// mean or a rate, and zero out of zero printed as "0 %" is a confident claim about
    /// nothing. The aggregator already refuses to produce NaN; this refuses to produce a
    /// number nobody measured.
    var qualitySignals: [StatsFigure] {
        guard summary.recordCount > 0 else { return [] }

        let unknownCosts = usageBreakdown.reduce(0) { $0 + $1.unknownCostCount }
        let spendValue = (unknownCosts > 0 ? "At least " : "")
            + StatsFormat.money(summary.totalCostUSD)
        var signals = [
            StatsFigure(label: "Retry rate",
                        value: AppBreakdownChart.percent(summary.retryRate),
                        detail: "of \(summary.recordCount) records"),
            StatsFigure(label: "Words the mode changed",
                        value: AppBreakdownChart.percent(summary.meanEditDistanceRawToFinal),
                        detail: "mean edit distance, raw to final"),
            StatsFigure(label: "Mean recording",
                        value: StatsFormat.duration(summary.meanRecordingSeconds)),
            StatsFigure(label: "Mean wait after speaking",
                        value: StatsFormat.duration(summary.meanPipelineLatencySeconds)),
            StatsFigure(
                label: "AI spend",
                value: spendValue,
                detail: unknownCosts > 0
                    ? "\(unknownCosts) request\(unknownCosts == 1 ? "" : "s") with unknown cost"
                    : nil),
        ]

        // Shown even at zero: it is a count of a real event, not a rate over an empty
        // sample, and a user looking for it should find it rather than wonder.
        signals.append(StatsFigure(
            label: "Partial failures",
            value: StatsFormat.count(summary.partialFailureCount),
            detail: summary.partialFailureCount > 0 ? "audio lost mid-dictation" : nil))

        return signals
    }

    /// What one bar of the volume chart covers, for its caption.
    var bucketUnit: String {
        switch VolumeSeries.bucket(spanningDays: chartSpanDays) {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        }
    }

    private var chartSpanDays: Int {
        guard let interval = chartInterval else { return 1 }
        return max(1, calendar.dateComponents(
            [.day], from: interval.start, to: interval.end).day ?? 1)
    }

    private var chartInterval: DateInterval?

    // MARK: Loading

    /// Re-reads the log and recomputes the whole page.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let records: [DictationRecord]
        do {
            records = try await loadRecords()
        } catch {
            // The previous page is left alone. A transient read failure should not blank a
            // screen the user is looking at, and it must not be reported as "no
            // dictations" either.
            loadFailure = error.localizedDescription
            return
        }

        loadFailure = nil
        hasRecords = !records.isEmpty
        totalDictationCount = records.filter { $0.outcome == .inserted }.count
        recompute(records)
        health = HealthAggregator.summarize(sessions: await loadSessions(), records: records)
    }

    /// Changes the window and recomputes. Async because it re-reads: caching the records
    /// to make this instant is the same trade `HomeViewModel` declined, for the same
    /// reason.
    func select(_ window: Window) async {
        guard window != self.window else { return }
        self.window = window
        await refresh()
    }

    private func recompute(_ records: [DictationRecord]) {
        let today = now()
        let interval = Self.window(window, calendar: calendar, now: today)
        let scoped = interval.map { Self.records(records, in: $0) } ?? records

        let baseline = readBaseline()
        summary = summarize(scoped, Self.effectiveBaselineWPM(baseline), calendar, today)
        baselineSummary = Self.makeBaselineSummary(baseline)

        appShares = AppBreakdown.shares(from: summary.byApp)
        modeShares = Self.modeShares(from: summary.byMode, resolveMode: resolveMode)
        usageBreakdown = Self.usageBreakdown(from: scoped)

        chartInterval = interval
            ?? Self.spanOfRecordedDays(summary.daily, calendar: calendar, now: today)
        buckets = chartInterval.map {
            VolumeSeries.buckets(in: $0, calendar: calendar, from: summary.daily)
        } ?? []
    }

    // MARK: The typing test seam

    /// Opens the test. `HomeActions.startTypingTest` points here too — see
    /// `docs/wiring/task26-wiring.md`.
    func startTypingTest() {
        typingTest = makeTypingTestSession()
    }

    /// Closes it and reloads, so a baseline measured just now turns the hero from the
    /// prompt into a figure without the window being reopened. Abandoning saves nothing,
    /// so the reload is a no-op in that case rather than a special path.
    func endTypingTest() async {
        typingTest = nil
        await refresh()
    }

    // MARK: - Pure helpers

    /// The window as a **half-open** interval, or nil for all time.
    ///
    /// Half-open deliberately: `DateInterval.contains` includes its end, so a record
    /// stamped exactly midnight would fall in two windows. The end is the start of
    /// tomorrow, so today counts in full however late it is.
    static func window(_ window: Window, calendar: Calendar, now: Date) -> DateInterval? {
        guard let days = window.days else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today)
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    static func records(
        _ records: [DictationRecord],
        in window: DateInterval
    ) -> [DictationRecord] {
        records.filter { $0.startedAt >= window.start && $0.startedAt < window.end }
    }

    static func usageBreakdown(from records: [DictationRecord]) -> [UsageBreakdownRow] {
        struct Key: Hashable {
            let stage: DictationUsageStage
            let providerID: String
            let modelID: String
        }
        struct Total {
            var requests = 0
            var prompt = 0
            var completion = 0
            var reasoning = 0
            var cost = Decimal.zero
            var unknown = 0
            var audioSeconds: TimeInterval = 0
            var outputWords = 0
            var retries = 0
            var successes = 0
            var failures = 0
            var paths: Set<DictationTranscriptionPath> = []
            var latencies: [Int] = []
        }

        var totals: [Key: Total] = [:]
        for record in records {
            let entries = record.usageEntries ?? []
            for entry in entries {
                let key = Key(stage: entry.stage,
                              providerID: entry.providerID,
                              modelID: entry.actualModelID ?? entry.requestedModelID)
                var total = totals[key] ?? Total()
                total.requests += 1
                total.prompt += entry.promptTokens ?? 0
                total.completion += entry.completionTokens ?? 0
                total.reasoning += entry.reasoningTokens ?? 0
                if let cost = entry.costUSD { total.cost += cost } else { total.unknown += 1 }
                total.audioSeconds += entry.audioSeconds ?? 0
                total.outputWords += entry.outputWordCount ?? 0
                if entry.isRetry == true { total.retries += 1 }
                switch entry.outcome {
                case .succeeded: total.successes += 1
                case .failed, .cancelled: total.failures += 1
                case nil: break
                }
                if let path = entry.transcriptionPath { total.paths.insert(path) }
                if let latency = entry.latencyMs { total.latencies.append(latency) }
                totals[key] = total
            }

            // Structured refinement receipts can exist on records created before
            // transcription receipts were introduced. Test for the stage itself,
            // not merely whether the usage array exists (an empty array is common).
            guard !entries.contains(where: { $0.stage == .transcription }),
                  record.speakingDuration > 0 || record.rawWordCount > 0
            else { continue }

            let isStandalonePaidLegacy = entries.isEmpty && record.estimatedCostUSD > 0
            let key = Key(
                stage: .transcription,
                providerID: isStandalonePaidLegacy
                    ? RefinementProviderID.groq.rawValue : "legacy",
                modelID: isStandalonePaidLegacy ? "Legacy estimate" : "Unattributed")
            var total = totals[key] ?? Total()
            total.requests += 1
            if isStandalonePaidLegacy { total.cost += Decimal(record.estimatedCostUSD) }
            total.audioSeconds += record.speakingDuration
            total.outputWords += record.rawWordCount
            if record.outcome == .inserted { total.successes += 1 } else { total.failures += 1 }
            totals[key] = total
        }

        return totals.map { key, total in
            UsageBreakdownRow(
                stage: key.stage,
                providerID: key.providerID,
                modelID: key.modelID,
                requestCount: total.requests,
                promptTokens: total.prompt,
                completionTokens: total.completion,
                reasoningTokens: total.reasoning,
                costUSD: total.cost,
                unknownCostCount: total.unknown,
                audioSeconds: total.audioSeconds,
                outputWordCount: total.outputWords,
                retryCount: total.retries,
                successCount: total.successes,
                failureCount: total.failures,
                transcriptionPaths: total.paths.sorted { $0.rawValue < $1.rawValue },
                latencyP50Ms: usagePercentile(total.latencies, 0.5),
                latencyP95Ms: usagePercentile(total.latencies, 0.95))
        }.sorted {
            if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
            return $0.id < $1.id
        }
    }

    private static func usagePercentile(_ values: [Int], _ percentile: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }

    /// The all-time chart domain: the first day with a dictation in it, through today.
    /// Nil when nothing has been recorded — an axis over no data is not an empty chart, it
    /// is a chart of an invented range.
    static func spanOfRecordedDays(
        _ daily: [StatsDay],
        calendar: Calendar,
        now: Date
    ) -> DateInterval? {
        guard let first = daily.first?.dayStart else { return nil }
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              end > first
        else { return nil }
        return DateInterval(start: first, end: end)
    }

    /// A non-positive baseline is not a baseline. `StatsAggregator` already treats it as
    /// absent; passing it through unchanged would rely on that being true somewhere else.
    static func effectiveBaselineWPM(_ baseline: TypingBaseline?) -> Double? {
        guard let wpm = baseline?.netWordsPerMinute, wpm > 0 else { return nil }
        return wpm
    }

    static func makeBaselineSummary(_ baseline: TypingBaseline?) -> TypingBaselineSummary? {
        guard let baseline, baseline.netWordsPerMinute > 0 else { return nil }
        return TypingBaselineSummary(
            wordsPerMinute: Int(baseline.netWordsPerMinute.rounded()),
            accuracy: baseline.accuracy,
            measuredAt: baseline.measuredAt)
    }

    /// Per-mode shares, reusing `AppBreakdown`'s top-few-plus-Other arithmetic and
    /// replacing only the labels — modes are named by the mode store, not by the record.
    static func modeShares(
        from groups: [StatsGroup],
        resolveMode: (String) -> ModeBadge?
    ) -> [WordShare] {
        AppBreakdown.shares(from: groups).map { share in
            guard !share.isOther else { return share }
            return WordShare(
                key: share.key,
                label: modeLabel(share.key, resolveMode: resolveMode),
                wordCount: share.wordCount,
                dictationCount: share.dictationCount,
                fraction: share.fraction,
                isOther: false)
        }
    }

    /// The mode's name if it still exists, its ID if it does not, and only then a name of
    /// our own. Falling straight to "Unknown" would throw away the one identifier that
    /// lets someone work out which mode it was — the same ladder `AppBreakdown.label(for:)`
    /// climbs for apps.
    static func modeLabel(_ key: String?, resolveMode: (String) -> ModeBadge?) -> String {
        guard let key, !key.isEmpty else { return noModeLabel }
        if let name = resolveMode(key)?.name, !name.isEmpty { return name }
        return key
    }
}

// MARK: - Performance and health, as the page renders it

extension StatsViewModel {

    /// Resource use, against spec §15's budgets.
    ///
    /// Every figure carries whether it is inside its budget, because a megabyte count on
    /// its own asks the reader to remember a number from a document they have not read.
    var resourceFigures: [StatsFigure] {
        var figures: [StatsFigure] = []

        if let idle = health.idleFootprintBytes {
            figures.append(StatsFigure(
                label: "Idle memory",
                value: Self.megabytes(idle),
                detail: Self.verdict(idle <= HealthSummary.Budget.idleFootprintBytes,
                                     budget: "60 MB")))
        }
        if let peak = health.peakFootprintBytes {
            figures.append(StatsFigure(
                label: "Peak memory",
                value: Self.megabytes(peak),
                detail: "Highest reading at any sampled moment."))
        }
        if let cpu = health.cpuSecondsPerDictation {
            figures.append(StatsFigure(
                label: "CPU per dictation",
                value: String(format: "%.2f s", cpu),
                detail: "Processor time burned from arming to inserted."))
        }
        if let launch = health.launchMs {
            figures.append(StatsFigure(
                label: "Cold launch",
                value: "\(launch) ms",
                detail: Self.verdict(launch <= HealthSummary.Budget.launchMs,
                                     budget: "400 ms")))
        }
        return figures
    }

    /// Stability. Deliberately reports the count of unexpected endings even when macOS
    /// wrote no crash report — being force-quit and faulting are different events, but
    /// both mean the app did not shut itself down, and hiding the ones without a report
    /// would undercount.
    var stabilityFigures: [StatsFigure] {
        guard health.sessionCount > 0 else { return [] }
        let clean = Double(health.cleanExitCount) / Double(health.sessionCount) * 100
        return [
            StatsFigure(label: "Runs recorded",
                        value: "\(health.sessionCount)",
                        detail: "Completed launches of Captur."),
            StatsFigure(label: "Clean shutdowns",
                        value: String(format: "%.0f%%", clean),
                        detail: "\(health.cleanExitCount) of \(health.sessionCount)."),
            StatsFigure(label: "Unexpected endings",
                        value: "\(health.unexpectedExitCount)",
                        detail: health.unexpectedExitCount == 0
                            ? "No crashes or force-quits recorded."
                            : "Crashed or was force-quit.")
        ]
    }

    /// Perceived latency against the two §15 budgets, which differ by mode because Clean
    /// adds a second round trip.
    var latencyFigures: [StatsFigure] {
        var figures: [StatsFigure] = []
        if let p50 = health.perceivedP50Ms {
            figures.append(StatsFigure(
                label: "Perceived p50",
                value: "\(p50) ms",
                detail: "Key release to text on screen."))
        }
        if let p95 = health.perceivedP95Ms {
            figures.append(StatsFigure(label: "Perceived p95", value: "\(p95) ms",
                                       detail: "The slow tail, not the typical case."))
        }
        if let verbatim = health.verbatimP50Ms {
            figures.append(StatsFigure(
                label: "Verbatim p50",
                value: "\(verbatim) ms",
                detail: Self.verdict(verbatim <= HealthSummary.Budget.verbatimPerceivedMs,
                                     budget: "800 ms")))
        }
        if let clean = health.cleanP50Ms {
            figures.append(StatsFigure(
                label: "Clean p50",
                value: "\(clean) ms",
                detail: Self.verdict(clean <= HealthSummary.Budget.cleanPerceivedMs,
                                     budget: "1,300 ms")))
        }
        return figures
    }

    /// Said out loud when the percentiles rest on too little. §15: "A p50 requires
    /// samples… at least 20. One timed dictation is an anecdote, not a measurement."
    var latencyCaveat: String? {
        guard health.latencySampleCount > 0 else {
            return "No dictations carry a stage breakdown yet. Timings are recorded from "
                + "the first dictation after this version was installed."
        }
        guard health.latencySampleCount < HealthSummary.Budget.minimumLatencySamples else {
            return nil
        }
        return "Based on \(health.latencySampleCount) "
            + "dictation\(health.latencySampleCount == 1 ? "" : "s"). "
            + "Treat these as indicative until there are "
            + "\(HealthSummary.Budget.minimumLatencySamples)."
    }

    static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    /// "Within budget" or "over budget", never a bare tick. The number it is being judged
    /// against is named, so the verdict can be disagreed with.
    static func verdict(_ withinBudget: Bool, budget: String) -> String {
        withinBudget ? "Within the \(budget) budget." : "Over the \(budget) budget."
    }

    /// Crash rows, newest first, already redacted by `CrashReportReader`.
    var crashRows: [CrashSummary] { health.crashes }
}
