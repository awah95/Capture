import Foundation

// MARK: - Row

/// One record, prepared for display and for search.
///
/// The precomputed `searchText` is the whole reason this type exists rather than the
/// view filtering `[DictationRecord]` directly. Search runs on every keystroke over
/// the entire history — the record log's own budget is 5,000 records — so the four
/// searchable fields are concatenated and case-folded **once**, at load, instead of
/// per comparison. Filtering is then one substring search per row.
struct HistoryRow: Identifiable, Equatable {
    let record: DictationRecord
    /// Resolved through the mode store, so a renamed mode is searchable and visible
    /// under its current name. Falls back to the raw id for a mode that no longer
    /// exists — better a slug than a blank.
    let modeName: String
    /// Lowercased `finalText` + `rawText` + app name + mode name. Never displayed.
    let searchText: String

    var id: UUID { record.id }

    /// A recorded name when there is one, a name derived from the bundle id when there
    /// is not — every record written before the pipeline started capturing names has
    /// only the identifier.
    var appName: String {
        AppDisplayName.label(bundleID: record.targetBundleID,
                             recordedName: record.targetAppName) ?? "Unknown app"
    }

    var isCancelled: Bool {
        if case .cancelled = record.outcome { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = record.outcome { return true }
        return false
    }

    var failureReason: String? {
        if case .failed(let reason) = record.outcome { return reason }
        return nil
    }

    /// A segment failed permanently and the stitcher left its marker in the text.
    ///
    /// This is the retryable signal, **not** the outcome: a capture where one segment
    /// died is still written with `outcome == .inserted` (`DictationRecordDraft`
    /// stamps `.inserted` once the text reaches the cursor, whether or not the text
    /// is complete). Keying retry off the outcome would hide a hole in the middle of
    /// the user's sentence behind a green tick. See `docs/wiring/task22-wiring.md`.
    var hasPartialTranscript: Bool {
        record.isPartialTranscript
    }

    /// Retry re-transcribes from the session file, so it needs one to exist. A record
    /// whose audio the retention sweep has purged gets no button at all — a dead
    /// control is worse than an absent one.
    var canRetryTranscription: Bool {
        guard record.audioFileName != nil else { return false }
        return isFailed || hasPartialTranscript
    }

    /// Re-running the mode transforms the stored raw transcript; it needs no audio
    /// and no network round trip through Whisper. With nothing raw there is nothing
    /// to transform.
    var canRetryMode: Bool { !record.rawText.isEmpty }

    var canReinsert: Bool { !record.finalText.isEmpty }

    /// Present only when there is something to say. `.inserted` is the ordinary case
    /// and gets no badge — a list where every row is labelled labels nothing.
    var statusLabel: String? {
        if isCancelled { return "Cancelled" }
        if isFailed { return "Failed" }
        if hasPartialTranscript { return "Partial" }
        return nil
    }

    /// The one-line summary shown when the row is collapsed. A cancelled capture has
    /// no final text, so it shows what was heard instead of showing nothing.
    var previewText: String {
        let text = record.finalText.isEmpty ? record.rawText : record.finalText
        return text.isEmpty ? "No transcript" : text
    }
}

// MARK: - Day group

/// Records that share a **local** calendar day. Spec §10.2 asks for date grouping;
/// the day boundary that matters is the user's, not UTC's.
struct HistoryDayGroup: Identifiable, Equatable {
    let day: Date
    let title: String
    let rows: [HistoryRow]

    var id: Date { day }
}

// MARK: - View model

/// State and behaviour behind spec §10.2's History pane.
///
/// Every dependency is injected, including the calendar and the clock, so the whole
/// screen is constructible in a test with no file system, no pasteboard, no
/// AVFoundation and no `NSWorkspace`. Task 21 hosts the view; this type never knows
/// there is a window.
@MainActor
final class HistoryViewModel: ObservableObject {

    /// Where a re-insert should land. Carries the name only so the button can say
    /// *Insert into Mail* rather than *Insert*.
    struct Target: Equatable, Sendable {
        var bundleID: String
        var name: String?
    }

    /// A scope chip. `id` is the mode id or the app's bundle id — never an index,
    /// because chips are rebuilt whenever the snapshot changes.
    struct Chip: Identifiable, Equatable {
        let id: String
        let title: String
        let count: Int
    }

    struct Playback: Equatable {
        var recordID: UUID
        var url: URL
        var position: TimeInterval
        var duration: TimeInterval
        var isPlaying: Bool
    }

    // MARK: Published state

    /// Re-filters on change. Assigning the same string is a no-op, so a SwiftUI
    /// re-render that writes the binding back does not redo the work.
    @Published var query: String = "" {
        didSet { if oldValue != query { rebuildGroups() } }
    }

    /// Mode id, nil = All.
    @Published var modeFilter: String? {
        didSet { if oldValue != modeFilter { rebuildGroups() } }
    }

    /// Target app bundle id, nil = All.
    @Published var appFilter: String? {
        didSet { if oldValue != appFilter { rebuildGroups() } }
    }

    @Published private(set) var groups: [HistoryDayGroup] = []
    @Published private(set) var modeChips: [Chip] = []
    @Published private(set) var appChips: [Chip] = []
    @Published private(set) var isLoaded = false
    /// Set when the record log could not be read at all. Distinct from an empty log:
    /// an unreadable history must not be presented as "you have never dictated".
    @Published private(set) var loadError: String?

    @Published private(set) var expandedRecordID: UUID?
    /// Resolved lazily, when a row expands. Resolving audio availability for every
    /// record at load would mean one `fileExists` per record — thousands of stats
    /// calls to decide the visibility of a control the user cannot see yet.
    @Published private(set) var expandedAudioURL: URL?

    /// The row whose delete button has been armed. Delete is irreversible, so it
    /// takes two deliberate acts and the second one is right next to the first.
    @Published private(set) var pendingDeleteID: UUID?

    @Published private(set) var insertionTarget: Target?
    @Published private(set) var playback: Playback?

    // MARK: Seams

    private let records: () async throws -> [DictationRecord]
    private let deleteRecord: (UUID) async throws -> Void
    private let modeName: (String) -> String
    private let copyText: (String) -> Void
    private let reinsertText: (String, Target?) async -> Void
    private let retryTranscriptionAction: (UUID) async -> Void
    private let retryModeAction: (UUID) async -> Void
    /// File name → playable URL, or nil when the file is gone. The caller owns the
    /// existence check; this type never touches the audio directory.
    private let audioURL: (String) -> URL?
    private let player: any HistoryAudioPlaying
    private let frontmostTarget: () -> Target?
    private let calendar: Calendar
    private let now: () -> Date

    /// Every loaded record, newest first, with its search text already folded.
    /// Filtering works on this; the log is read once per `load()`.
    private var snapshot: [HistoryRow] = []

    private let dayFormatter: DateFormatter
    private let timeFormatter: DateFormatter

    init(
        records: @escaping () async throws -> [DictationRecord],
        deleteRecord: @escaping (UUID) async throws -> Void,
        modeName: @escaping (String) -> String,
        copyText: @escaping (String) -> Void,
        reinsert: @escaping (String, Target?) async -> Void,
        retryTranscription: @escaping (UUID) async -> Void,
        retryMode: @escaping (UUID) async -> Void,
        audioURL: @escaping (String) -> URL?,
        player: any HistoryAudioPlaying,
        frontmostTarget: @escaping () -> Target?,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.records = records
        self.deleteRecord = deleteRecord
        self.modeName = modeName
        self.copyText = copyText
        self.reinsertText = reinsert
        self.retryTranscriptionAction = retryTranscription
        self.retryModeAction = retryMode
        self.audioURL = audioURL
        self.player = player
        self.frontmostTarget = frontmostTarget
        self.calendar = calendar
        self.now = now

        // Both formatters take their zone and locale from the injected calendar, so a
        // test that grouped in Kathmandu also *labels* in Kathmandu. A formatter left
        // on the system zone would silently disagree with the grouping.
        dayFormatter = Self.formatter(template: "EEEE d MMMM y", calendar: calendar)
        timeFormatter = Self.formatter(template: "j:mm", calendar: calendar)

        player.onProgress = { [weak self] position, duration in
            self?.applyProgress(position: position, duration: duration)
        }
        player.onFinish = { [weak self] in
            self?.finishPlayback()
        }
    }

    private static func formatter(template: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// Time of day in the user's own zone — the same zone the day grouping uses.
    func timeOfDay(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    // MARK: - Empty states, spec §10.6

    /// Nothing has ever been dictated. Same copy as Home: it is the same absence.
    var hasNoDictations: Bool { isLoaded && loadError == nil && snapshot.isEmpty }

    /// There is a history, but the query and chips exclude all of it.
    var hasNoSearchMatches: Bool { isLoaded && !snapshot.isEmpty && groups.isEmpty }

    var hasActiveScope: Bool { modeFilter != nil || appFilter != nil }

    // MARK: - Loading

    /// Reads the log once and rebuilds everything derived from it.
    func load() async {
        do {
            let loaded = try await records()
            snapshot = loaded
                .sorted { $0.startedAt > $1.startedAt }
                .map(makeRow)
            loadError = nil
        } catch {
            snapshot = []
            loadError = error.localizedDescription
        }
        isLoaded = true
        rebuildChips()
        rebuildGroups()
    }

    /// Same as `load()`, named for the call site that means "something else changed
    /// the log" — a retry finishing, or the retention sweep running.
    func refresh() async {
        await load()
    }

    private func makeRow(_ record: DictationRecord) -> HistoryRow {
        let mode = modeName(record.modeID)
        // One allocation per record, at load. The four fields spec §10.2 requires
        // search to match, joined with a separator so a term cannot straddle two of
        // them and produce a phantom hit.
        let haystack = [record.finalText,
                        record.rawText,
                        record.targetAppName ?? "",
                        record.targetBundleID ?? "",
                        mode]
            .joined(separator: "\u{1F}")
            .lowercased()
        return HistoryRow(record: record, modeName: mode, searchText: haystack)
    }

    // MARK: - Filtering and grouping

    private func rebuildGroups() {
        // Folded once per keystroke, not once per row.
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mode = modeFilter
        let app = appFilter

        let matches = snapshot.filter { row in
            if let mode, row.record.modeID != mode { return false }
            if let app, row.record.targetBundleID != app { return false }
            if needle.isEmpty { return true }
            return row.searchText.contains(needle)
        }

        // `snapshot` is already newest-first, so grouping in order gives newest-first
        // groups with newest-first rows and needs no second sort.
        var order: [Date] = []
        var buckets: [Date: [HistoryRow]] = [:]
        for row in matches {
            let day = calendar.startOfDay(for: row.record.startedAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(row)
        }

        groups = order.map { day in
            HistoryDayGroup(day: day, title: title(for: day), rows: buckets[day] ?? [])
        }
    }

    /// "Today" and "Yesterday" are computed against the injected clock, not
    /// `Calendar.isDateInToday`, which reads the system clock and would make the
    /// titles untestable.
    private func title(for day: Date) -> String {
        let today = calendar.startOfDay(for: now())
        if day == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Yesterday"
        }
        return dayFormatter.string(from: day)
    }

    private func rebuildChips() {
        // Chips describe the whole history, not the current filter: a chip that
        // vanished because it was not selected could never be selected.
        var modeCounts: [String: Int] = [:]
        var appCounts: [String: Int] = [:]
        var appTitles: [String: String] = [:]

        for row in snapshot {
            modeCounts[row.record.modeID, default: 0] += 1
            if let bundleID = row.record.targetBundleID {
                appCounts[bundleID, default: 0] += 1
                appTitles[bundleID] = row.appName
            }
        }

        modeChips = modeCounts
            .map { Chip(id: $0.key, title: modeName($0.key), count: $0.value) }
            .sorted { ($1.count, $0.title) < ($0.count, $1.title) }
        appChips = appCounts
            .map { Chip(id: $0.key, title: appTitles[$0.key] ?? $0.key, count: $0.value) }
            .sorted { ($1.count, $0.title) < ($0.count, $1.title) }
    }

    func clearScope() {
        modeFilter = nil
        appFilter = nil
    }

    // MARK: - Re-insert target

    /// Captures the app to re-insert into. **Call this when the window opens, before
    /// it becomes key.**
    ///
    /// Spec §10.2: ⏎ inserts into the app that was frontmost *before* the window
    /// opened. Reading the frontmost app at re-insert time would always answer
    /// "Captur", because opening History is what made Captur frontmost — and this
    /// app exists to put text into whatever the user was working in. See
    /// `docs/wiring/task22-wiring.md` for the robust wiring, which remembers the
    /// last non-Captur app rather than sampling at one instant.
    func captureInsertionTarget() {
        insertionTarget = frontmostTarget()
    }

    // MARK: - Row actions

    func toggleExpansion(_ id: UUID) {
        if expandedRecordID == id {
            collapse()
            return
        }
        // Switching rows abandons whatever was playing: the scrubber belongs to the
        // expanded row, and leaving audio running under a collapsed row is a ghost.
        stopPlayback()
        expandedRecordID = id
        expandedAudioURL = resolveAudioURL(for: id)
    }

    private func collapse() {
        stopPlayback()
        expandedRecordID = nil
        expandedAudioURL = nil
    }

    /// Whether the expanded row can show a scrubber at all.
    var canPlayExpandedRow: Bool { expandedAudioURL != nil }

    func copy(_ row: HistoryRow) {
        copyText(row.record.finalText.isEmpty ? row.record.rawText : row.record.finalText)
    }

    func reinsert(_ row: HistoryRow) async {
        guard row.canReinsert else { return }
        await reinsertText(row.record.finalText, insertionTarget)
    }

    func retryTranscription(_ row: HistoryRow) async {
        guard row.canRetryTranscription else { return }
        await retryTranscriptionAction(row.id)
    }

    func retryMode(_ row: HistoryRow) async {
        guard row.canRetryMode else { return }
        await retryModeAction(row.id)
        await load()
    }

    // MARK: - Delete

    func requestDelete(_ id: UUID) {
        pendingDeleteID = id
    }

    func cancelDelete() {
        pendingDeleteID = nil
    }

    /// Deletes the armed record **by id**.
    ///
    /// By id and never by position: the visible list is a filtered, grouped subset of
    /// the snapshot, so "the second row on screen" and "the second record in the log"
    /// are different records the moment a search is active. Deleting a dictation is
    /// unrecoverable, which makes an off-by-one here a data-loss bug rather than a
    /// cosmetic one.
    func confirmDelete() async {
        guard let id = pendingDeleteID else { return }
        pendingDeleteID = nil

        do {
            try await deleteRecord(id)
        } catch {
            loadError = error.localizedDescription
            return
        }

        if expandedRecordID == id { collapse() }
        if playback?.recordID == id { stopPlayback() }

        snapshot.removeAll { $0.id == id }
        rebuildChips()
        rebuildGroups()
    }

    // MARK: - Playback

    /// Plays, pauses or resumes the row's **session** file — the continuous recording
    /// (spec §4.3), not a segment temporary, which is why the record stores exactly
    /// one audio file name.
    func togglePlayback(_ row: HistoryRow) {
        if var current = playback, current.recordID == row.id {
            if current.isPlaying {
                player.pause()
                current.isPlaying = false
            } else {
                player.resume()
                current.isPlaying = true
            }
            playback = current
            return
        }

        guard let url = resolveAudioURL(for: row.id) else { return }

        // Starting a second row's audio stops the first: two dictations playing at
        // once is never what the keystroke meant.
        if playback != nil { stopPlayback() }

        player.play(url)
        playback = Playback(recordID: row.id, url: url, position: 0, duration: 0, isPlaying: true)
    }

    func seek(to position: TimeInterval) {
        guard var current = playback else { return }
        player.seek(to: position)
        current.position = position
        playback = current
    }

    func stopPlayback() {
        guard playback != nil else { return }
        player.stop()
        playback = nil
    }

    /// The player's own clock advanced. Nothing here polls — see `HistoryAudioPlayer`.
    private func applyProgress(position: TimeInterval, duration: TimeInterval) {
        guard var current = playback else { return }
        current.position = position
        if duration > 0 { current.duration = duration }
        playback = current
    }

    private func finishPlayback() {
        playback = nil
    }

    /// nil for a record whose audio was never kept or has since been purged, and for
    /// one whose file has vanished under us. Either way the row shows no scrubber
    /// instead of an error the user can do nothing about.
    private func resolveAudioURL(for id: UUID) -> URL? {
        guard let record = snapshot.first(where: { $0.id == id })?.record,
              let fileName = record.audioFileName
        else { return nil }
        return audioURL(fileName)
    }
}
