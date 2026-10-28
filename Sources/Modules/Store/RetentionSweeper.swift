import Foundation
import os

// MARK: - Policy

/// How long session audio is kept before it is purged. Spec §16.
///
/// The raw values are the **persisted** form of the user's choice. Renaming a case
/// silently resets everyone who chose it back to the default on next launch, so
/// `RetentionSweeperTests` pins them.
///
/// `forever` and `never` are the two ends of the same dial rather than special modes:
/// `forever` has no age at which audio expires, `never` expires it immediately.
enum RetentionPolicy: String, Codable, CaseIterable, Sendable {
    case sevenDays, thirtyDays, ninetyDays, forever, never

    /// Spec §16: 30 days. This is what the app deletes for every user who never opens
    /// Settings, which is most of them.
    static let `default`: RetentionPolicy = .thirtyDays

    /// The age at which audio expires, or nil when age is not the deciding factor
    /// (`forever` keeps everything, `never` keeps nothing).
    ///
    /// **Exact 24-hour intervals, not calendar days.** `startedAt` is stored as epoch
    /// seconds and retention is a promise about a *duration* — "your audio is kept for
    /// 30 days". Calendar arithmetic would hand the answer to the user's timezone and
    /// to DST: the same recording could be expired or spared depending on which hour
    /// of the day they dictated, and a machine that crossed a timezone would purge a
    /// different set than the one it would have at home. Seconds are timezone-free and
    /// reproducible in a test.
    var maxAudioAge: TimeInterval? {
        switch self {
        case .sevenDays: return 7 * Self.day
        case .thirtyDays: return 30 * Self.day
        case .ninetyDays: return 90 * Self.day
        case .forever, .never: return nil
        }
    }

    private static let day: TimeInterval = 86_400
}

// MARK: - Pure sweep arithmetic

/// Decides *what* the sweep should act on. No filesystem, no clock of its own, no
/// state — so every boundary can be fenced by a test that names the exact ages
/// involved. `RetentionSweepRunner` does the acting.
enum RetentionSweeper {
    /// The ids whose audio has outlived `policy`, in log order.
    ///
    /// **The boundary is strictly greater-than: audio *exactly* at the threshold is
    /// spared.** At the 30-day mark the last day of the promise has only just elapsed,
    /// and there is no undo for a deleted recording, so the tie goes to keeping it.
    /// One more sweep — at most a day later — takes it.
    ///
    /// A record whose `audioFileName` is already nil is never returned: there is no
    /// file to delete and no field left to clear, and returning it would cost a wasted
    /// delete attempt plus a pointless rewrite of the whole log every single day.
    ///
    /// Each id appears at most once, and a duplicated id resolves to its **first**
    /// line — the same line `RetentionSweepRunner` will read the file name from. The
    /// log recovers from corruption by skipping lines rather than by de-duplicating
    /// them, so two lines sharing an id is possible, and it must not become two delete
    /// attempts for one file.
    static func expiredAudio(
        in records: [DictationRecord],
        policy: RetentionPolicy,
        now: Date
    ) -> [UUID] {
        guard policy != .forever else { return [] }

        var considered = Set<UUID>()
        var expired: [UUID] = []
        for record in records {
            guard considered.insert(record.id).inserted else { continue }
            guard record.audioFileName != nil else { continue }

            if let maxAge = policy.maxAudioAge {
                // A clock that stepped backwards — NTP, a restored backup — gives a
                // negative age. Negative is not "very old".
                guard now.timeIntervalSince(record.startedAt) > maxAge else { continue }
            }
            expired.append(record.id)
        }
        return expired
    }

    /// Bytes of audio currently on disk, for Settings → Privacy.
    ///
    /// `audioBytes` survives a purge because it is a stats figure — how much was
    /// recorded. Disk usage is a filesystem figure, so it counts only the records that
    /// still name a file. Counting the purged ones would show a number that never
    /// falls, which is the one thing this readout exists to do.
    static func diskUsageBytes(in records: [DictationRecord]) -> Int {
        records.reduce(into: 0) { total, record in
            guard record.audioFileName != nil else { return }
            total += record.audioBytes
        }
    }
}

// MARK: - Seams

/// The file-deletion surface the sweep acts through. A seam rather than a direct
/// `FileManager` call so no test has to put a real file where the app keeps audio in
/// order to prove which files a sweep would have deleted.
protocol FileRemoving: Sendable {
    func removeItem(at url: URL) throws
}

/// The production remover.
///
/// **An already-missing file is a success.** The goal is "this audio is not on disk",
/// and it is not. Throwing here would leave the record permanently naming a file that
/// does not exist — a playback button that can never work and a sweep that retries a
/// no-op forever.
struct FileManagerRemover: FileRemoving {
    func removeItem(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// The once-a-day schedule seam.
///
/// It exists so the runner's daily behaviour is testable without a real timer: the
/// production implementation arms one 24 hours out, and a test that watched it fire
/// would have to wait a day.
protocol DailyScheduling: AnyObject, Sendable {
    /// Arms the schedule. Called at most once per instance.
    func scheduleDaily(_ work: @escaping @Sendable () async -> Void)
    func cancel()
}

/// **The only long-lived timer in the app** (spec §15 requires ~0% idle CPU and no
/// polling anywhere else).
///
/// It earns the exception by being armed exactly once, 24 hours out, and repeating on
/// its own — nothing here ever re-arms from inside the handler, which is how a
/// "daily" timer usually turns into a loop that drifts. The 15-minute leeway lets the
/// kernel coalesce the wakeup with whatever else it was already going to wake for; a
/// purge has no business being punctual.
final class DailyDispatchTimer: DailyScheduling, @unchecked Sendable {
    private static let interval: TimeInterval = 86_400

    private let queue = DispatchQueue(label: "com.awah.captur.retention", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// Latched, and deliberately never cleared by `cancel`. Teardown is final: a
    /// second arming would mean two timers sweeping the same files at once.
    private var didSchedule = false

    func scheduleDaily(_ work: @escaping @Sendable () async -> Void) {
        let source: DispatchSourceTimer? = lock.withLock { () -> DispatchSourceTimer? in
            guard !didSchedule else { return nil }
            didSchedule = true
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now() + Self.interval,
                repeating: Self.interval,
                leeway: .seconds(15 * 60))
            source.setEventHandler {
                Task.detached(priority: .utility) { await work() }
            }
            timer = source
            return source
        }
        // Resumed outside the lock: the handler runs on `queue`, not here, but a
        // timer that could fire while the lock is held is a deadlock waiting for a
        // slow first tick.
        source?.resume()
    }

    func cancel() {
        let source: DispatchSourceTimer? = lock.withLock {
            let source = timer
            timer = nil
            return source
        }
        source?.cancel()
    }

    deinit { timer?.cancel() }
}

// MARK: - Result

/// What one sweep did. `failed` counts records the sweep could not finish, each of
/// which is left in a state the next sweep can retry — see `RetentionSweepRunner`.
struct RetentionSweepResult: Equatable, Sendable {
    var purged = 0
    var failed = 0
    var reclaimedBytes = 0
}

// MARK: - Runner

/// Runs the retention sweep: at launch, once a day, and on demand from Settings.
///
/// Every dependency is injected — the record log, the file remover, the schedule, the
/// policy and the clock — because this is the one unit in the app that deletes the
/// user's data, and no test of it should be able to reach the real audio directory or
/// arm a real timer.
///
/// An actor, and sweeps are **chained** rather than merely serialized by actor
/// isolation: a sweep suspends at every `await`, so two overlapping sweeps would
/// otherwise interleave and both act on the same record. The chain is the same idiom
/// `AppComposition` uses for capture edges.
actor RetentionSweepRunner {
    private let records: any DictationRecordLogging
    private let audioDirectory: URL
    private let remover: FileRemoving
    private let scheduler: DailyScheduling
    private let policy: @Sendable () -> RetentionPolicy
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.awah.captur", category: "retention")

    private var didStart = false
    private var tail: Task<RetentionSweepResult, Error>?

    init(
        records: any DictationRecordLogging,
        audioDirectory: URL,
        remover: FileRemoving,
        scheduler: DailyScheduling,
        policy: @escaping @Sendable () -> RetentionPolicy,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.records = records
        self.audioDirectory = audioDirectory
        self.remover = remover
        self.scheduler = scheduler
        self.policy = policy
        self.now = now
    }

    // MARK: Lifecycle

    /// Sweeps once and arms the daily schedule. Idempotent: a second call does
    /// nothing, so a repeated launch path cannot produce a second timer or a second
    /// launch sweep.
    func start() async {
        guard !didStart else { return }
        didStart = true

        // Armed *before* the launch sweep, not after: a launch sweep that throws — an
        // unreadable log, a locked directory — must not also cost the user the daily
        // one, which is the sweep that will still be running in a month.
        scheduler.scheduleDaily { [weak self] in await self?.sweepIgnoringFailure() }

        await sweepIgnoringFailure()
    }

    /// Stops the daily timer.
    ///
    /// An in-flight sweep is deliberately left to finish. It may be between deleting a
    /// file and clearing the record that names it, and abandoning it exactly there is
    /// the file-and-log disagreement this whole file is built to avoid.
    func cancel() {
        scheduler.cancel()
    }

    deinit { scheduler.cancel() }

    // MARK: Sweeps

    /// Sweeps under the configured policy. Throws only when the record log cannot be
    /// read at all; a record the sweep could not finish is counted in `failed`.
    @discardableResult
    func sweepNow() async throws -> RetentionSweepResult {
        try await enqueue(expiring: policy()).value
    }

    /// Settings → Privacy → *Delete all audio*.
    ///
    /// Deliberately ignores the configured policy — `.forever` is exactly the setting
    /// a user is most likely to have on at the moment they press it — by running the
    /// already-tested `.never` path rather than a second deletion loop.
    @discardableResult
    func deleteAllAudio() async throws -> RetentionSweepResult {
        try await enqueue(expiring: .never).value
    }

    /// Bytes of audio on disk, for the Settings readout.
    ///
    /// Throws rather than reporting 0 for a log it cannot read: "0 bytes" next to a
    /// *Delete all audio* button is a claim, and the wrong one.
    func diskUsageBytes() async throws -> Int {
        RetentionSweeper.diskUsageBytes(in: try await records.all())
    }

    /// The launch and daily-tick path: logged, never thrown. Nothing is waiting on the
    /// result, and a throw out of a timer handler is nobody's error to catch.
    private func sweepIgnoringFailure() async {
        do {
            _ = try await sweepNow()
        } catch {
            logger.error(
                "Retention sweep could not read the record log: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Chains a sweep behind whatever sweep is already running. A previous sweep that
    /// failed is not allowed to fail this one — each sweep re-reads the log and works
    /// from what it finds.
    private func enqueue(expiring policy: RetentionPolicy) -> Task<RetentionSweepResult, Error> {
        let previous = tail
        let task = Task { [weak self] () throws -> RetentionSweepResult in
            _ = try? await previous?.value
            guard let self else { return RetentionSweepResult() }
            return try await self.purge(expiring: policy)
        }
        tail = task
        return task
    }

    /// Deletes the expired session files and clears the `audioFileName` of every
    /// record whose file is confirmed gone.
    ///
    /// The governing rule is *never lose what was said, and always say what happened*.
    /// The text is never touched — this amends one optional field and nothing else.
    /// The two ways the file and the log can disagree are both handled deliberately:
    ///
    /// - **The delete failed** (permissions, I/O). The file is still there, so the name
    ///   stays. Clearing it would strand an orphan the sweep can never see again *and*
    ///   break a playback button for a file that is sitting right there. Keeping it
    ///   costs nothing: playback still works and tomorrow's sweep retries.
    /// - **The delete succeeded but the log rewrite failed.** There is no undo for the
    ///   delete, so the record briefly names a file that is gone. It self-heals: the
    ///   record is still expired next sweep, `FileManagerRemover` treats the absent
    ///   file as success, and the name is cleared then.
    ///
    /// A single stuck file never aborts the rest of the sweep — one unreadable
    /// recording would otherwise pin every older one on disk forever.
    private func purge(expiring policy: RetentionPolicy) async throws -> RetentionSweepResult {
        let all = try await records.all()
        let expired = RetentionSweeper.expiredAudio(in: all, policy: policy, now: now())
        guard !expired.isEmpty else { return RetentionSweepResult() }

        // First line wins on a duplicated id, matching `expiredAudio`'s own choice.
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var result = RetentionSweepResult()
        for id in expired {
            guard let record = byID[id], let fileName = record.audioFileName else { continue }

            do {
                try remover.removeItem(at: audioDirectory.appendingPathComponent(fileName))
            } catch {
                result.failed += 1
                logger.error(
                    "Retention: could not delete audio, keeping the record's reference: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            do {
                try await records.update(id: id) { $0.audioFileName = nil }
            } catch {
                result.failed += 1
                logger.error(
                    "Retention: audio deleted but the record still names it; the next sweep will finish it: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            result.purged += 1
            result.reclaimedBytes += record.audioBytes
        }

        if result.purged > 0 || result.failed > 0 {
            logger.info(
                """
                Retention sweep (\(policy.rawValue, privacy: .public)): \
                purged \(result.purged, privacy: .public), \
                failed \(result.failed, privacy: .public), \
                reclaimed \(result.reclaimedBytes, privacy: .public) bytes
                """
            )
        }
        return result
    }
}
