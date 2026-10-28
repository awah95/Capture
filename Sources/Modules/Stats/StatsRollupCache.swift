import Foundation
import os

/// Caches the additive part of the stats rollup in `rollup.json` so opening the stats
/// screen does not re-fold the whole record log every time.
///
/// **What is cached, and what deliberately is not.** The file holds `StatsTotals` —
/// sums and counts — plus the identity of the log prefix they were folded from. It
/// does NOT hold a finished `StatsSummary`, even though that is what the screen shows:
/// `timeSavedSeconds` depends on a typing baseline the user can re-measure at any
/// time, and the streak decays at midnight with no record changing. Freezing either
/// into the file would make it quietly wrong rather than merely stale, so both are
/// re-derived on every read (spec §11.1 asks for cached "aggregates", which is exactly
/// the additive half).
///
/// **When the cache is trusted.** The log is append-only, so cached totals are valid
/// for a prefix of it. The stored `recordCount` and `lastRecordID` identify that
/// prefix; anything else — a shorter log, a different record at the end, a version
/// bump, a different time zone — means the prefix is not a prefix any more and the
/// totals are rebuilt from scratch.
///
/// **Corruption.** Unlike `DictationRecordLog`, a damaged `rollup.json` is discarded
/// without a backup. It is derived data: every byte can be recomputed from the log in
/// milliseconds, so keeping a forensic copy of a broken cache would be clutter, not
/// insurance.
final class StatsRollupCache {

    /// Bump whenever the arithmetic in `StatsAggregator` changes shape. Stored totals
    /// from a different version are not evidence of anything and are never merged.
    static let version = 1

    /// How the last `summary(for:...)` call got its answer. Read by tests, and useful
    /// in diagnostics: a cache that reports `.full` on every read is not working.
    enum Refresh: String, Codable, Equatable, Sendable {
        /// Nothing changed; the cached totals were used as they stood.
        case reused
        /// New records were folded onto the cached totals.
        case incremental
        /// The cache was absent, unreadable, or no longer described this log.
        case full
    }

    /// `rollup.json`. `totals` is the payload; every other field exists to decide
    /// whether the payload may be trusted.
    struct Envelope: Codable, Equatable {
        var version: Int
        /// Calendar identifier and time zone the day buckets were built in. Local-day
        /// buckets computed in Tokyo are wrong in New York, and travelling is not a
        /// reason to show a wrong streak.
        var calendarIdentifier: String
        var timeZoneIdentifier: String
        /// Number of records folded in, and the id of the last of them — together,
        /// the identity of the log prefix these totals describe.
        var recordCount: Int
        var lastRecordID: UUID?
        var totals: StatsTotals
    }

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.awah.captur", category: "stats")

    private var envelope: Envelope?
    private(set) var lastRefresh: Refresh?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Reads

    /// The summary for `records`, folding in only what the cache has not already seen.
    ///
    /// `records` is the log in file order (`DictationRecordLog.all()`). Passing a
    /// filtered window would poison the cache with totals that do not describe the log,
    /// so windowed views should summarize through `StatsAggregator` directly.
    func summary(
        for records: [DictationRecord],
        baselineWPM: Double?,
        calendar: Calendar,
        now: Date
    ) -> StatsSummary {
        let totals = refreshedTotals(for: records, calendar: calendar)
        return StatsAggregator.summarize(
            totals: totals, baselineWPM: baselineWPM, calendar: calendar, now: now)
    }

    private func refreshedTotals(
        for records: [DictationRecord],
        calendar: Calendar
    ) -> StatsTotals {
        let cached = envelope ?? loadEnvelope()

        if let cached, isUsable(cached, for: records, calendar: calendar) {
            if cached.recordCount == records.count {
                lastRefresh = .reused
                envelope = cached
                return cached.totals
            }
            let appended = Array(records[cached.recordCount...])
            let totals = StatsAggregator.accumulate(
                into: cached.totals, records: appended, calendar: calendar)
            lastRefresh = .incremental
            store(totals, for: records, calendar: calendar)
            return totals
        }

        let totals = StatsAggregator.totals(records, calendar: calendar)
        lastRefresh = .full
        store(totals, for: records, calendar: calendar)
        return totals
    }

    /// True when `cached` describes a prefix of `records` computed by this version of
    /// the arithmetic in this time zone.
    private func isUsable(
        _ cached: Envelope,
        for records: [DictationRecord],
        calendar: Calendar
    ) -> Bool {
        guard cached.version == Self.version else { return false }
        guard cached.calendarIdentifier == Self.identifier(of: calendar),
              cached.timeZoneIdentifier == calendar.timeZone.identifier
        else { return false }
        guard cached.recordCount <= records.count else { return false }

        // An empty prefix is trivially a prefix of anything: folding every record onto
        // zeroed totals is the same arithmetic as a rebuild.
        guard cached.recordCount > 0 else { return true }

        // The record at the end of the cached prefix must still be that record. A
        // rewrite (an audio purge, a delete) can leave the count unchanged while the
        // contents move, and folding onto that would double-count or lose words.
        return cached.lastRecordID == records[cached.recordCount - 1].id
    }

    // MARK: - Persistence

    /// The stored envelope, or nil when there is none, it cannot be read, or it does
    /// not decode. All three are the same situation: recompute.
    func loadEnvelope() -> Envelope? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let envelope = try Self.decoder.decode(Envelope.self, from: data)
            self.envelope = envelope
            return envelope
        } catch {
            logger.info(
                "Discarding unreadable stats rollup: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Writes the envelope atomically. A failed write is logged and otherwise ignored:
    /// the numbers on screen are already correct, and the only cost is that the next
    /// read recomputes them.
    func save(_ envelope: Envelope) throws {
        self.envelope = envelope
        let data = try Self.encoder.encode(envelope)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func store(
        _ totals: StatsTotals,
        for records: [DictationRecord],
        calendar: Calendar
    ) {
        let envelope = Envelope(
            version: Self.version,
            calendarIdentifier: Self.identifier(of: calendar),
            timeZoneIdentifier: calendar.timeZone.identifier,
            recordCount: records.count,
            lastRecordID: records.last?.id,
            totals: totals)
        do {
            try save(envelope)
        } catch {
            self.envelope = envelope
            logger.error(
                "Failed to write stats rollup: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `Calendar.Identifier` is not `RawRepresentable`, so its description is the
    /// portable form. It only has to be comparable to itself.
    private static func identifier(of calendar: Calendar) -> String {
        "\(calendar.identifier)"
    }

    /// Dates as epoch seconds, matching `DictationRecordLog`: an exact round trip for
    /// the day-boundary math the day buckets are made of.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
