import XCTest
@testable import Captur

final class DictationRecordLogTests: XCTestCase {
    func testContextMetadataDecodesLegacyRowsAndRoundTripsWithoutRawContext() throws {
        var original = record()
        original.contextSummary = "selection: 12 UTF-16 units"
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(DictationRecord.self, from: data), original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "contextSummary")
        let legacy = try JSONDecoder().decode(DictationRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.contextSummary)
        XCTAssertEqual(legacy.rawText, original.rawText)
    }

    // MARK: - Fixtures

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-records-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeLogURL() throws -> URL {
        try makeDirectory().appendingPathComponent("records.jsonl")
    }

    /// Whole-second epoch dates keep the `.secondsSince1970` round-trip bit-exact,
    /// so a full-struct equality assertion is meaningful rather than flaky.
    private func date(offsetDays: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_784_000_000 + Double(offsetDays) * 86_400)
    }

    private func record(
        id: UUID = UUID(),
        startedAt: Date? = nil,
        finalText: String = "final text here",
        outcome: DictationOutcome = .inserted
    ) -> DictationRecord {
        DictationRecord(
            id: id,
            startedAt: startedAt ?? date(),
            speakingDuration: 12.5,
            rawText: "raw text here",
            finalText: finalText,
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
            retryCount: 1,
            editDistanceRawToFinal: 0.25,
            audioFileName: "session-1.m4a",
            audioBytes: 4096,
            estimatedCostUSD: 0.0031,
            vocabularyTermsSent: 7,
            voiceProcessingActive: true,
            outcome: outcome
        )
    }

    private func backups(besides url: URL) throws -> [URL] {
        let directory = url.deletingLastPathComponent()
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("records.jsonl.corrupt-") }
    }

    private func lines(of url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Missing and empty files

    func testMissingFileReturnsEmptyWithoutThrowing() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let all = try await log.all()
        XCTAssertTrue(all.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEmptyFileReturnsEmpty() async throws {
        let url = try makeLogURL()
        try Data().write(to: url)
        let log = DictationRecordLog(fileURL: url)
        let all = try await log.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testWhitespaceOnlyFileReturnsEmpty() async throws {
        let url = try makeLogURL()
        try Data("\n\n  \n".utf8).write(to: url)
        let log = DictationRecordLog(fileURL: url)
        let all = try await log.all()
        XCTAssertTrue(all.isEmpty)
        XCTAssertTrue(try backups(besides: url).isEmpty, "Blank lines are not corruption")
    }

    func testRecordLookupOnAMissingFileReturnsNil() async throws {
        let log = DictationRecordLog(fileURL: try makeLogURL())
        let found = try await log.record(id: UUID())
        XCTAssertNil(found)
    }

    // MARK: - Append / read round trip

    func testAppendReadRoundTripPreservesEveryField() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let original = record()
        try await log.append(original)

        let all = try await log.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first, original)
    }

    func testFailedOutcomeAssociatedValueSurvivesTheRoundTrip() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let failed = record(outcome: .failed(reason: "whisper timed out after 30s"))
        let cancelled = record(outcome: .cancelled)
        try await log.append(failed)
        try await log.append(cancelled)

        let all = try await log.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].outcome, .failed(reason: "whisper timed out after 30s"))
        XCTAssertEqual(all[1].outcome, .cancelled)
        XCTAssertEqual(all[0], failed)
        XCTAssertEqual(all[1], cancelled)
    }

    func testNilOptionalFieldsSurviveTheRoundTrip() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        var purged = record()
        purged.audioFileName = nil
        purged.targetBundleID = nil
        purged.targetAppName = nil
        try await log.append(purged)

        let all = try await log.all()
        XCTAssertEqual(all.first, purged)
        XCTAssertNil(all.first?.audioFileName)
    }

    func testAppendPreservesInsertionOrder() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let records = (0..<5).map { record(finalText: "text \($0)") }
        for item in records {
            try await log.append(item)
        }

        let all = try await log.all()
        XCTAssertEqual(all.map(\.id), records.map(\.id))
    }

    func testTextWithNewlinesDoesNotBreakTheLineFraming() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let multiline = record(finalText: "first line\nsecond line\n\nfourth")
        try await log.append(multiline)
        try await log.append(record(finalText: "plain"))

        XCTAssertEqual(try lines(of: url).count, 2, "One JSON object per line")
        let all = try await log.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.finalText, "first line\nsecond line\n\nfourth")
    }

    // MARK: - On-disk format

    func testEachLineIsOneCompactJSONObjectAndTheFileIsNewlineTerminated() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        try await log.append(record())
        try await log.append(record())

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.last, UInt8(ascii: "\n"), "Every line is newline-terminated")

        let lines = try self.lines(of: url)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            XCTAssertTrue(object is [String: Any], "Each line decodes as a JSON object")
            XCTAssertFalse(line.contains("\n"))
        }
    }

    /// Dates are stored as `.secondsSince1970` numbers: no formatter parsing on the
    /// read path, and an exact round trip for day-boundary streak math.
    func testDatesAreStoredAsEpochSeconds() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        try await log.append(record(startedAt: date()))

        let line = try XCTUnwrap(lines(of: url).first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let startedAt = try XCTUnwrap(object["startedAt"] as? Double)
        XCTAssertEqual(startedAt, 1_784_000_000, accuracy: 1e-6)
    }

    func testAnArbitraryDateRoundTripsWellInsideADay() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let now = Date()
        try await log.append(record(startedAt: now))

        let all = try await log.all()
        let decoded = try XCTUnwrap(all.first?.startedAt)
        XCTAssertEqual(decoded.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }

    /// `append` must not rewrite the file: bytes already on disk are untouched and
    /// exactly one line is added.
    func testAppendOnlyAddsBytesAndNeverRewritesWhatIsAlreadyThere() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        try await log.append(record())
        let firstPass = try Data(contentsOf: url)

        try await log.append(record())
        let secondPass = try Data(contentsOf: url)

        XCTAssertGreaterThan(secondPass.count, firstPass.count)
        XCTAssertEqual(secondPass.prefix(firstPass.count), firstPass)
        XCTAssertEqual(try lines(of: url).count, 2)
    }

    func testAppendCreatesMissingIntermediateDirectories() async throws {
        let nested = try makeDirectory()
            .appendingPathComponent("stats", isDirectory: true)
            .appendingPathComponent("records.jsonl")
        let log = DictationRecordLog(fileURL: nested)
        let item = record()
        try await log.append(item)

        let all = try await log.all()
        XCTAssertEqual(all, [item])
    }

    // MARK: - Corruption

    func testACorruptLineIsSkippedTheFileIsBackedUpAndIntactRecordsStillLoad() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let first = record(finalText: "one")
        let second = record(finalText: "two")
        try await log.append(first)
        try await log.append(second)

        // Simulate a torn write followed by a healthy one.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"not-a-record\",\"star\n".utf8))
        try handle.close()

        let third = record(finalText: "three")
        try await log.append(third)

        let all = try await log.all()
        XCTAssertEqual(all.map(\.finalText), ["one", "two", "three"])

        let backups = try self.backups(besides: url)
        XCTAssertEqual(backups.count, 1, "Corruption is backed up exactly once per file state")

        // The original is never destroyed and still holds the corrupt line.
        let originalText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(originalText.contains("not-a-record"))

        // The backup is a faithful copy of the file as it was found.
        let backupText = try String(contentsOf: XCTUnwrap(backups.first), encoding: .utf8)
        XCTAssertEqual(backupText, originalText)
    }

    func testRepeatedReadsOfTheSameCorruptFileDoNotPileUpBackups() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        try await log.append(record())
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage\n".utf8))
        try handle.close()

        _ = try await log.all()
        _ = try await log.all()
        _ = try await log.all()

        XCTAssertEqual(try backups(besides: url).count, 1)
    }

    func testAFullyCorruptFileStillReturnsEmptyRatherThanThrowing() async throws {
        let url = try makeLogURL()
        try Data("not json at all\nnor this\n".utf8).write(to: url)
        let log = DictationRecordLog(fileURL: url)

        let all = try await log.all()
        XCTAssertTrue(all.isEmpty)
        XCTAssertEqual(try backups(besides: url).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Never erase")
    }

    func testAppendStillWorksAfterCorruptionAndTheNewRecordReadsBack() async throws {
        let url = try makeLogURL()
        try Data("corrupt\n".utf8).write(to: url)
        let log = DictationRecordLog(fileURL: url)
        let fresh = record(finalText: "after the tear")
        try await log.append(fresh)

        let all = try await log.all()
        XCTAssertEqual(all, [fresh])
    }

    // MARK: - Update

    func testUpdateMutatesOneRecordWithoutTouchingItsNeighbours() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let first = record(finalText: "first")
        let middle = record(finalText: "middle")
        let last = record(finalText: "last")
        for item in [first, middle, last] {
            try await log.append(item)
        }

        try await log.update(id: middle.id) { record in
            record.finalText = "middle, edited"
            record.wordCount = 2
            record.audioFileName = nil
        }

        let all = try await log.all()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0], first)
        XCTAssertEqual(all[2], last)
        XCTAssertEqual(all[1].finalText, "middle, edited")
        XCTAssertEqual(all[1].wordCount, 2)
        XCTAssertNil(all[1].audioFileName)
        XCTAssertEqual(all[1].id, middle.id)
        XCTAssertEqual(all[1].rawText, middle.rawText, "Untouched fields survive")
    }

    func testUpdatePreservesOrderAndLineCount() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let records = (0..<4).map { record(finalText: "text \($0)") }
        for item in records {
            try await log.append(item)
        }

        try await log.update(id: records[1].id) { $0.retryCount = 9 }

        XCTAssertEqual(try lines(of: url).count, 4)
        let all = try await log.all()
        XCTAssertEqual(all.map(\.id), records.map(\.id))
        XCTAssertEqual(all[1].retryCount, 9)
    }

    func testUpdatingAnUnknownIDIsANoOp() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let item = record()
        try await log.append(item)
        let before = try Data(contentsOf: url)

        try await log.update(id: UUID()) { $0.finalText = "should not happen" }

        XCTAssertEqual(try Data(contentsOf: url), before)
        let all = try await log.all()
        XCTAssertEqual(all, [item])
    }

    func testUpdateOnAMissingFileIsANoOp() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        try await log.update(id: UUID()) { $0.retryCount = 1 }
        let all = try await log.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testUpdateRewritesAtomicallyAndLeavesNoTempFileBehind() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let item = record()
        try await log.append(item)
        try await log.update(id: item.id) { $0.retryCount = 3 }

        let directory = url.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(contents.map(\.lastPathComponent), ["records.jsonl"])
    }

    // MARK: - Delete

    func testDeleteRemovesExactlyOneRecord() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let first = record(finalText: "first")
        let middle = record(finalText: "middle")
        let last = record(finalText: "last")
        for item in [first, middle, last] {
            try await log.append(item)
        }

        try await log.delete(id: middle.id)

        let all = try await log.all()
        XCTAssertEqual(all, [first, last])
        XCTAssertEqual(try lines(of: url).count, 2)
    }

    func testDeletingTheLastRecordLeavesAnEmptyReadableFile() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let only = record()
        try await log.append(only)

        try await log.delete(id: only.id)

        let all = try await log.all()
        XCTAssertTrue(all.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeletingAnUnknownIDIsANoOp() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let item = record()
        try await log.append(item)
        let before = try Data(contentsOf: url)

        try await log.delete(id: UUID())

        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testDeleteOnAMissingFileIsANoOp() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        try await log.delete(id: UUID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A rewrite drops the unreadable line from the live file — the timestamped
    /// backup taken when it was first seen remains the record of what was lost.
    func testARewriteAfterCorruptionKeepsTheBackupAsTheSalvage() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let keeper = record(finalText: "keeper")
        let doomed = record(finalText: "doomed")
        try await log.append(keeper)
        try await log.append(doomed)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("half a rec\n".utf8))
        try handle.close()

        try await log.delete(id: doomed.id)

        let all = try await log.all()
        XCTAssertEqual(all, [keeper])
        let backups = try self.backups(besides: url)
        XCTAssertEqual(backups.count, 1)
        let backupText = try String(contentsOf: XCTUnwrap(backups.first), encoding: .utf8)
        XCTAssertTrue(backupText.contains("half a rec"))
        XCTAssertTrue(backupText.contains("doomed"))
    }

    // MARK: - Lookup

    func testRecordByIDFindsTheMatchAndMissesTheRest() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        let wanted = record(finalText: "wanted")
        try await log.append(record())
        try await log.append(wanted)
        try await log.append(record())

        let found = try await log.record(id: wanted.id)
        XCTAssertEqual(found, wanted)
        let missing = try await log.record(id: UUID())
        XCTAssertNil(missing)
    }

    // MARK: - Performance

    func testReadingFiveThousandRecordsIsUnderFiveHundredMilliseconds() async throws {
        let url = try makeLogURL()
        let log = DictationRecordLog(fileURL: url)
        for index in 0..<5_000 {
            try await log.append(
                record(
                    startedAt: date(offsetDays: -index % 400),
                    finalText: "Record number \(index) with a realistic sentence of dictated text."
                )
            )
        }

        let start = Date()
        let all = try await log.all()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(all.count, 5_000)
        XCTAssertLessThan(
            elapsed,
            0.5,
            "Reading 5,000 records took \(String(format: "%.1f", elapsed * 1000)) ms"
        )
        print("[perf] 5,000-record read: \(String(format: "%.1f", elapsed * 1000)) ms")
    }
}
