import Foundation

// MARK: - Summary

/// Words and dictations attributed to one app or one mode.
///
/// `key` is optional because a dictation can happen with no frontmost app, and the
/// model refuses to name that bucket: "Unknown" is a UI decision, not a fact about
/// the data.
struct StatsGroup: Codable, Equatable, Sendable, Identifiable {
    /// `targetBundleID` or `modeID`; nil only for the no-target-app bucket.
    var key: String?
    /// The app's display name as it was at dictation time, when one was recorded.
    /// Modes carry no name here — resolving a mode ID to a title belongs to Modes.
    var displayName: String?
    var dictationCount: Int
    var wordCount: Int

    var id: String { key ?? "" }
}

/// One local calendar day of successful dictation. `dayStart` is midnight in the
/// calendar the summary was computed with — which is why the rollup cache records the
/// time zone it was built in and rebuilds when it changes.
struct StatsDay: Codable, Equatable, Sendable, Identifiable {
    var dayStart: Date
    var dictationCount: Int
    var wordCount: Int

    var id: Date { dayStart }
}

/// Everything the stats screen shows, derived from a window of records.
///
/// Two rules govern every field, and both exist because a dictation app that
/// flatters itself is worse than one that says nothing:
///
/// 1. **No invented numbers.** `timeSavedSeconds` is nil until the typing test has
///    been run. Rates over an empty window are 0, never NaN, and never a plausible
///    placeholder.
/// 2. **Word totals count only what reached the cursor.** Cancelled and failed
///    dictations are excluded from words, speaking time, WPM, streaks and the
///    per-app/per-mode groups — but they are counted in `recordCount`, in
///    `retryRate` and in `totalCostUSD`, because a retry that ended in failure is
///    the most important retry there is and Groq bills for it either way.
struct StatsSummary: Codable, Equatable, Sendable {

    // Volume
    /// Every record in the window, whatever its outcome.
    var recordCount: Int
    /// Records that reached the cursor — the ones behind every word total below.
    var dictationCount: Int
    var totalWords: Int
    var totalSpeakingSeconds: TimeInterval

    /// Mean of the PER-RECORD WPM values, as spec §11.2 defines it, not
    /// total words over total time. Per-record values are the ones the UI shows, so
    /// averaging them keeps the hero number and the row it came from consistent.
    var averageWordsPerMinute: Double

    /// Seconds saved against the typing baseline, or **nil when there is no
    /// baseline**. Nil is the whole point of the field: until the 60-second typing
    /// test has been run there is no honest number to show.
    var timeSavedSeconds: TimeInterval?

    /// Consecutive local days ending today — or ending yesterday while today is
    /// still in progress. See `StatsAggregator.streaks`.
    var currentStreakDays: Int
    var longestStreakDays: Int

    // Grouping, sorted by words descending so the UI needs no sort of its own.
    var byApp: [StatsGroup]
    var byMode: [StatsGroup]

    // Quality signals (spec §11.2)
    /// Fraction of records in the window with at least one retry.
    var retryRate: Double
    /// How much the mode changed the transcript, over successful records only: a
    /// failed record has no text, and its 0 would make the mode look faithful.
    var meanEditDistanceRawToFinal: Double
    /// Mean length of the recordings that actually captured audio, including ones
    /// the user then cancelled — how long you speak for is a fact about the
    /// microphone, not about whether the text landed.
    var meanRecordingSeconds: TimeInterval
    /// Mean time the user waited AFTER speaking, over successful dictations.
    var meanPipelineLatencySeconds: TimeInterval
    var totalCostUSD: Double

    /// Successful dictations whose text carries `TranscriptStitcher.failureMarker` —
    /// a segment was permanently lost even though the rest was inserted. These
    /// records are `.inserted`, so this marker is the only signal they exist.
    var partialFailureCount: Int

    /// Successful dictations bucketed by local day, ascending. Days with nothing in
    /// them are absent rather than zero-filled; a chart decides its own x-domain.
    var daily: [StatsDay]

    /// The zero of the type: what an empty window looks like.
    static let empty = StatsSummary(
        recordCount: 0,
        dictationCount: 0,
        totalWords: 0,
        totalSpeakingSeconds: 0,
        averageWordsPerMinute: 0,
        timeSavedSeconds: nil,
        currentStreakDays: 0,
        longestStreakDays: 0,
        byApp: [],
        byMode: [],
        retryRate: 0,
        meanEditDistanceRawToFinal: 0,
        meanRecordingSeconds: 0,
        meanPipelineLatencySeconds: 0,
        totalCostUSD: 0,
        partialFailureCount: 0,
        daily: [])
}

// MARK: - Totals

/// The additive part of a summary: everything that can be folded over records one at
/// a time, in any order, without knowing today's date or the typing baseline.
///
/// This split is what makes the rollup cache correct rather than merely fast. A
/// finished `StatsSummary` cannot be cached: `timeSavedSeconds` depends on a baseline
/// the user can re-measure at any time, and the streak decays at midnight with no
/// record changing. Both are derived from these totals on every read, so the cached
/// bytes never go quietly stale. Spec §11.1 asks for "aggregates" in `rollup.json`;
/// these are them.
struct StatsTotals: Codable, Equatable, Sendable {
    var recordCount = 0
    var dictationCount = 0
    var totalWords = 0

    /// Speaking time and post-speaking wait, over successful dictations only —
    /// the two quantities time-saved subtracts.
    var countedSpeakingSeconds: TimeInterval = 0
    var countedLatencySeconds: TimeInterval = 0

    /// Sum of the per-record WPM values and how many records contributed one.
    var wordsPerMinuteSum = 0
    var wordsPerMinuteSamples = 0

    var editDistanceSum: Double = 0
    var editDistanceSamples = 0

    var recordedSecondsSum: TimeInterval = 0
    var recordedSamples = 0

    var retriedRecordCount = 0
    var totalCostUSD: Double = 0
    var partialFailureCount = 0

    /// Canonically ordered so that a folded and a rebuilt set of totals compare
    /// equal, and so `rollup.json` diffs are readable.
    var days: [StatsDay] = []
    var byApp: [StatsGroup] = []
    var byMode: [StatsGroup] = []
}

// MARK: - Aggregator

/// Turns dictation records into the numbers on the stats screen.
///
/// Stateless and calendar-injected on purpose: streaks are consecutive LOCAL days, so
/// a hidden `Calendar.current` would make the same records mean different things on
/// two machines and make the tests pass or fail depending on where they ran.
enum StatsAggregator {

    /// Summarizes `records` — any window: all time, this week, one app.
    ///
    /// - Parameters:
    ///   - baselineWPM: the typing baseline, or nil when the typing test has not
    ///     been run. A non-positive value is treated as absent: it is not a baseline,
    ///     and dividing by it would report an infinite saving.
    ///   - calendar: the calendar (and therefore time zone) that defines a "day".
    ///   - now: today, for the streak that includes it.
    static func summarize(
        _ records: [DictationRecord],
        baselineWPM: Double?,
        calendar: Calendar,
        now: Date
    ) -> StatsSummary {
        summarize(
            totals: totals(records, calendar: calendar),
            baselineWPM: baselineWPM,
            calendar: calendar,
            now: now)
    }

    /// Derives the summary from already-folded totals. The rollup cache calls this on
    /// every read so a new baseline or a new day is reflected without re-scanning.
    static func summarize(
        totals: StatsTotals,
        baselineWPM: Double?,
        calendar: Calendar,
        now: Date
    ) -> StatsSummary {
        let streak = streaks(days: totals.days.map(\.dayStart), calendar: calendar, now: now)

        return StatsSummary(
            recordCount: totals.recordCount,
            dictationCount: totals.dictationCount,
            totalWords: totals.totalWords,
            totalSpeakingSeconds: totals.countedSpeakingSeconds,
            averageWordsPerMinute: mean(
                Double(totals.wordsPerMinuteSum), totals.wordsPerMinuteSamples),
            timeSavedSeconds: timeSavedSeconds(totals: totals, baselineWPM: baselineWPM),
            currentStreakDays: streak.current,
            longestStreakDays: streak.longest,
            byApp: totals.byApp,
            byMode: totals.byMode,
            retryRate: mean(Double(totals.retriedRecordCount), totals.recordCount),
            meanEditDistanceRawToFinal: mean(totals.editDistanceSum, totals.editDistanceSamples),
            meanRecordingSeconds: mean(totals.recordedSecondsSum, totals.recordedSamples),
            meanPipelineLatencySeconds: mean(
                totals.countedLatencySeconds, totals.dictationCount),
            totalCostUSD: totals.totalCostUSD,
            partialFailureCount: totals.partialFailureCount,
            daily: totals.days)
    }

    // MARK: - Folding

    static func totals(_ records: [DictationRecord], calendar: Calendar) -> StatsTotals {
        accumulate(into: StatsTotals(), records: records, calendar: calendar)
    }

    /// Folds `records` into `totals`. Every field is a sum or a count, so the result
    /// does not depend on the order records arrive in — which is what lets the cache
    /// append to yesterday's totals instead of rebuilding them.
    static func accumulate(
        into totals: StatsTotals,
        records: [DictationRecord],
        calendar: Calendar
    ) -> StatsTotals {
        var totals = totals

        // Dictionaries for the fold, arrays on the way out: an O(1) lookup per record
        // instead of a linear scan of a multi-year day series.
        var days = Dictionary(uniqueKeysWithValues: totals.days.map { ($0.dayStart, $0) })
        var apps = Dictionary(uniqueKeysWithValues: totals.byApp.map { (GroupKey($0.key), $0) })
        var modes = Dictionary(uniqueKeysWithValues: totals.byMode.map { (GroupKey($0.key), $0) })

        for record in records {
            totals.recordCount += 1

            // Quality signals span every outcome: a retry that ended in failure still
            // happened, and Groq billed for the audio either way.
            if record.retryCount > 0 { totals.retriedRecordCount += 1 }
            totals.totalCostUSD += record.totalTrackedCostUSD
            if record.speakingDuration > 0 {
                totals.recordedSecondsSum += record.speakingDuration
                totals.recordedSamples += 1
            }

            guard record.outcome == .inserted else { continue }

            totals.dictationCount += 1
            totals.totalWords += record.wordCount
            totals.countedSpeakingSeconds += record.speakingDuration
            totals.countedLatencySeconds += perceivedLatencySeconds(of: record)

            totals.editDistanceSum += record.editDistanceRawToFinal
            totals.editDistanceSamples += 1

            if record.speakingDuration > 0 {
                totals.wordsPerMinuteSum += DictationRecordDraft.wordsPerMinute(
                    words: record.wordCount, speakingDuration: record.speakingDuration)
                totals.wordsPerMinuteSamples += 1
            }

            if record.finalText.contains(TranscriptStitcher.failureMarker) {
                totals.partialFailureCount += 1
            }

            let dayStart = calendar.startOfDay(for: record.startedAt)
            var day = days[dayStart] ?? StatsDay(dayStart: dayStart, dictationCount: 0, wordCount: 0)
            day.dictationCount += 1
            day.wordCount += record.wordCount
            days[dayStart] = day

            add(record, to: &apps, key: record.targetBundleID, name: record.targetAppName)
            add(record, to: &modes, key: record.modeID, name: nil)
        }

        totals.days = days.values.sorted { $0.dayStart < $1.dayStart }
        totals.byApp = apps.values.sorted(by: groupOrder)
        totals.byMode = modes.values.sorted(by: groupOrder)
        return totals
    }

    // MARK: - Time saved

    /// Spec §11.2: `wordCount / baselineWPM − (speakingDuration + totalPipelineLatency)`,
    /// in seconds here rather than the spec's minutes.
    ///
    /// The latency term is `timings.totalMs − timings.captureMs`. `totalMs` is
    /// anchored at capture START (the pipeline writes `finishedAt − capture.startedAt`)
    /// and `captureMs` is the speaking duration, so the difference is exactly the wait
    /// the user sat through AFTER speaking. Using `totalMs` as if it were latency
    /// would subtract the speaking time twice and halve every saving.
    ///
    /// The result may be negative, and is left that way: a dictation slower than
    /// typing did not save time, and clamping it at zero would flatter the one number
    /// this feature exists to keep honest.
    private static func timeSavedSeconds(
        totals: StatsTotals,
        baselineWPM: Double?
    ) -> TimeInterval? {
        guard let baselineWPM, baselineWPM > 0 else { return nil }
        let typingSeconds = Double(totals.totalWords) / baselineWPM * 60
        return typingSeconds - totals.countedSpeakingSeconds - totals.countedLatencySeconds
    }

    /// Clamped at zero: a record written before `totalMs` was amended reads as
    /// negative latency, which would credit the user with time they never waited.
    private static func perceivedLatencySeconds(of record: DictationRecord) -> TimeInterval {
        Double(max(0, record.timings.totalMs - record.timings.captureMs)) / 1_000
    }

    // MARK: - Streaks

    /// Consecutive local days with at least one successful dictation.
    ///
    /// The current streak ends at today when today has one. When it does not, it ends
    /// at YESTERDAY: today is still in progress, and a streak that read 0 every
    /// morning until the first dictation would be a bug report, not a feature. Two
    /// missed days in a row is a break either way.
    ///
    /// Day steps go through `Calendar`, never through 86 400 seconds: the day a
    /// region springs forward is 23 hours long, and second arithmetic silently loses
    /// it.
    static func streaks(
        days: [Date],
        calendar: Calendar,
        now: Date
    ) -> (current: Int, longest: Int) {
        guard !days.isEmpty else { return (0, 0) }

        let sorted = days.sorted()
        let present = Set(sorted)

        var longest = 1
        var run = 1
        for index in 1..<sorted.count {
            if calendar.date(byAdding: .day, value: 1, to: sorted[index - 1]) == sorted[index] {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        var anchor: Date?
        if present.contains(today) {
            anchor = today
        } else if let yesterday, present.contains(yesterday) {
            anchor = yesterday
        }

        var current = 0
        var cursor = anchor
        while let day = cursor, present.contains(day) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }

        return (current, longest)
    }

    // MARK: - Helpers

    /// A rate over an empty sample is 0, not NaN. Every mean in the summary goes
    /// through here so no division by zero can reach the UI.
    private static func mean(_ sum: Double, _ count: Int) -> Double {
        count > 0 ? sum / Double(count) : 0
    }

    /// Dictionary key that can hold the nil group. `String?` is not `Hashable` in a
    /// way that survives being a dictionary key without this wrapper.
    private struct GroupKey: Hashable {
        var value: String?
        init(_ value: String?) { self.value = value }
    }

    private static func add(
        _ record: DictationRecord,
        to groups: inout [GroupKey: StatsGroup],
        key: String?,
        name: String?
    ) {
        let groupKey = GroupKey(key)
        var group = groups[groupKey]
            ?? StatsGroup(key: key, displayName: nil, dictationCount: 0, wordCount: 0)
        // First recorded name wins, so an app that was renamed between dictations
        // does not make the label flicker with folding order.
        if group.displayName == nil { group.displayName = name }
        group.dictationCount += 1
        group.wordCount += record.wordCount
        groups[groupKey] = group
    }

    /// Words descending, then count, then key — a total order, so the same set of
    /// groups always serializes and renders identically.
    private static func groupOrder(_ lhs: StatsGroup, _ rhs: StatsGroup) -> Bool {
        if lhs.wordCount != rhs.wordCount { return lhs.wordCount > rhs.wordCount }
        if lhs.dictationCount != rhs.dictationCount {
            return lhs.dictationCount > rhs.dictationCount
        }
        // nil (no target app) sorts last so it never leads the list.
        switch (lhs.key, rhs.key) {
        case let (left?, right?): return left < right
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return false
        }
    }
}
