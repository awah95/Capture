import XCTest
@testable import Captur

final class StatsRollupCacheTests: XCTestCase {

    private let berlin = StatsFixture.calendar("Europe/Berlin")
    private var now: Date { StatsFixture.date(berlin, 2026, 3, 7, 12) }

    private func makeCacheURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-rollup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("rollup.json")
    }

    /// What a full, uncached aggregation of the same records says. Every cache path
    /// is asserted against this: an incremental fold that disagrees with a rebuild is
    /// the only failure mode that matters here.
    private func expected(
        _ records: [DictationRecord],
        baselineWPM: Double? = 55,
        calendar: Calendar? = nil
    ) -> StatsSummary {
        StatsAggregator.summarize(
            records,
            baselineWPM: baselineWPM,
            calendar: calendar ?? berlin,
            now: now)
    }

    private func summary(
        _ cache: StatsRollupCache,
        _ records: [DictationRecord],
        baselineWPM: Double? = 55,
        calendar: Calendar? = nil,
        now overrideNow: Date? = nil
    ) -> StatsSummary {
        cache.summary(
            for: records,
            baselineWPM: baselineWPM,
            calendar: calendar ?? berlin,
            now: overrideNow ?? now)
    }

    // MARK: - Cold, incremental, reused

    func testFirstReadComputesEverythingAndWritesTheFile() throws {
        let url = try makeCacheURL()
        let records = StatsFixture.mixedRecords(calendar: berlin)
        let cache = StatsRollupCache(fileURL: url)

        XCTAssertEqual(summary(cache, records), expected(records))
        XCTAssertEqual(cache.lastRefresh, .full)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAppendedRecordsAreFoldedInIncrementally() throws {
        let all = StatsFixture.mixedRecords(calendar: berlin)
        let cache = StatsRollupCache(fileURL: try makeCacheURL())

        _ = summary(cache, Array(all.prefix(9)))
        XCTAssertEqual(cache.lastRefresh, .full)

        let incremental = summary(cache, all)
        XCTAssertEqual(cache.lastRefresh, .incremental)
        XCTAssertEqual(incremental, expected(all), "an incremental fold must equal a rebuild")
    }

    func testUnchangedLogReusesTheCachedTotals() throws {
        let records = StatsFixture.mixedRecords(calendar: berlin)
        let cache = StatsRollupCache(fileURL: try makeCacheURL())

        _ = summary(cache, records)
        let again = summary(cache, records)

        XCTAssertEqual(cache.lastRefresh, .reused)
        XCTAssertEqual(again, expected(records))
    }

    func testCachePersistsAcrossInstances() throws {
        let url = try makeCacheURL()
        let all = StatsFixture.mixedRecords(calendar: berlin)

        _ = summary(StatsRollupCache(fileURL: url), Array(all.prefix(6)))

        let second = StatsRollupCache(fileURL: url)
        let result = summary(second, all)
        XCTAssertEqual(second.lastRefresh, .incremental)
        XCTAssertEqual(result, expected(all))
    }

    // MARK: - Forced rebuilds

    /// A version bump means the stored numbers were produced by different arithmetic,
    /// so they are not evidence of anything. The planted totals are deliberately wrong:
    /// trusting them shows up as a wrong answer, not just a wrong refresh kind.
    func testVersionMismatchForcesAFullRecompute() throws {
        let url = try makeCacheURL()
        let records = StatsFixture.mixedRecords(calendar: berlin)
        let cache = StatsRollupCache(fileURL: url)

        var poisoned = StatsAggregator.totals(records, calendar: berlin)
        poisoned.totalWords += 100_000
        try cache.save(
            StatsRollupCache.Envelope(
                version: StatsRollupCache.version + 1,
                calendarIdentifier: "\(berlin.identifier)",
                timeZoneIdentifier: berlin.timeZone.identifier,
                recordCount: records.count,
                lastRecordID: records.last?.id,
                totals: poisoned))

        let result = summary(StatsRollupCache(fileURL: url), records)
        XCTAssertEqual(result, expected(records))
        XCTAssertEqual(result.totalWords, expected(records).totalWords)
    }

    func testVersionMismatchIsReportedAsAFullRefresh() throws {
        let url = try makeCacheURL()
        let records = StatsFixture.mixedRecords(calendar: berlin)
        let seeded = StatsRollupCache(fileURL: url)
        _ = summary(seeded, records)

        var envelope = try XCTUnwrap(seeded.loadEnvelope())
        envelope.version = StatsRollupCache.version + 1
        try seeded.save(envelope)

        let cache = StatsRollupCache(fileURL: url)
        _ = summary(cache, records)
        XCTAssertEqual(cache.lastRefresh, .full)
    }

    /// A shorter log means records were deleted or the file was rewritten, so the
    /// stored totals include words that no longer exist.
    func testADeletedRecordForcesAFullRecompute() throws {
        let url = try makeCacheURL()
        let all = StatsFixture.mixedRecords(calendar: berlin)
        let cache = StatsRollupCache(fileURL: url)
        _ = summary(cache, all)

        let trimmed = Array(all.dropLast(3))
        let result = summary(cache, trimmed)
        XCTAssertEqual(cache.lastRefresh, .full)
        XCTAssertEqual(result, expected(trimmed))
    }

    /// Same count, different tail: the log was rewritten in place (an audio purge
    /// amendment, a delete plus an append). The prefix is no longer trustworthy.
    func testARewrittenTailForcesAFullRecompute() throws {
        let url = try makeCacheURL()
        let all = StatsFixture.mixedRecords(calendar: berlin)
        let cache = StatsRollupCache(fileURL: url)
        _ = summary(cache, all)

        var swapped = all
        swapped[swapped.count - 1] = StatsFixture.record(
            startedAt: StatsFixture.date(berlin, 2026, 3, 6, 11), words: 500)
        let result = summary(cache, swapped)

        XCTAssertEqual(cache.lastRefresh, .full)
        XCTAssertEqual(result, expected(swapped))
    }

    /// Daily buckets are local-day anchored, so a cache built in one zone cannot be
    /// folded onto in another: the streak and the day series would be silently wrong.
    func testATimeZoneChangeForcesAFullRecompute() throws {
        let url = try makeCacheURL()
        let tokyo = StatsFixture.calendar("Asia/Tokyo")
        let records = StatsFixture.mixedRecords(calendar: berlin)
        let cache = StatsRollupCache(fileURL: url)

        _ = summary(cache, records)
        let inTokyo = summary(cache, records, calendar: tokyo, now: now)

        XCTAssertEqual(cache.lastRefresh, .full)
        XCTAssertEqual(inTokyo, expected(records, calendar: tokyo))
    }

    /// `rollup.json` is derived data, recomputable from the log in milliseconds, so a
    /// corrupt file is discarded rather than backed up — the opposite of the record
    /// log, where the bytes are the only copy of the truth.
    func testCorruptFileFallsBackToAFullRecompute() throws {
        let url = try makeCacheURL()
        try Data("{ this is not json".utf8).write(to: url)
        let records = StatsFixture.mixedRecords(calendar: berlin)

        let cache = StatsRollupCache(fileURL: url)
        let result = summary(cache, records)

        XCTAssertEqual(cache.lastRefresh, .full)
        XCTAssertEqual(result, expected(records))
    }

    func testEmptyLogProducesAZeroedSummary() throws {
        let cache = StatsRollupCache(fileURL: try makeCacheURL())
        XCTAssertEqual(summary(cache, [], baselineWPM: nil), StatsSummary.empty)
    }

    // MARK: - What the cache must not freeze

    /// The typing test is re-runnable, so a cached rollup must not bake a baseline
    /// into itself. Same cache, same records, three baselines, three answers.
    func testTimeSavedFollowsTheCurrentBaselineWithoutRebuilding() throws {
        let records = StatsFixture.mixedRecords(calendar: berlin)
        let cache = StatsRollupCache(fileURL: try makeCacheURL())

        let slowTypist = summary(cache, records, baselineWPM: 30).timeSavedSeconds
        let fastTypist = summary(cache, records, baselineWPM: 90).timeSavedSeconds
        let none = summary(cache, records, baselineWPM: nil).timeSavedSeconds

        XCTAssertEqual(cache.lastRefresh, .reused, "a new baseline is not a new scan")
        XCTAssertNotNil(slowTypist)
        XCTAssertNotNil(fastTypist)
        // The faster you type, the less dictation saves you.
        XCTAssertGreaterThan(slowTypist!, fastTypist!)
        XCTAssertNil(none, "no baseline is still nil, cached or not")
    }

    /// A streak decays at midnight even though no record changed, so `now` cannot be
    /// frozen into the cached numbers either.
    func testStreakFollowsTheCurrentDayWithoutRebuilding() throws {
        let records = [
            StatsFixture.record(startedAt: StatsFixture.date(berlin, 2026, 3, 6, 10)),
            StatsFixture.record(startedAt: StatsFixture.date(berlin, 2026, 3, 7, 10))
        ]
        let cache = StatsRollupCache(fileURL: try makeCacheURL())

        let onTheDay = summary(cache, records, now: StatsFixture.date(berlin, 2026, 3, 7, 20))
        let threeDaysLater = summary(
            cache, records, now: StatsFixture.date(berlin, 2026, 3, 10, 9))

        XCTAssertEqual(onTheDay.currentStreakDays, 2)
        XCTAssertEqual(threeDaysLater.currentStreakDays, 0)
        XCTAssertEqual(threeDaysLater.longestStreakDays, 2)
        XCTAssertEqual(cache.lastRefresh, .reused)
    }
}
