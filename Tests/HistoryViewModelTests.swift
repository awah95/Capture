import XCTest
@testable import Captur

// MARK: - Test doubles
//
// Local to this file on purpose. `Tests/Support/Fakes.swift` is owned by another
// branch, and every seam below exists so that no test in here touches the owner's
// real record log, real clipboard, real audio files, or the speakers. A history
// test that played a dictation out loud, or that deleted a real record, would be
// unrecoverable damage rather than a red test.

/// Records what the view model asked the audio layer to do. Never opens a file and
/// never makes a sound.
@MainActor
final class SpyHistoryAudioPlayer: HistoryAudioPlaying {
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?
    var onFinish: (() -> Void)?

    private(set) var played: [URL] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0
    private(set) var seeks: [TimeInterval] = []

    func play(_ url: URL) {
        played.append(url)
    }

    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
    func stop() { stopCount += 1 }
    func seek(to position: TimeInterval) { seeks.append(position) }

    /// Stands in for the player's own progress observer firing.
    func emitProgress(position: TimeInterval, duration: TimeInterval) {
        onProgress?(position, duration)
    }

    func emitFinish() { onFinish?() }
}

@MainActor
final class HistoryViewModelTests: XCTestCase {

    // MARK: - Fixtures

    /// A calendar whose time zone is deliberately *not* UTC, so any accidental UTC
    /// day maths in the view model shows up as a wrong grouping rather than passing.
    private func calendar(_ timeZoneID: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// An instant, specified in UTC. Tests then hand the view model a calendar in
    /// some other zone, which is the only way to tell "grouped by local day" apart
    /// from "grouped by UTC day".
    private func instant(_ year: Int, _ month: Int, _ day: Int,
                         _ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar("UTC").date(from: components)!
    }

    private func record(
        id: UUID = UUID(),
        finalText: String = "final transcript",
        rawText: String = "raw transcript",
        startedAt: Date? = nil,
        modeID: String = "email",
        targetBundleID: String? = "com.apple.mail",
        targetAppName: String? = "Mail",
        audioFileName: String? = "session-a.flac",
        outcome: DictationOutcome = .inserted
    ) -> DictationRecord {
        DictationRecord(
            id: id,
            startedAt: startedAt ?? instant(2026, 7, 20, 12),
            speakingDuration: 8,
            rawText: rawText,
            finalText: finalText,
            modeID: modeID,
            targetBundleID: targetBundleID,
            targetAppName: targetAppName,
            wordCount: TextMetrics.wordCount(finalText),
            rawWordCount: TextMetrics.wordCount(rawText),
            segmentCount: 1,
            timings: Timings(captureMs: 1, convertMs: 2, uploadMs: 3,
                             whisperMs: 4, llmMs: 5, insertMs: 6, totalMs: 21),
            insertionOutcome: "insertedDirect",
            retryCount: 0,
            editDistanceRawToFinal: 0.1,
            audioFileName: audioFileName,
            audioBytes: 1024,
            estimatedCostUSD: 0.001,
            vocabularyTermsSent: 0,
            voiceProcessingActive: true,
            outcome: outcome)
    }

    /// Everything the view model needs, with every seam captured so a test can
    /// assert on it. `audio` maps a file name to a URL; returning nil is how this
    /// suite models "purged by the retention sweep" or "file gone".
    private struct Harness {
        let viewModel: HistoryViewModel
        let player: SpyHistoryAudioPlayer
        let copied: Box<[String]>
        let inserted: Box<[(text: String, target: HistoryViewModel.Target?)]>
        let deleted: Box<[UUID]>
        let retriedTranscription: Box<[UUID]>
        let retriedMode: Box<[UUID]>
        let frontmost: Box<HistoryViewModel.Target?>
        let loadCount: Box<Int>
    }

    /// A reference cell, so a closure can report back into a `let` harness.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func makeHarness(
        records: [DictationRecord],
        timeZoneID: String = "Asia/Kathmandu",
        now: Date? = nil,
        audio: @escaping (String) -> URL? = { URL(fileURLWithPath: "/tmp/captur-test-audio/\($0)") },
        modeNames: [String: String] = ["email": "Email", "slack": "Slack Message"]
    ) -> Harness {
        let player = SpyHistoryAudioPlayer()
        let copied = Box<[String]>([])
        let inserted = Box<[(text: String, target: HistoryViewModel.Target?)]>([])
        let deleted = Box<[UUID]>([])
        let retriedTranscription = Box<[UUID]>([])
        let retriedMode = Box<[UUID]>([])
        let frontmost = Box<HistoryViewModel.Target?>(
            HistoryViewModel.Target(bundleID: "com.apple.mail", name: "Mail"))
        let loadCount = Box<Int>(0)
        let stored = Box<[DictationRecord]>(records)
        // Resolved up front rather than inside the closure: the clock seam must be a
        // plain value, not a call back into this test case.
        let fixedNow = now ?? instant(2026, 7, 20, 18)

        let viewModel = HistoryViewModel(
            records: {
                loadCount.value += 1
                return stored.value
            },
            deleteRecord: { id in
                deleted.value.append(id)
                stored.value.removeAll { $0.id == id }
            },
            modeName: { modeNames[$0] ?? $0 },
            copyText: { copied.value.append($0) },
            reinsert: { text, target in inserted.value.append((text, target)) },
            retryTranscription: { retriedTranscription.value.append($0) },
            retryMode: { retriedMode.value.append($0) },
            audioURL: audio,
            player: player,
            frontmostTarget: { frontmost.value },
            calendar: calendar(timeZoneID),
            now: { fixedNow })

        return Harness(viewModel: viewModel,
                       player: player,
                       copied: copied,
                       inserted: inserted,
                       deleted: deleted,
                       retriedTranscription: retriedTranscription,
                       retriedMode: retriedMode,
                       frontmost: frontmost,
                       loadCount: loadCount)
    }

    /// Every row currently visible, flattened in display order.
    private func visibleRows(_ viewModel: HistoryViewModel) -> [HistoryRow] {
        viewModel.groups.flatMap(\.rows)
    }

    // MARK: - Search

    func testSearchMatchesFinalTextIgnoringCase() async {
        let harness = makeHarness(records: [
            record(finalText: "Ship the Kraken today"),
            record(finalText: "Nothing to see"),
        ])
        await harness.viewModel.load()

        harness.viewModel.query = "kRaKeN"

        XCTAssertEqual(visibleRows(harness.viewModel).map(\.record.finalText),
                       ["Ship the Kraken today"])
    }

    func testSearchMatchesRawText() async {
        // The whole point of keeping rawText: the user remembers what they *said*,
        // not what the mode rewrote it into.
        let harness = makeHarness(records: [
            record(finalText: "Q3 results attached.",
                   rawText: "um so anyway the quarterly numbers"),
            record(finalText: "Buy milk.", rawText: "reminder to buy milk"),
        ])
        await harness.viewModel.load()

        harness.viewModel.query = "QUARTERLY"

        XCTAssertEqual(visibleRows(harness.viewModel).map(\.record.finalText),
                       ["Q3 results attached."])
    }

    func testSearchMatchesAppName() async {
        let harness = makeHarness(records: [
            record(finalText: "one", targetBundleID: "com.tinyspeck.slackmacgap",
                   targetAppName: "Slack"),
            record(finalText: "two", targetBundleID: "com.apple.mail", targetAppName: "Mail"),
        ])
        await harness.viewModel.load()

        harness.viewModel.query = "slack"

        XCTAssertEqual(visibleRows(harness.viewModel).map(\.record.finalText), ["one"])
    }

    func testSearchMatchesModeName() async {
        // "slack" here is the MODE's display name, not the target app: the record
        // went to Mail. Matching requires the mode-name lookup, not the record alone.
        let harness = makeHarness(records: [
            record(finalText: "one", modeID: "slack",
                   targetBundleID: "com.apple.mail", targetAppName: "Mail"),
            record(finalText: "two", modeID: "email",
                   targetBundleID: "com.apple.mail", targetAppName: "Mail"),
        ])
        await harness.viewModel.load()

        harness.viewModel.query = "slack message"

        XCTAssertEqual(visibleRows(harness.viewModel).map(\.record.finalText), ["one"])
    }

    func testNoSearchMatchesIsDistinctFromNoDictations() async {
        let harness = makeHarness(records: [record(finalText: "hello")])
        await harness.viewModel.load()

        harness.viewModel.query = "zzzz"

        XCTAssertTrue(harness.viewModel.groups.isEmpty)
        XCTAssertTrue(harness.viewModel.hasNoSearchMatches)
        XCTAssertFalse(harness.viewModel.hasNoDictations)
    }

    func testEmptyLogReportsNoDictations() async {
        let harness = makeHarness(records: [])
        await harness.viewModel.load()

        XCTAssertTrue(harness.viewModel.hasNoDictations)
        XCTAssertFalse(harness.viewModel.hasNoSearchMatches)
    }

    func testSearchDoesNotReReadTheLog() async {
        // Spec §15 and the log's own 5,000-record budget: a keystroke filters an
        // in-memory snapshot. Re-reading records.jsonl per keystroke would make the
        // search field unusable on a real history.
        let harness = makeHarness(records: (0..<20).map { record(finalText: "line \($0)") })
        await harness.viewModel.load()
        XCTAssertEqual(harness.loadCount.value, 1)

        for prefix in ["l", "li", "lin", "line", "line 1"] {
            harness.viewModel.query = prefix
        }

        XCTAssertEqual(harness.loadCount.value, 1)
    }

    func testFilteringLargeHistoryPerKeystrokeStaysCheap() async {
        let records = (0..<5_000).map { index in
            record(finalText: "dictation number \(index) about shipping",
                   rawText: "raw \(index)",
                   modeID: index.isMultiple(of: 2) ? "email" : "slack")
        }
        let harness = makeHarness(records: records)
        await harness.viewModel.load()

        let queries = ["s", "sh", "shi", "ship", "shipp", "shippi", "shippin", "shipping",
                       "number 4", "number 49", "number 499", "number 4999"]
        let started = Date()
        for query in queries { harness.viewModel.query = query }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(visibleRows(harness.viewModel).count, 1)
        // Generous by an order of magnitude — this catches an accidental O(n²)
        // filter or a per-comparison `lowercased()`, not machine speed.
        XCTAssertLessThan(elapsed, 3.0, "per-keystroke filter took \(elapsed)s over 5,000 records")
    }

    // MARK: - Scope chips

    func testModeChipFiltersByMode() async {
        let harness = makeHarness(records: [
            record(finalText: "mailed", modeID: "email"),
            record(finalText: "slacked", modeID: "slack"),
        ])
        await harness.viewModel.load()

        harness.viewModel.modeFilter = "slack"

        XCTAssertEqual(visibleRows(harness.viewModel).map(\.record.finalText), ["slacked"])
    }

    func testAppChipFiltersByApp() async {
        let harness = makeHarness(records: [
            record(finalText: "to mail", targetBundleID: "com.apple.mail", targetAppName: "Mail"),
            record(finalText: "to notes", targetBundleID: "com.apple.Notes", targetAppName: "Notes"),
        ])
        await harness.viewModel.load()

        harness.viewModel.appFilter = "com.apple.Notes"

        XCTAssertEqual(visibleRows(harness.viewModel).map(\.record.finalText), ["to notes"])
    }

    func testModeAndAppChipsIntersect() async {
        let harness = makeHarness(records: [
            record(finalText: "a", modeID: "email", targetBundleID: "com.apple.mail", targetAppName: "Mail"),
            record(finalText: "b", modeID: "email", targetBundleID: "com.apple.Notes", targetAppName: "Notes"),
            record(finalText: "c", modeID: "slack", targetBundleID: "com.apple.Notes", targetAppName: "Notes"),
        ])
        await harness.viewModel.load()

        harness.viewModel.modeFilter = "email"
        harness.viewModel.appFilter = "com.apple.Notes"

        XCTAssertEqual(visibleRows(harness.viewModel).map(\.record.finalText), ["b"])
    }

    func testClearScopeRestoresEverythingButKeepsQuery() async {
        let harness = makeHarness(records: [
            record(finalText: "alpha one", modeID: "email"),
            record(finalText: "alpha two", modeID: "slack"),
            record(finalText: "beta", modeID: "slack"),
        ])
        await harness.viewModel.load()
        harness.viewModel.query = "alpha"
        harness.viewModel.modeFilter = "slack"
        XCTAssertEqual(visibleRows(harness.viewModel).count, 1)

        harness.viewModel.clearScope()

        XCTAssertNil(harness.viewModel.modeFilter)
        XCTAssertNil(harness.viewModel.appFilter)
        XCTAssertEqual(harness.viewModel.query, "alpha")
        XCTAssertEqual(visibleRows(harness.viewModel).count, 2)
    }

    func testChipsAreDerivedFromTheSnapshotWithCounts() async {
        let harness = makeHarness(records: [
            record(modeID: "email", targetBundleID: "com.apple.mail", targetAppName: "Mail"),
            record(modeID: "email", targetBundleID: "com.apple.Notes", targetAppName: "Notes"),
            record(modeID: "slack", targetBundleID: "com.apple.Notes", targetAppName: "Notes"),
        ])
        await harness.viewModel.load()

        XCTAssertEqual(harness.viewModel.modeChips.map(\.id).sorted(), ["email", "slack"])
        XCTAssertEqual(harness.viewModel.modeChips.first { $0.id == "email" }?.count, 2)
        XCTAssertEqual(harness.viewModel.modeChips.first { $0.id == "email" }?.title, "Email")
        XCTAssertEqual(harness.viewModel.appChips.map(\.id).sorted(),
                       ["com.apple.Notes", "com.apple.mail"])
        XCTAssertEqual(harness.viewModel.appChips.first { $0.id == "com.apple.Notes" }?.count, 2)
    }

    // MARK: - Day grouping

    func testGroupsByLocalDayNotUTCDay() async {
        // Kathmandu is UTC+5:45. 12:00 UTC is the 20th locally; 20:30 UTC is already
        // 02:15 on the 21st. Grouping by UTC day would collapse these into one.
        let harness = makeHarness(records: [
            record(finalText: "afternoon", startedAt: instant(2026, 7, 20, 12)),
            record(finalText: "after midnight", startedAt: instant(2026, 7, 20, 20, 30)),
        ], timeZoneID: "Asia/Kathmandu")
        await harness.viewModel.load()

        XCTAssertEqual(harness.viewModel.groups.count, 2)
        XCTAssertEqual(harness.viewModel.groups.flatMap { $0.rows.map(\.record.finalText) },
                       ["after midnight", "afternoon"])
    }

    func testGroupsAcrossADSTBoundaryUseTheLongLocalDay() async {
        // 2026-03-08 is 23 hours long in New York (spring forward at 02:00 local).
        // 06:30Z is 01:30 EST on the 8th; 03:00Z the next UTC day is 23:00 EDT still
        // on the 8th. One local day, two UTC days.
        let harness = makeHarness(records: [
            record(finalText: "before the jump", startedAt: instant(2026, 3, 8, 6, 30)),
            record(finalText: "late that night", startedAt: instant(2026, 3, 9, 3)),
        ], timeZoneID: "America/New_York", now: instant(2026, 3, 10, 12))
        await harness.viewModel.load()

        XCTAssertEqual(harness.viewModel.groups.count, 1)
        XCTAssertEqual(harness.viewModel.groups.first?.rows.count, 2)

        let expectedDay = calendar("America/New_York")
            .startOfDay(for: instant(2026, 3, 8, 6, 30))
        XCTAssertEqual(harness.viewModel.groups.first?.day, expectedDay)
    }

    func testGroupTitlesUseTodayAndYesterdayRelativeToInjectedNow() async {
        let now = instant(2026, 7, 20, 12)                     // 17:45 local
        let harness = makeHarness(records: [
            record(finalText: "today", startedAt: instant(2026, 7, 20, 9)),
            record(finalText: "yesterday", startedAt: instant(2026, 7, 19, 9)),
            record(finalText: "last week", startedAt: instant(2026, 7, 13, 9)),
        ], timeZoneID: "Asia/Kathmandu", now: now)
        await harness.viewModel.load()

        let titles = harness.viewModel.groups.map(\.title)
        XCTAssertEqual(titles.count, 3)
        XCTAssertEqual(titles[0], "Today")
        XCTAssertEqual(titles[1], "Yesterday")
        XCTAssertFalse(titles[2].isEmpty)
        XCTAssertFalse(["Today", "Yesterday"].contains(titles[2]))
    }

    func testGroupsAndRowsAreNewestFirst() async {
        let harness = makeHarness(records: [
            record(finalText: "old", startedAt: instant(2026, 7, 18, 9)),
            record(finalText: "newest", startedAt: instant(2026, 7, 20, 11)),
            record(finalText: "earlier today", startedAt: instant(2026, 7, 20, 9)),
        ])
        await harness.viewModel.load()

        XCTAssertEqual(harness.viewModel.groups.flatMap { $0.rows.map(\.record.finalText) },
                       ["newest", "earlier today", "old"])
    }

    func testRowTimeLabelUsesTheInjectedZoneNotTheSystemZone() async {
        // 12:00 UTC is 17:45 in Kathmandu. A formatter left on the system zone would
        // label rows in a different day than the one they are grouped under.
        let harness = makeHarness(records: [record()], timeZoneID: "Asia/Kathmandu")
        await harness.viewModel.load()

        XCTAssertTrue(harness.viewModel.timeOfDay(instant(2026, 7, 20, 12)).contains("5:45"),
                      "unexpected time label: \(harness.viewModel.timeOfDay(instant(2026, 7, 20, 12)))")
    }

    // MARK: - Re-insert target, captured on open

    func testInsertionTargetIsCapturedOnOpen() async {
        let harness = makeHarness(records: [record()])
        harness.frontmost.value = HistoryViewModel.Target(bundleID: "com.apple.Notes", name: "Notes")

        harness.viewModel.captureInsertionTarget()

        XCTAssertEqual(harness.viewModel.insertionTarget?.bundleID, "com.apple.Notes")
    }

    func testReinsertUsesTheTargetCapturedOnOpenNotTheCurrentFrontmostApp() async {
        // The defect this exists to prevent: opening History makes *Captur*
        // frontmost, so reading the frontmost app at re-insert time types the text
        // into Captur's own window instead of the app the user was working in.
        let harness = makeHarness(records: [record(finalText: "put me back")])
        harness.frontmost.value = HistoryViewModel.Target(bundleID: "com.apple.Notes", name: "Notes")
        harness.viewModel.captureInsertionTarget()
        await harness.viewModel.load()

        // Captur is now frontmost, as it always is once the window is open.
        harness.frontmost.value = HistoryViewModel.Target(bundleID: "com.awah.captur", name: "Captur")

        await harness.viewModel.reinsert(visibleRows(harness.viewModel)[0])

        XCTAssertEqual(harness.inserted.value.count, 1)
        XCTAssertEqual(harness.inserted.value[0].text, "put me back")
        XCTAssertEqual(harness.inserted.value[0].target?.bundleID, "com.apple.Notes")
    }

    func testReinsertDoesNothingForARecordWithNoFinalText() async {
        let harness = makeHarness(records: [
            record(finalText: "", audioFileName: "session-c.flac", outcome: .cancelled),
        ])
        harness.viewModel.captureInsertionTarget()
        await harness.viewModel.load()

        let row = visibleRows(harness.viewModel)[0]
        XCTAssertFalse(row.canReinsert)
        await harness.viewModel.reinsert(row)

        XCTAssertTrue(harness.inserted.value.isEmpty)
    }

    // MARK: - Copy

    func testCopyGoesThroughTheInjectedClipboardSeam() async {
        let harness = makeHarness(records: [record(finalText: "clip this")])
        await harness.viewModel.load()

        harness.viewModel.copy(visibleRows(harness.viewModel)[0])

        XCTAssertEqual(harness.copied.value, ["clip this"])
    }

    // MARK: - Delete

    func testDeleteNeedsAnInlineConfirmation() async {
        let target = UUID()
        let harness = makeHarness(records: [record(id: target)])
        await harness.viewModel.load()

        harness.viewModel.requestDelete(target)

        XCTAssertEqual(harness.viewModel.pendingDeleteID, target)
        XCTAssertTrue(harness.deleted.value.isEmpty, "requesting a delete must not delete anything")

        await harness.viewModel.confirmDelete()

        XCTAssertEqual(harness.deleted.value, [target])
        XCTAssertNil(harness.viewModel.pendingDeleteID)
        XCTAssertTrue(harness.viewModel.hasNoDictations)
    }

    func testCancellingAConfirmDeletesNothing() async {
        let target = UUID()
        let harness = makeHarness(records: [record(id: target)])
        await harness.viewModel.load()
        harness.viewModel.requestDelete(target)

        harness.viewModel.cancelDelete()
        await harness.viewModel.confirmDelete()

        XCTAssertTrue(harness.deleted.value.isEmpty)
        XCTAssertNil(harness.viewModel.pendingDeleteID)
        XCTAssertEqual(visibleRows(harness.viewModel).count, 1)
    }

    func testDeleteWhileSearchingRemovesTheRequestedRecordNotThePositionalOne() async {
        // The classic version of this bug: the visible list is a filtered subset, so
        // "row 2" in the UI is a different element from "index 2" in the snapshot.
        // Deleting a record is irreversible, so this must be keyed by id.
        let alpha = UUID(), beta = UUID(), gamma = UUID(), delta = UUID()
        let harness = makeHarness(records: [
            record(id: alpha, finalText: "alpha unmatched"),
            record(id: beta, finalText: "beta MATCHES here"),
            record(id: gamma, finalText: "gamma unmatched"),
            record(id: delta, finalText: "delta matches too"),
        ])
        await harness.viewModel.load()
        harness.viewModel.query = "matches"

        let visible = visibleRows(harness.viewModel)
        XCTAssertEqual(visible.count, 2)
        let secondVisible = visible[1]

        harness.viewModel.requestDelete(secondVisible.id)
        await harness.viewModel.confirmDelete()

        XCTAssertEqual(harness.deleted.value, [secondVisible.id])
        XCTAssertEqual(visibleRows(harness.viewModel).map(\.id), [visible[0].id])

        // And the records the search hid are all still there.
        harness.viewModel.query = ""
        let remaining = Set(visibleRows(harness.viewModel).map(\.id))
        XCTAssertTrue(remaining.contains(alpha))
        XCTAssertTrue(remaining.contains(gamma))
        XCTAssertEqual(remaining.count, 3)
    }

    func testDeletingTheLastRecordOfADayRemovesItsGroup() async {
        let lonely = UUID()
        let harness = makeHarness(records: [
            record(id: lonely, startedAt: instant(2026, 7, 18, 9)),
            record(startedAt: instant(2026, 7, 20, 9)),
        ])
        await harness.viewModel.load()
        XCTAssertEqual(harness.viewModel.groups.count, 2)

        harness.viewModel.requestDelete(lonely)
        await harness.viewModel.confirmDelete()

        XCTAssertEqual(harness.viewModel.groups.count, 1)
    }

    func testDeletingTheExpandedRowCollapsesAndStopsPlayback() async {
        let target = UUID()
        let harness = makeHarness(records: [record(id: target)])
        await harness.viewModel.load()
        harness.viewModel.toggleExpansion(target)
        harness.viewModel.togglePlayback(visibleRows(harness.viewModel)[0])

        harness.viewModel.requestDelete(target)
        await harness.viewModel.confirmDelete()

        XCTAssertNil(harness.viewModel.expandedRecordID)
        XCTAssertNil(harness.viewModel.playback)
        XCTAssertEqual(harness.player.stopCount, 1)
    }

    // MARK: - Cancelled and failed records

    func testCancelledRecordsAreVisibleAndMarked() async {
        // Spec §4.1: a cancelled capture still writes audio and still appears here,
        // marked, "so nothing spoken is ever lost". Hiding them breaks that promise.
        let harness = makeHarness(records: [
            record(finalText: "kept", outcome: .inserted),
            record(finalText: "", rawText: "half a sentence", outcome: .cancelled),
        ])
        await harness.viewModel.load()

        let rows = visibleRows(harness.viewModel)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter(\.isCancelled).count, 1)
        XCTAssertEqual(rows.first(where: \.isCancelled)?.statusLabel, "Cancelled")
    }

    func testFailedRecordSurfacesItsReason() async {
        let harness = makeHarness(records: [
            record(outcome: .failed(reason: "Groq returned 429")),
        ])
        await harness.viewModel.load()

        let row = visibleRows(harness.viewModel)[0]
        XCTAssertTrue(row.isFailed)
        XCTAssertEqual(row.failureReason, "Groq returned 429")
        XCTAssertTrue(row.canRetryTranscription)
    }

    // MARK: - Retry

    func testRetryTranscriptionIsOfferedForAPartialTranscriptMarkedInserted() async {
        // Known spec-vs-spec conflict: a capture where one segment permanently failed
        // is written with outcome `.inserted` (DictationRecordDraft line 91), not
        // `.failed`. The retryable signal is therefore the stitcher's failure marker
        // in the final text, not the outcome.
        let harness = makeHarness(records: [
            record(finalText: "the first half \(TranscriptStitcher.failureMarker) the rest is gone",
                   outcome: .inserted),
            record(finalText: "complete and clean", outcome: .inserted),
        ])
        await harness.viewModel.load()

        let rows = visibleRows(harness.viewModel)
        let partial = rows.first { $0.hasPartialTranscript }
        XCTAssertNotNil(partial)
        XCTAssertTrue(partial!.canRetryTranscription)
        XCTAssertFalse(rows.first { !$0.hasPartialTranscript }!.canRetryTranscription)
    }

    func testPartialSelectionEditOffersRetryFromRawTranscript() async {
        let harness = makeHarness(records: [
            record(finalText: "Original selection",
                   rawText: "\(TranscriptStitcher.failureMarker) make it uppercase", outcome: .inserted),
        ])
        await harness.viewModel.load()
        let row = visibleRows(harness.viewModel)[0]
        XCTAssertTrue(row.hasPartialTranscript)
        XCTAssertTrue(row.canRetryTranscription)
        XCTAssertEqual(row.statusLabel, "Partial")
    }

    func testRetryTranscriptionIsNotOfferedOnceTheAudioIsPurged() async {
        // `retry(recordID:)` reads the session file. With nothing to read there is no
        // retry to offer — a dead button is worse than an absent one.
        let harness = makeHarness(records: [
            record(finalText: "gap \(TranscriptStitcher.failureMarker) here",
                   audioFileName: nil,
                   outcome: .failed(reason: "segment 2 failed")),
        ])
        await harness.viewModel.load()

        XCTAssertFalse(visibleRows(harness.viewModel)[0].canRetryTranscription)
    }

    func testRetryTranscriptionCallsTheInjectedClosureWithTheRecordID() async {
        let target = UUID()
        let harness = makeHarness(records: [
            record(id: target, outcome: .failed(reason: "boom")),
        ])
        await harness.viewModel.load()

        await harness.viewModel.retryTranscription(visibleRows(harness.viewModel)[0])

        XCTAssertEqual(harness.retriedTranscription.value, [target])
    }

    func testRetryModeCallsTheInjectedClosureWithTheRecordID() async {
        let target = UUID()
        let harness = makeHarness(records: [record(id: target, rawText: "the raw words")])
        await harness.viewModel.load()

        let row = visibleRows(harness.viewModel)[0]
        XCTAssertTrue(row.canRetryMode)
        await harness.viewModel.retryMode(row)

        XCTAssertEqual(harness.retriedMode.value, [target])
    }

    func testRetryModeIsNotOfferedWithoutARawTranscript() async {
        let harness = makeHarness(records: [record(finalText: "", rawText: "", outcome: .cancelled)])
        await harness.viewModel.load()

        XCTAssertFalse(visibleRows(harness.viewModel)[0].canRetryMode)
    }

    // MARK: - Inline expansion

    func testExpansionTogglesOneRowAtATime() async {
        let first = UUID(), second = UUID()
        let harness = makeHarness(records: [
            record(id: first, startedAt: instant(2026, 7, 20, 11)),
            record(id: second, startedAt: instant(2026, 7, 20, 9)),
        ])
        await harness.viewModel.load()

        harness.viewModel.toggleExpansion(first)
        XCTAssertEqual(harness.viewModel.expandedRecordID, first)

        harness.viewModel.toggleExpansion(second)
        XCTAssertEqual(harness.viewModel.expandedRecordID, second)

        harness.viewModel.toggleExpansion(second)
        XCTAssertNil(harness.viewModel.expandedRecordID)
    }

    // MARK: - Playback

    func testExpandingARowWhoseAudioWasPurgedOffersNoScrubber() async {
        let target = UUID()
        let harness = makeHarness(records: [record(id: target, audioFileName: nil)])
        await harness.viewModel.load()

        harness.viewModel.toggleExpansion(target)

        XCTAssertNil(harness.viewModel.expandedAudioURL)
        XCTAssertFalse(harness.viewModel.canPlayExpandedRow)
    }

    func testExpandingARowWhoseAudioFileIsGoneOffersNoScrubber() async {
        let target = UUID()
        let harness = makeHarness(records: [record(id: target, audioFileName: "session-gone.flac")],
                                  audio: { _ in nil })
        await harness.viewModel.load()

        harness.viewModel.toggleExpansion(target)

        XCTAssertNil(harness.viewModel.expandedAudioURL)
        XCTAssertFalse(harness.viewModel.canPlayExpandedRow)
    }

    func testPlaybackIsNeverStartedForARowWithoutAudio() async {
        let harness = makeHarness(records: [record(audioFileName: nil)])
        await harness.viewModel.load()

        harness.viewModel.togglePlayback(visibleRows(harness.viewModel)[0])

        XCTAssertTrue(harness.player.played.isEmpty)
        XCTAssertNil(harness.viewModel.playback)
    }

    func testPlaybackTargetsTheSessionFile() async {
        // `audioFileName` is the continuous SESSION file, not a segment temporary.
        let harness = makeHarness(records: [record(audioFileName: "session-42.flac")],
                                  audio: { URL(fileURLWithPath: "/audio/\($0)") })
        await harness.viewModel.load()

        harness.viewModel.togglePlayback(visibleRows(harness.viewModel)[0])

        XCTAssertEqual(harness.player.played.map(\.path), ["/audio/session-42.flac"])
        XCTAssertEqual(harness.viewModel.playback?.isPlaying, true)
    }

    func testPlaybackProgressComesFromThePlayersOwnObserver() async {
        // No polling timer anywhere: the position advances because the player told us,
        // which is also why an idle History costs nothing (spec §15).
        let harness = makeHarness(records: [record()])
        await harness.viewModel.load()
        harness.viewModel.togglePlayback(visibleRows(harness.viewModel)[0])

        harness.player.emitProgress(position: 3.5, duration: 8)

        XCTAssertEqual(harness.viewModel.playback?.position, 3.5)
        XCTAssertEqual(harness.viewModel.playback?.duration, 8)
    }

    func testTogglingPlaybackOnThePlayingRowPauses() async {
        let harness = makeHarness(records: [record()])
        await harness.viewModel.load()
        let row = visibleRows(harness.viewModel)[0]

        harness.viewModel.togglePlayback(row)
        harness.viewModel.togglePlayback(row)

        XCTAssertEqual(harness.player.pauseCount, 1)
        XCTAssertEqual(harness.viewModel.playback?.isPlaying, false)

        harness.viewModel.togglePlayback(row)
        XCTAssertEqual(harness.player.resumeCount, 1)
        XCTAssertEqual(harness.player.played.count, 1, "resuming must not reload the file")
    }

    func testStartingPlaybackOnAnotherRowStopsTheFirst() async {
        let first = UUID(), second = UUID()
        let harness = makeHarness(records: [
            record(id: first, startedAt: instant(2026, 7, 20, 11), audioFileName: "one.flac"),
            record(id: second, startedAt: instant(2026, 7, 20, 9), audioFileName: "two.flac"),
        ])
        await harness.viewModel.load()
        let rows = visibleRows(harness.viewModel)

        harness.viewModel.togglePlayback(rows[0])
        harness.viewModel.togglePlayback(rows[1])

        XCTAssertEqual(harness.player.stopCount, 1)
        XCTAssertEqual(harness.player.played.map(\.lastPathComponent), ["one.flac", "two.flac"])
        XCTAssertEqual(harness.viewModel.playback?.recordID, second)
    }

    func testSeekForwardsToThePlayerAndUpdatesThePosition() async {
        let harness = makeHarness(records: [record()])
        await harness.viewModel.load()
        harness.viewModel.togglePlayback(visibleRows(harness.viewModel)[0])
        harness.player.emitProgress(position: 1, duration: 10)

        harness.viewModel.seek(to: 6.25)

        XCTAssertEqual(harness.player.seeks, [6.25])
        XCTAssertEqual(harness.viewModel.playback?.position, 6.25)
    }

    func testFinishingPlaybackClearsIt() async {
        let harness = makeHarness(records: [record()])
        await harness.viewModel.load()
        harness.viewModel.togglePlayback(visibleRows(harness.viewModel)[0])

        harness.player.emitFinish()

        XCTAssertNil(harness.viewModel.playback)
    }

    func testCollapsingTheExpandedRowStopsPlayback() async {
        let target = UUID()
        let harness = makeHarness(records: [record(id: target)])
        await harness.viewModel.load()
        harness.viewModel.toggleExpansion(target)
        harness.viewModel.togglePlayback(visibleRows(harness.viewModel)[0])

        harness.viewModel.toggleExpansion(target)

        XCTAssertEqual(harness.player.stopCount, 1)
        XCTAssertNil(harness.viewModel.playback)
    }
}
