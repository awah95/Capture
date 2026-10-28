import Foundation

/// T8. A durable FIFO of pending capture UUIDs awaiting Open Brain sync.
///
/// The queue is persisted as JSON at `Application Support/Captur/ob-queue.json`
/// (directory injectable for tests). Draining attempts each pending id in order
/// via a caller-supplied closure; the first failure keeps the id (preserving
/// order) and STOPS the drain. Exponential backoff (30s doubling to a 10-minute
/// cap) is persisted alongside the queue, and `drain` is a no-op until the
/// scheduled `nextAttemptAt`. A corrupt queue file is backed up alongside — the
/// pending list is never lost silently.
actor OpenBrainSyncQueue {

    /// The persisted queue state.
    private struct State: Codable {
        var pending: [UUID] = []
        var nextAttemptAt: Date?
        /// Seconds to wait after the *next* failure. Starts at the floor and
        /// doubles per failure up to the cap.
        var backoffSeconds: TimeInterval = OpenBrainSyncQueue.backoffFloor
    }

    static let backoffFloor: TimeInterval = 30       // 30s
    static let backoffCap: TimeInterval = 10 * 60    // 10 minutes

    private let directory: URL
    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var state: State
    private var isDraining = false

    init(directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let dir = directory ?? Self.defaultDirectory()
        self.directory = dir
        self.fileURL = dir.appendingPathComponent("ob-queue.json")
        self.now = now
        self.state = Self.loadState(fileURL: fileURL, directory: dir, now: now)
    }

    // MARK: - API

    /// Appends an id to the FIFO (de-duplicated) and persists.
    func enqueue(_ id: UUID) {
        guard !state.pending.contains(id) else { return }
        state.pending.append(id)
        persist()
    }

    /// The pending ids in FIFO order.
    func pending() -> [UUID] {
        state.pending
    }

    /// The scheduled earliest next attempt, if the queue is backing off.
    func nextAttempt() -> Date? {
        state.nextAttemptAt
    }

    /// Attempts each pending id in order. A `true` result removes the id and
    /// resets backoff; a `false` result keeps the id, schedules the next attempt
    /// with exponential backoff, and STOPS (preserving FIFO order). The drain is a
    /// no-op before `nextAttemptAt`.
    func drain(send: (UUID) async -> Bool) async {
        guard !isDraining else { return }
        guard !state.pending.isEmpty else { return }
        if let next = state.nextAttemptAt, now() < next { return }
        isDraining = true
        defer { isDraining = false }

        while let id = state.pending.first {
            let succeeded = await send(id)
            if succeeded {
                // The actor is re-entrant across `send`. Only acknowledge the exact
                // head that was attempted; never remove an item introduced or
                // otherwise changed while suspended.
                guard state.pending.first == id else { return }
                state.pending.removeFirst()
                state.backoffSeconds = Self.backoffFloor
                state.nextAttemptAt = nil
                persist()
            } else {
                state.nextAttemptAt = now().addingTimeInterval(state.backoffSeconds)
                state.backoffSeconds = min(state.backoffSeconds * 2, Self.backoffCap)
                persist()
                return
            }
        }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: an unwritable directory shouldn't crash a capture.
            // The in-memory state remains correct for this process's lifetime.
        }
    }

    private static func loadState(fileURL: URL, directory: URL, now: @Sendable () -> Date) -> State {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return State()
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return State()
        }
        if let state = try? JSONDecoder().decode(State.self, from: data) {
            return state
        }
        // Corrupt file: back it up alongside so the list is never lost silently,
        // then start empty.
        backupCorruptFile(fileURL: fileURL, directory: directory, now: now)
        return State()
    }

    private static func backupCorruptFile(fileURL: URL, directory: URL, now: @Sendable () -> Date) {
        let stamp = String(Int(now().timeIntervalSince1970))
        let backupURL = directory.appendingPathComponent("ob-queue.corrupt-\(stamp).json")
        // Move if possible; fall back to copy so the corrupt bytes survive even
        // if a same-stamp backup already exists.
        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
        } catch {
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
    }

    private static func defaultDirectory() -> URL {
        AppPaths.supportDirectory()
    }
}
