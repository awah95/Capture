import XCTest
@testable import Captur

// MARK: - Doubles

/// In-memory `DictationRecordLogging` for the retention tests.
///
/// Deliberately not the pipeline's `FakeRecordLog`: what the sweep has to prove is a
/// different set of facts — which ids were *attempted*, how many times, and what
/// happens when the log cannot be read or cannot be amended. Deleting audio is
/// irreversible, so "was this record touched twice" has to be observable.
private final class RetentionFakeRecordLog: DictationRecordLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [DictationRecord]
    private var _updateAttempts: [UUID] = []

    /// Thrown by `all()`. A log the sweep cannot read must never be mistaken for a log
    /// with nothing in it — that reads as "0 bytes used, nothing to purge" and is a
    /// silent lie in both directions.
    var readError: Error?
    /// Thrown by `update`, to exercise the file-deleted-but-record-not-amended window.
    var updateError: Error?

    init(_ records: [DictationRecord] = []) { _records = records }

    var records: [DictationRecord] { lock.withLock { _records } }
    /// Every id `update` was called for, including ones that then threw.
    var updateAttempts: [UUID] { lock.withLock { _updateAttempts } }

    func append(_ record: DictationRecord) async throws {
        lock.withLock { _records.append(record) }
    }

    func all() async throws -> [DictationRecord] {
        await Task.yield()
        if let readError { throw readError }
        return lock.withLock { _records }
    }

    func record(id: UUID) async throws -> DictationRecord? {
        lock.withLock { _records.first { $0.id == id } }
    }

    func update(id: UUID, mutate: (inout DictationRecord) -> Void) async throws {
        await Task.yield()
        lock.withLock { _updateAttempts.append(id) }
        if let updateError { throw updateError }
        lock.withLock {
            guard let index = _records.firstIndex(where: { $0.id == id }) else { return }
            mutate(&_records[index])
        }
    }
}

/// Records every removal attempt and can be made to fail for named files. A throwing
/// removal means "the file is still on disk", which is the case the sweep's
/// failure policy turns on.
private final class FakeRemover: FileRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts: [URL] = []

    /// File names whose removal throws, as a permissions or I/O failure would.
    var failingNames: Set<String> = []

    var attempts: [URL] { lock.withLock { _attempts } }
    var attemptedNames: [String] { attempts.map(\.lastPathComponent) }

    func removeItem(at url: URL) throws {
        lock.withLock { _attempts.append(url) }
        if failingNames.contains(url.lastPathComponent) {
            throw FakeFailure.boom("removal refused for \(url.lastPathComponent)")
        }
    }
}

/// A `DailyScheduling` that holds the scheduled work instead of arming a real
/// `DispatchSourceTimer`. No test in this file creates a real timer: the production
/// one is armed once, 24 hours out, and a test that could observe it firing would
/// have to wait a day or lie about the clock.
private final class FakeDailyScheduler: DailyScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _work: (@Sendable () async -> Void)?
    private var _scheduleCount = 0
    private var _cancelCount = 0

    var scheduleCount: Int { lock.withLock { _scheduleCount } }
    var cancelCount: Int { lock.withLock { _cancelCount } }
    var isArmed: Bool { lock.withLock { _work != nil } }

    func scheduleDaily(_ work: @escaping @Sendable () async -> Void) {
        lock.withLock {
            _scheduleCount += 1
            _work = work
        }
    }

    func cancel() {
        lock.withLock {
            _cancelCount += 1
            _work = nil
        }
    }

    /// Run whatever the unit scheduled, exactly as a timer tick would — and *await* it,
    /// so a test never polls and never sleeps for a day.
    func fire() async {
        guard let work = lock.withLock({ _work }) else { return }
        await work()
    }
}

/// A clock the test moves by hand. `now` is a parameter everywhere in this module
/// precisely so that "a day later" is an assignment rather than a wait.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ now: Date) { _now = now }

    var now: Date { lock.withLock { _now } }

    func advance(by interval: TimeInterval) {
        lock.withLock { _now = _now.addingTimeInterval(interval) }
    }
}

// MARK: - Tests

final class RetentionSweeperTests: XCTestCase {
    // MARK: - Fixtures

    /// One exact day. The sweep measures age in 24-hour intervals, not calendar days —
    /// see `RetentionPolicy.maxAudioAge` for why — so the fixtures do the same.
    private let day: TimeInterval = 86_400

    /// A fixed "now". Whole-second epoch dates keep the record log's
    /// `.secondsSince1970` round trip exact, matching `DictationRecordLogTests`.
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * day)
    }

    private func record(
        id: UUID = UUID(),
        startedAt: Date? = nil,
        audioFileName: String? = "session-1.flac",
        audioBytes: Int = 4_096
    ) -> DictationRecord {
        DictationRecord(
            id: id,
            startedAt: startedAt ?? now,
            speakingDuration: 12.5,
            rawText: "raw text here",
            finalText: "final text here",
            modeID: "email",
            targetBundleID: "com.apple.mail",
            targetAppName: "Mail",
            wordCount: 3,
            rawWordCount: 3,
            segmentCount: 2,
            timings: Timings(
                captureMs: 10,
                convertMs: 20,
                uploadMs: 30,
                whisperMs: 40,
                llmMs: 50,
                insertMs: 60,
                totalMs: 210
            ),
            insertionOutcome: "insertedDirect",
            retryCount: 0,
            editDistanceRawToFinal: 0.25,
            audioFileName: audioFileName,
            audioBytes: audioBytes,
            estimatedCostUSD: 0.0031,
            vocabularyTermsSent: 7,
            voiceProcessingActive: true,
            outcome: .inserted
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-retention-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Assembles a runner over in-memory doubles. `audioDirectory` is a path that is
    /// never written to unless a test asks for real files, and is never Application
    /// Support.
    private func makeRunner(
        records: RetentionFakeRecordLog,
        remover: FileRemoving,
        scheduler: DailyScheduling,
        policy: RetentionPolicy,
        directory: URL? = nil,
        clock: TestClock? = nil
    ) -> RetentionSweepRunner {
        let clock = clock ?? TestClock(now)
        return RetentionSweepRunner(
            records: records,
            audioDirectory: directory ?? URL(fileURLWithPath: "/captur-tests-never-written/audio"),
            remover: remover,
            scheduler: scheduler,
            policy: { policy },
            now: { clock.now }
        )
    }

    // MARK: - Policy

    /// Spec §16: 30 days is the shipped default. A change here changes what the app
    /// deletes for every user who never opened Settings.
    func testTheDefaultPolicyIsThirtyDays() {
        XCTAssertEqual(RetentionPolicy.default, .thirtyDays)
        XCTAssertEqual(RetentionPolicy.default.maxAudioAge, 30 * day)
    }

    /// The raw values are the persisted form. Renaming one silently resets the user's
    /// choice back to the default on next launch, so they are pinned here.
    func testRawValuesArePinnedBecauseTheyArePersisted() {
        XCTAssertEqual(
            RetentionPolicy.allCases.map(\.rawValue),
            ["sevenDays", "thirtyDays", "ninetyDays", "forever", "never"]
        )
    }

    func testForeverAndNeverHaveNoAgeThreshold() {
        XCTAssertNil(RetentionPolicy.forever.maxAudioAge)
        XCTAssertNil(RetentionPolicy.never.maxAudioAge)
        XCTAssertEqual(RetentionPolicy.sevenDays.maxAudioAge, 7 * day)
        XCTAssertEqual(RetentionPolicy.ninetyDays.maxAudioAge, 90 * day)
    }

    // MARK: - expiredAudio: the age thresholds

    func testThirtyDaysExpiresA31DayOldRecordAndSparesA29DayOldOne() {
        let old = record(startedAt: daysAgo(31))
        let young = record(startedAt: daysAgo(29))

        let expired = RetentionSweeper.expiredAudio(
            in: [old, young], policy: .thirtyDays, now: now)

        XCTAssertEqual(expired, [old.id])
    }

    /// **Boundary choice: exactly 30 days old is SPARED.** The promise is "audio is
    /// kept for 30 days"; at the 30-day mark the last day of that promise has only
    /// just elapsed, and deletion cannot be undone, so the tie goes to keeping the
    /// file. The comparison is therefore strictly greater-than, and this test plus
    /// the next one fence both sides of it.
    func testAudioExactlyThirtyDaysOldIsSpared() {
        let onTheLine = record(startedAt: daysAgo(30))

        let expired = RetentionSweeper.expiredAudio(
            in: [onTheLine], policy: .thirtyDays, now: now)

        XCTAssertTrue(expired.isEmpty, "Exactly at the threshold, audio is kept")
    }

    func testAudioOneSecondPastThirtyDaysExpires() {
        let justOver = record(startedAt: now.addingTimeInterval(-(30 * day + 1)))

        let expired = RetentionSweeper.expiredAudio(
            in: [justOver], policy: .thirtyDays, now: now)

        XCTAssertEqual(expired, [justOver.id], "One second past the threshold is expired")
    }

    func testSevenAndNinetyDayPoliciesUseTheirOwnThresholds() {
        let eightDays = record(startedAt: daysAgo(8))
        let sixtyDays = record(startedAt: daysAgo(60))
        let hundredDays = record(startedAt: daysAgo(100))
        let all = [eightDays, sixtyDays, hundredDays]

        XCTAssertEqual(
            RetentionSweeper.expiredAudio(in: all, policy: .sevenDays, now: now),
            [eightDays.id, sixtyDays.id, hundredDays.id]
        )
        XCTAssertEqual(
            RetentionSweeper.expiredAudio(in: all, policy: .ninetyDays, now: now),
            [hundredDays.id]
        )
    }

    // MARK: - expiredAudio: forever and never

    func testForeverExpiresNothingHoweverOldTheAudioIs() {
        let ancient = record(startedAt: daysAgo(5_000))
        let old = record(startedAt: daysAgo(400))

        let expired = RetentionSweeper.expiredAudio(
            in: [ancient, old], policy: .forever, now: now)

        XCTAssertTrue(expired.isEmpty)
    }

    func testNeverExpiresEveryRecordThatStillHoldsAudio() {
        let fresh = record(startedAt: now)
        let old = record(startedAt: daysAgo(400))
        let purged = record(startedAt: daysAgo(400), audioFileName: nil)

        let expired = RetentionSweeper.expiredAudio(
            in: [fresh, old, purged], policy: .never, now: now)

        XCTAssertEqual(expired, [fresh.id, old.id], "Even audio recorded a second ago")
        XCTAssertFalse(expired.contains(purged.id), "Nothing left to purge")
    }

    // MARK: - expiredAudio: records with no audio left

    /// A record whose audio is already gone must never come back for a second pass:
    /// it would be a wasted delete attempt against a file that is not there, and a
    /// second `update` writing a value that is already nil.
    func testRecordsWhoseAudioIsAlreadyPurgedAreNeverReturnedUnderAnyPolicy() {
        let purged = record(startedAt: daysAgo(400), audioFileName: nil)

        for policy in RetentionPolicy.allCases {
            XCTAssertTrue(
                RetentionSweeper.expiredAudio(in: [purged], policy: policy, now: now).isEmpty,
                "\(policy) returned a record with no audio"
            )
        }
    }

    /// The log is append-only JSONL and recovers from corruption by skipping lines;
    /// a duplicated id is not impossible. Returning it twice would mean two delete
    /// attempts for one file.
    func testADuplicatedRecordIDIsReturnedOnlyOnce() {
        let id = UUID()
        let first = record(id: id, startedAt: daysAgo(400))
        let second = record(id: id, startedAt: daysAgo(401))

        let expired = RetentionSweeper.expiredAudio(
            in: [first, second], policy: .thirtyDays, now: now)

        XCTAssertEqual(expired, [id])
    }

    /// A clock that stepped backwards (NTP, a timezone change, a restored backup)
    /// gives a record a negative age. Negative is not "very old".
    func testAFutureDatedRecordIsNeverExpired() {
        let future = record(startedAt: now.addingTimeInterval(10 * day))

        XCTAssertTrue(
            RetentionSweeper.expiredAudio(in: [future], policy: .sevenDays, now: now).isEmpty
        )
    }

    func testExpiredIDsComeBackInLogOrder() {
        let first = record(startedAt: daysAgo(100))
        let second = record(startedAt: daysAgo(500))
        let third = record(startedAt: daysAgo(40))

        XCTAssertEqual(
            RetentionSweeper.expiredAudio(in: [first, second, third], policy: .thirtyDays, now: now),
            [first.id, second.id, third.id]
        )
    }

    func testAnEmptyLogExpiresNothing() {
        XCTAssertTrue(RetentionSweeper.expiredAudio(in: [], policy: .never, now: now).isEmpty)
    }

    // MARK: - diskUsageBytes

    /// `audioBytes` is kept after a purge because it is a stats figure. Disk usage is
    /// a *filesystem* figure, so it counts only records that still have a file.
    func testDiskUsageCountsOnlyRecordsThatStillHaveAudio() {
        let live = record(audioFileName: "a.flac", audioBytes: 1_000)
        let alsoLive = record(audioFileName: "b.flac", audioBytes: 2_500)
        let purged = record(audioFileName: nil, audioBytes: 9_999_999)

        XCTAssertEqual(
            RetentionSweeper.diskUsageBytes(in: [live, alsoLive, purged]),
            3_500
        )
    }

    func testDiskUsageOfAnEmptyLogIsZero() {
        XCTAssertEqual(RetentionSweeper.diskUsageBytes(in: []), 0)
    }

    func testDiskUsageOfAFullyPurgedLogIsZero() {
        let purged = (0..<3).map { _ in record(audioFileName: nil, audioBytes: 5_000) }
        XCTAssertEqual(RetentionSweeper.diskUsageBytes(in: purged), 0)
    }

    // MARK: - The sweep: deletes exactly the expired set

    func testSweepDeletesExactlyTheExpiredFilesAndNilsOnlyTheirNames() async throws {
        let expired = record(startedAt: daysAgo(31), audioFileName: "old.flac", audioBytes: 1_000)
        let kept = record(startedAt: daysAgo(29), audioFileName: "new.flac", audioBytes: 2_000)
        let log = RetentionFakeRecordLog([expired, kept])
        let remover = FakeRemover()
        let runner = makeRunner(
            records: log, remover: remover, scheduler: FakeDailyScheduler(), policy: .thirtyDays)

        let result = try await runner.sweepNow()

        XCTAssertEqual(remover.attemptedNames, ["old.flac"], "Only the expired file")
        XCTAssertEqual(result.purged, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.reclaimedBytes, 1_000)
        XCTAssertNil(log.records[0].audioFileName)
        XCTAssertEqual(log.records[1].audioFileName, "new.flac")
        XCTAssertEqual(log.updateAttempts, [expired.id])
    }

    /// The sweep amends `audioFileName` and nothing else. It is not a delete of the
    /// record: the text of what was said survives forever.
    func testSweepNeverTouchesTheTextOrAnyOtherField() async throws {
        let expired = record(startedAt: daysAgo(400))
        let log = RetentionFakeRecordLog([expired])
        let runner = makeRunner(
            records: log, remover: FakeRemover(), scheduler: FakeDailyScheduler(),
            policy: .thirtyDays)

        _ = try await runner.sweepNow()

        var expectation = expired
        expectation.audioFileName = nil
        XCTAssertEqual(log.records, [expectation])
        XCTAssertEqual(log.records[0].audioBytes, expired.audioBytes, "Stats figure survives")
    }

    func testForeverSweepsNothingAtAll() async throws {
        let ancient = record(startedAt: daysAgo(5_000))
        let log = RetentionFakeRecordLog([ancient])
        let remover = FakeRemover()
        let runner = makeRunner(
            records: log, remover: remover, scheduler: FakeDailyScheduler(), policy: .forever)

        let result = try await runner.sweepNow()

        XCTAssertTrue(remover.attempts.isEmpty, "Not one delete attempt")
        XCTAssertTrue(log.updateAttempts.isEmpty, "Not one log rewrite")
        XCTAssertEqual(result, RetentionSweepResult())
        XCTAssertEqual(log.records, [ancient])
    }

    func testTheFileIsResolvedInsideTheConfiguredAudioDirectory() async throws {
        let directory = URL(fileURLWithPath: "/captur-tests-never-written/audio")
        let expired = record(startedAt: daysAgo(400), audioFileName: "session-7.flac")
        let remover = FakeRemover()
        let runner = makeRunner(
            records: RetentionFakeRecordLog([expired]), remover: remover,
            scheduler: FakeDailyScheduler(), policy: .thirtyDays, directory: directory)

        _ = try await runner.sweepNow()

        XCTAssertEqual(
            remover.attempts.first,
            directory.appendingPathComponent("session-7.flac")
        )
    }

    // MARK: - The sweep: idempotence

    /// The second sweep is the one that matters. The first nils the name; if the
    /// second still saw the record as expired it would attempt a delete against a
    /// file that no longer exists and rewrite the log for no reason.
    func testASecondSweepOverTheSameRecordsDoesNothingMore() async throws {
        let expired = record(startedAt: daysAgo(400))
        let log = RetentionFakeRecordLog([expired])
        let remover = FakeRemover()
        let runner = makeRunner(
            records: log, remover: remover, scheduler: FakeDailyScheduler(), policy: .thirtyDays)

        let first = try await runner.sweepNow()
        let second = try await runner.sweepNow()

        XCTAssertEqual(first.purged, 1)
        XCTAssertEqual(second, RetentionSweepResult(), "Nothing left to do")
        XCTAssertEqual(remover.attempts.count, 1, "Exactly one delete attempt, ever")
        XCTAssertEqual(log.updateAttempts, [expired.id], "Exactly one log rewrite, ever")
    }

    /// Two sweeps launched together must not both act on the same record. The runner
    /// chains its sweeps onto one another rather than letting them interleave across
    /// an `await`.
    func testConcurrentSweepsDoNotBothDeleteTheSameFile() async throws {
        let expired = record(startedAt: daysAgo(400))
        let log = RetentionFakeRecordLog([expired])
        let remover = FakeRemover()
        let runner = makeRunner(
            records: log, remover: remover, scheduler: FakeDailyScheduler(), policy: .thirtyDays)

        async let first = runner.sweepNow()
        async let second = runner.sweepNow()
        let results = try await [first, second]

        XCTAssertEqual(remover.attempts.count, 1, "One file, one delete attempt")
        XCTAssertEqual(results.map(\.purged).reduce(0, +), 1)
    }

    // MARK: - The sweep: failure policy

    /// **Decision: a failed file delete leaves `audioFileName` intact.** A throwing
    /// removal means the file is still on disk. Nil-ing the name would strand it as
    /// an orphan the sweep can never see again *and* break the playback button for
    /// a file that is right there. Keeping the name loses nothing: playback still
    /// works and the next sweep retries.
    func testAFailedFileDeleteLeavesTheNameIntactAndReportsTheFailure() async throws {
        let expired = record(startedAt: daysAgo(400), audioFileName: "locked.flac")
        let log = RetentionFakeRecordLog([expired])
        let remover = FakeRemover()
        remover.failingNames = ["locked.flac"]
        let runner = makeRunner(
            records: log, remover: remover, scheduler: FakeDailyScheduler(), policy: .thirtyDays)

        let result = try await runner.sweepNow()

        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.purged, 0)
        XCTAssertEqual(result.reclaimedBytes, 0)
        XCTAssertEqual(log.records[0].audioFileName, "locked.flac", "Still playable")
        XCTAssertTrue(log.updateAttempts.isEmpty, "The log is not amended for a file still there")
    }

    func testTheNextSweepRetriesAFileWhoseDeleteFailed() async throws {
        let expired = record(startedAt: daysAgo(400), audioFileName: "locked.flac")
        let log = RetentionFakeRecordLog([expired])
        let remover = FakeRemover()
        remover.failingNames = ["locked.flac"]
        let runner = makeRunner(
            records: log, remover: remover, scheduler: FakeDailyScheduler(), policy: .thirtyDays)

        _ = try await runner.sweepNow()
        remover.failingNames = []
        let retry = try await runner.sweepNow()

        XCTAssertEqual(retry.purged, 1)
        XCTAssertEqual(remover.attempts.count, 2, "The retry is a second attempt, not a skip")
        XCTAssertNil(log.records[0].audioFileName)
    }

    /// One unreadable file must not stop the sweep reclaiming the rest — a single
    /// stuck file would otherwise pin every older recording on disk forever.
    func testOneFailedDeleteDoesNotAbortTheRestOfTheSweep() async throws {
        let locked = record(startedAt: daysAgo(400), audioFileName: "locked.flac", audioBytes: 10)
        let first = record(startedAt: daysAgo(400), audioFileName: "a.flac", audioBytes: 100)
        let last = record(startedAt: daysAgo(400), audioFileName: "b.flac", audioBytes: 200)
        let log = RetentionFakeRecordLog([first, locked, last])
        let remover = FakeRemover()
        remover.failingNames = ["locked.flac"]
        let runner = makeRunner(
            records: log, remover: remover, scheduler: FakeDailyScheduler(), policy: .thirtyDays)

        let result = try await runner.sweepNow()

        XCTAssertEqual(result.purged, 2)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.reclaimedBytes, 300)
        XCTAssertEqual(remover.attemptedNames, ["a.flac", "locked.flac", "b.flac"])
        XCTAssertNil(log.records[0].audioFileName)
        XCTAssertEqual(log.records[1].audioFileName, "locked.flac")
        XCTAssertNil(log.records[2].audioFileName)
    }

    /// The file is gone but the log rewrite failed. There is no undo, so the record
    /// still names a file that is not there — a broken playback button. It is counted
    /// as a failure and self-heals: the next sweep sees the record as expired again,
    /// the remover treats an absent file as success, and the name is finally nil'd.
    func testALogUpdateFailureAfterASuccessfulDeleteIsReportedAndSelfHeals() async throws {
        let expired = record(startedAt: daysAgo(400), audioFileName: "gone.flac")
        let log = RetentionFakeRecordLog([expired])
        log.updateError = FakeFailure.boom("disk full")
        let remover = FakeRemover()
        let runner = makeRunner(
            records: log, remover: remover, scheduler: FakeDailyScheduler(), policy: .thirtyDays)

        let result = try await runner.sweepNow()

        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.purged, 0)
        XCTAssertEqual(log.records[0].audioFileName, "gone.flac", "The rewrite did not land")

        log.updateError = nil
        let healed = try await runner.sweepNow()
        XCTAssertEqual(healed.purged, 1)
        XCTAssertNil(log.records[0].audioFileName)
    }

    /// A log that cannot be read is not an empty log. Swallowing the error would make
    /// the sweep a silent no-op and disk usage a confident "0 bytes".
    func testASweepThatCannotReadTheLogThrows() async throws {
        let log = RetentionFakeRecordLog([record(startedAt: daysAgo(400))])
        log.readError = FakeFailure.boom("records.jsonl unreadable")
        let remover = FakeRemover()
        let runner = makeRunner(
            records: log, remover: remover, scheduler: FakeDailyScheduler(), policy: .thirtyDays)

        do {
            _ = try await runner.sweepNow()
            XCTFail("A sweep over an unreadable log must throw")
        } catch {
            XCTAssertTrue(remover.attempts.isEmpty, "And must not guess at what to delete")
        }
    }

    func testDiskUsageThrowsRatherThanReportingZeroForAnUnreadableLog() async throws {
        let log = RetentionFakeRecordLog([record(audioBytes: 5_000)])
        log.readError = FakeFailure.boom("records.jsonl unreadable")
        let runner = makeRunner(
            records: log, remover: FakeRemover(), scheduler: FakeDailyScheduler(),
            policy: .thirtyDays)

        do {
            _ = try await runner.diskUsageBytes()
            XCTFail("Unreadable is not zero")
        } catch {
            // Expected.
        }
    }

    // MARK: - Settings surfaces

    func testDiskUsageThroughTheRunnerReflectsTheLog() async throws {
        let log = RetentionFakeRecordLog([
            record(audioFileName: "a.flac", audioBytes: 1_500),
            record(audioFileName: nil, audioBytes: 9_000),
        ])
        let runner = makeRunner(
            records: log, remover: FakeRemover(), scheduler: FakeDailyScheduler(),
            policy: .thirtyDays)

        let usage = try await runner.diskUsageBytes()
        XCTAssertEqual(usage, 1_500)
    }

    /// *Delete all audio* ignores the configured policy — including `.forever`, which
    /// is exactly the setting a user is most likely to have on when they press it.
    func testDeleteAllAudioClearsEveryRecordEvenUnderForever() async throws {
        let fresh = record(startedAt: now, audioFileName: "a.flac", audioBytes: 100)
        let old = record(startedAt: daysAgo(400), audioFileName: "b.flac", audioBytes: 200)
        let purged = record(audioFileName: nil, audioBytes: 9_000)
        let log = RetentionFakeRecordLog([fresh, old, purged])
        let remover = FakeRemover()
        let runner = makeRunner(
            records: log, remover: remover, scheduler: FakeDailyScheduler(), policy: .forever)

        let result = try await runner.deleteAllAudio()

        XCTAssertEqual(result.purged, 2)
        XCTAssertEqual(result.reclaimedBytes, 300)
        XCTAssertEqual(remover.attemptedNames, ["a.flac", "b.flac"], "The purged record is skipped")
        XCTAssertTrue(log.records.allSatisfy { $0.audioFileName == nil })
        let usageAfter = try await runner.diskUsageBytes()
        XCTAssertEqual(usageAfter, 0)
    }

    // MARK: - Scheduling

    func testStartSweepsAtLaunchAndArmsTheDailyTimerExactlyOnce() async throws {
        let expired = record(startedAt: daysAgo(400))
        let log = RetentionFakeRecordLog([expired])
        let remover = FakeRemover()
        let scheduler = FakeDailyScheduler()
        let runner = makeRunner(
            records: log, remover: remover, scheduler: scheduler, policy: .thirtyDays)

        await runner.start()

        XCTAssertEqual(scheduler.scheduleCount, 1)
        XCTAssertTrue(scheduler.isArmed)
        XCTAssertEqual(remover.attemptedNames.count, 1, "Launch-time sweep ran")
        XCTAssertNil(log.records[0].audioFileName)
    }

    /// Spec §15 allows exactly one long-lived timer in the app, scheduled once. A
    /// second `start` must not arm a second one.
    func testRepeatedStartCallsNeverArmASecondTimer() async throws {
        let scheduler = FakeDailyScheduler()
        let log = RetentionFakeRecordLog([record(startedAt: daysAgo(400))])
        let remover = FakeRemover()
        let runner = makeRunner(
            records: log, remover: remover, scheduler: scheduler, policy: .thirtyDays)

        await runner.start()
        await runner.start()
        await runner.start()

        XCTAssertEqual(scheduler.scheduleCount, 1)
        XCTAssertEqual(remover.attempts.count, 1, "And no repeated launch sweep")
    }

    /// The daily tick has to actually run a sweep. Without this, the timer could be
    /// armed with a handler that does nothing and every other test would still pass.
    func testTheDailyTickRunsASweep() async throws {
        let scheduler = FakeDailyScheduler()
        let log = RetentionFakeRecordLog([record(startedAt: daysAgo(29), audioFileName: "x.flac")])
        let remover = FakeRemover()
        let clock = TestClock(now)
        let runner = makeRunner(
            records: log, remover: remover, scheduler: scheduler, policy: .thirtyDays, clock: clock)

        await runner.start()
        XCTAssertTrue(remover.attempts.isEmpty, "Nothing was expired at launch")

        // Two days later the same record is past 30 days, so the tick has work to do.
        clock.advance(by: 2 * day)
        await scheduler.fire()

        XCTAssertEqual(remover.attemptedNames, ["x.flac"], "The tick swept")
        XCTAssertNil(log.records[0].audioFileName)
    }

    /// A tick over an unreadable log must not blow up on a background queue — the
    /// scheduled path swallows and logs what the Settings-facing path throws.
    func testADailyTickOverAnUnreadableLogDoesNotTrap() async throws {
        let scheduler = FakeDailyScheduler()
        let log = RetentionFakeRecordLog([record(startedAt: daysAgo(400))])
        let runner = makeRunner(
            records: log, remover: FakeRemover(), scheduler: scheduler, policy: .thirtyDays)
        await runner.start()

        log.readError = FakeFailure.boom("records.jsonl unreadable")
        await scheduler.fire()   // Must simply return.
    }

    func testCancelCancelsTheSchedulerAndTheTickStopsFiring() async throws {
        let scheduler = FakeDailyScheduler()
        let log = RetentionFakeRecordLog([record(startedAt: daysAgo(400))])
        let remover = FakeRemover()
        let runner = makeRunner(
            records: log, remover: remover, scheduler: scheduler, policy: .thirtyDays)

        await runner.start()
        let attemptsAtLaunch = remover.attempts.count
        await runner.cancel()

        XCTAssertEqual(scheduler.cancelCount, 1)
        XCTAssertFalse(scheduler.isArmed)

        await scheduler.fire()
        XCTAssertEqual(remover.attempts.count, attemptsAtLaunch, "A cancelled timer does no work")
    }

    /// Cancel then start again must not resurrect the timer: the app builds this once
    /// at launch and tears it down once, and anything else is a second timer.
    func testStartAfterCancelDoesNotRearm() async throws {
        let scheduler = FakeDailyScheduler()
        let runner = makeRunner(
            records: RetentionFakeRecordLog(), remover: FakeRemover(),
            scheduler: scheduler, policy: .thirtyDays)

        await runner.start()
        await runner.cancel()
        await runner.start()

        XCTAssertEqual(scheduler.scheduleCount, 1)
        XCTAssertFalse(scheduler.isArmed)
    }

    // MARK: - The real remover, against real files

    func testTheFileManagerRemoverDeletesAFileThatExists() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("session.flac")
        try Data("audio".utf8).write(to: url)

        try FileManagerRemover().removeItem(at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// An already-missing file is a success, not a failure: the goal is "this audio is
    /// not on disk", and it is not. Treating it as a failure would leave the record
    /// permanently pointing at a file that does not exist.
    func testTheFileManagerRemoverTreatsAnAlreadyMissingFileAsSuccess() throws {
        let directory = try makeDirectory()
        let missing = directory.appendingPathComponent("never-existed.flac")

        XCTAssertNoThrow(try FileManagerRemover().removeItem(at: missing))
    }

    /// End to end over the real filesystem: the expired file leaves the audio
    /// directory, the spared one is still there afterwards.
    func testSweepRemovesTheExpiredFileFromDiskAndLeavesTheOther() async throws {
        let directory = try makeDirectory()
        try Data("old".utf8).write(to: directory.appendingPathComponent("old.flac"))
        try Data("new".utf8).write(to: directory.appendingPathComponent("new.flac"))

        let log = RetentionFakeRecordLog([
            record(startedAt: daysAgo(31), audioFileName: "old.flac"),
            record(startedAt: daysAgo(29), audioFileName: "new.flac"),
        ])
        let runner = RetentionSweepRunner(
            records: log,
            audioDirectory: directory,
            remover: FileManagerRemover(),
            scheduler: FakeDailyScheduler(),
            policy: { .thirtyDays },
            now: { self.now })

        let result = try await runner.sweepNow()

        XCTAssertEqual(result.purged, 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            ["new.flac"]
        )
    }
}
