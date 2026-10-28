import XCTest
@testable import Captur

@MainActor
final class CaptureStoreTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickcapture-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeStore() throws -> CaptureStore {
        CaptureStore(baseURL: try makeDirectory())
    }

    func testUpsertInsertsAndSortsNewestFirst() throws {
        let store = try makeStore()
        let older = Capture(
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .success,
            text: "old"
        )
        let newer = Capture(
            createdAt: Date(timeIntervalSince1970: 2_000),
            status: .success,
            text: "new"
        )
        store.upsert(older)
        store.upsert(newer)
        XCTAssertEqual(store.captures.first?.text, "new")
        XCTAssertEqual(store.captures.count, 2)
    }

    func testUpsertUpdatesExisting() throws {
        let store = try makeStore()
        var capture = Capture(status: .transcribing)
        store.upsert(capture)
        capture.status = .success
        capture.text = "done"
        store.upsert(capture)
        XCTAssertEqual(store.captures.count, 1)
        XCTAssertEqual(store.captures.first?.status, .success)
        XCTAssertEqual(store.captures.first?.text, "done")
    }

    func testUpdateMutatesInPlace() throws {
        let store = try makeStore()
        let capture = Capture(status: .transcribing)
        store.upsert(capture)
        store.update(capture.id) {
            $0.status = .failed
            $0.errorMessage = "boom"
        }
        XCTAssertEqual(store.capture(capture.id)?.status, .failed)
        XCTAssertEqual(store.capture(capture.id)?.errorMessage, "boom")
    }

    func testPruneKeepsTenNewest() throws {
        let store = try makeStore()
        for index in 0..<15 {
            store.upsert(
                Capture(
                    createdAt: Date(timeIntervalSince1970: Double(index)),
                    status: .success,
                    text: "n\(index)"
                )
            )
        }
        XCTAssertEqual(store.captures.count, 10)
        XCTAssertEqual(store.captures.first?.text, "n14")
        XCTAssertFalse(store.captures.contains { $0.text == "n0" })
    }

    func testPruneNeverDropsNonTerminalCaptures() throws {
        let store = try makeStore()
        let statuses: [CaptureStatus] = [.recording, .pending, .transcribing]
        let inFlight = statuses.enumerated().map { offset, status in
            Capture(
                createdAt: Date(timeIntervalSince1970: Double(offset)),
                status: status
            )
        }
        for capture in inFlight {
            store.upsert(capture)
        }
        for index in 3...17 {
            store.upsert(
                Capture(
                    createdAt: Date(timeIntervalSince1970: Double(index)),
                    status: .success,
                    text: "n\(index)"
                )
            )
        }

        for capture in inFlight {
            XCTAssertNotNil(
                store.capture(capture.id),
                "\(capture.status) capture must not be pruned"
            )
        }
        XCTAssertEqual(store.captures.filter { $0.status == .success }.count, 10)
    }

    func testTransferInProgressTerminalCaptureIsNotPruned() throws {
        let store = try makeStore()
        let transferring = Capture(
            createdAt: Date(timeIntervalSince1970: 0),
            transferState: .sending,
            status: .failed
        )
        store.upsert(transferring)
        for index in 1...14 {
            store.upsert(
                Capture(
                    createdAt: Date(timeIntervalSince1970: Double(index)),
                    status: .success
                )
            )
        }
        XCTAssertNotNil(store.capture(transferring.id))
    }

    func testThoughtsAreNeverPruned() throws {
        let store = try makeStore()
        for index in 0..<15 {
            store.upsert(
                Capture(
                    createdAt: Date(timeIntervalSince1970: Double(index)),
                    mode: .thought,
                    status: .success,
                    text: "thought \(index)"
                )
            )
        }
        XCTAssertEqual(store.captures.count, 15)
    }

    func testRecoverableFindsPendingWithAudio() throws {
        let store = try makeStore()
        var capture = Capture(status: .pending)
        let url = store.newAudioURL(for: capture.id)
        try Data("audio".utf8).write(to: url)
        capture.audioFileName = url.lastPathComponent
        store.upsert(capture)
        store.upsert(Capture(status: .success, text: "done"))

        XCTAssertEqual(store.recoverable().count, 1)
        XCTAssertEqual(store.recoverable().first?.id, capture.id)
    }

    func testAudioURLHelpersUseStableCaptureNames() throws {
        let store = try makeStore()
        let id = UUID()
        XCTAssertEqual(store.newAudioURL(for: id), store.importedAudioURL(for: id))

        var capture = Capture(id: id)
        capture.audioFileName = "\(id.uuidString).m4a"
        XCTAssertNil(store.audioURL(for: capture))
        try Data("audio".utf8).write(to: store.newAudioURL(for: id))
        XCTAssertEqual(store.audioURL(for: capture), store.newAudioURL(for: id))
    }

    func testDeleteRemovesCaptureAndAudio() throws {
        let store = try makeStore()
        var capture = Capture(status: .success)
        let url = store.newAudioURL(for: capture.id)
        try Data("audio".utf8).write(to: url)
        capture.audioFileName = url.lastPathComponent
        store.upsert(capture)

        store.delete(capture)

        XCTAssertNil(store.capture(capture.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testClearRemovesAll() throws {
        let store = try makeStore()
        store.upsert(Capture(status: .success, text: "x"))
        store.clear()
        XCTAssertTrue(store.captures.isEmpty)
    }

    func testClearModeOnlyRemovesMatchingCapturesAndAudio() throws {
        let store = try makeStore()
        var dictation = Capture(mode: .dictation, status: .success)
        let dictationURL = store.newAudioURL(for: dictation.id)
        try Data("dictation".utf8).write(to: dictationURL)
        dictation.audioFileName = dictationURL.lastPathComponent

        var thought = Capture(mode: .thought, status: .success)
        let thoughtURL = store.newAudioURL(for: thought.id)
        try Data("thought".utf8).write(to: thoughtURL)
        thought.audioFileName = thoughtURL.lastPathComponent
        store.upsert(dictation)
        store.upsert(thought)

        store.clear(mode: .dictation)

        XCTAssertNil(store.capture(dictation.id))
        XCTAssertNotNil(store.capture(thought.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dictationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thoughtURL.path))
    }

    func testPersistenceRoundTripAcrossInstances() throws {
        let directory = try makeDirectory()
        let first = CaptureStore(baseURL: directory)
        var capture = Capture(status: .success)
        capture.text = "persisted"
        first.upsert(capture)

        let second = CaptureStore(baseURL: directory)
        XCTAssertEqual(second.captures.count, 1)
        XCTAssertEqual(second.capture(capture.id)?.text, "persisted")
    }

    func testImportIfNewIsIdempotentAndPreservesAdvancedState() throws {
        let store = try makeStore()
        let id = UUID()
        var original = Capture(id: id, status: .pending)
        original.text = "incoming"
        XCTAssertTrue(store.importIfNew(original))

        store.update(id) {
            $0.status = .success
            $0.text = "local final"
        }
        XCTAssertFalse(store.importIfNew(original))

        XCTAssertEqual(store.captures.count, 1)
        XCTAssertEqual(store.capture(id)?.status, .success)
        XCTAssertEqual(store.capture(id)?.text, "local final")
    }

    func testOrphanedAudioIsRemovedOnTrustworthyLaunch() throws {
        let directory = try makeDirectory()
        let first = CaptureStore(baseURL: directory)
        var kept = Capture(status: .pending)
        let keptURL = first.newAudioURL(for: kept.id)
        try Data("audio".utf8).write(to: keptURL)
        kept.audioFileName = keptURL.lastPathComponent
        first.upsert(kept)

        let orphanURL = first.newAudioURL(for: UUID())
        try Data("orphan".utf8).write(to: orphanURL)

        let second = CaptureStore(baseURL: directory)
        XCTAssertNotNil(second.audioURL(for: kept))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    func testCorruptIndexPreservesAllAudioAndBacksUpIndex() throws {
        let directory = try makeDirectory()
        let capturesDirectory = directory.appendingPathComponent(
            "captures",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: capturesDirectory,
            withIntermediateDirectories: true
        )
        let firstAudio = capturesDirectory.appendingPathComponent("first.m4a")
        let secondAudio = capturesDirectory.appendingPathComponent("second.m4a")
        try Data("first".utf8).write(to: firstAudio)
        try Data("second".utf8).write(to: secondAudio)

        let corruptData = Data("{ definitely-not-json".utf8)
        let indexURL = directory.appendingPathComponent("captures-index.json")
        try corruptData.write(to: indexURL)

        let store = CaptureStore(baseURL: directory)

        XCTAssertTrue(store.captures.isEmpty)
        XCTAssertNotNil(store.recoveryWarning)
        XCTAssertEqual(try Data(contentsOf: indexURL), corruptData)
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("captures-index.corrupt") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), corruptData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondAudio.path))

        // A subsequent save creates a readable forward index. The persistent
        // corruption backup must still prevent audio reconciliation on relaunch.
        store.upsert(Capture(status: .pending))
        _ = CaptureStore(baseURL: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondAudio.path))
    }

    // F-A regression: a missing index with audio present must NOT trigger orphan
    // deletion (that path is indistinguishable from a transient index-write
    // failure). Every audio file is quarantined as a recovered capture instead.
    func testMissingIndexWithAudioQuarantinesInsteadOfDeleting() throws {
        let directory = try makeDirectory()
        let capturesDirectory = directory.appendingPathComponent(
            "captures",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: capturesDirectory,
            withIntermediateDirectories: true
        )
        let idA = UUID()
        let idB = UUID()
        let audioA = capturesDirectory.appendingPathComponent("\(idA.uuidString).m4a")
        let audioB = capturesDirectory.appendingPathComponent("\(idB.uuidString).m4a")
        try Data("a".utf8).write(to: audioA)
        try Data("b".utf8).write(to: audioB)
        // No captures-index.json exists → load() returns .missing.

        let store = CaptureStore(baseURL: directory)

        // Nothing was deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioB.path))

        // Both audio files surface as recovered, retryable captures.
        XCTAssertEqual(store.captures.count, 2)
        XCTAssertNotNil(store.recoveryWarning)
        for capture in store.captures {
            XCTAssertEqual(capture.status, .pending)
            XCTAssertEqual(capture.source, .importedAudio)
            XCTAssertEqual(capture.mode, .dictation)
            XCTAssertNotNil(capture.audioFileName)
            XCTAssertNotNil(store.audioURL(for: capture))
        }
        XCTAssertEqual(store.recoverable().count, 2)

        // The recovery persists: a relaunch reads a real index and still keeps
        // every audio file.
        let reopened = CaptureStore(baseURL: directory)
        XCTAssertEqual(reopened.captures.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioB.path))
    }

    // F-B regression: a second corruption must not overwrite the first backup;
    // both salvaged copies survive under unique names.
    func testDoubleCorruptionPreservesBothBackups() throws {
        let directory = try makeDirectory()
        let indexURL = directory.appendingPathComponent("captures-index.json")

        let firstCorrupt = Data("{ corrupt-one".utf8)
        try firstCorrupt.write(to: indexURL)
        _ = CaptureStore(baseURL: directory)

        let secondCorrupt = Data("{ corrupt-two-and-different".utf8)
        try secondCorrupt.write(to: indexURL)
        _ = CaptureStore(baseURL: directory)

        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("captures-index.corrupt") }

        XCTAssertEqual(backups.count, 2)
        let contents = Set(try backups.map { try Data(contentsOf: $0) })
        XCTAssertTrue(contents.contains(firstCorrupt))
        XCTAssertTrue(contents.contains(secondCorrupt))
    }
}
