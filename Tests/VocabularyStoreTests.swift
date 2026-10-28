import XCTest
@testable import Captur

@MainActor
final class VocabularyStoreTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-vocab-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func term(_ text: String, pinned: Bool = false) -> VocabularyTerm {
        VocabularyTerm(
            id: UUID(),
            text: text,
            soundsLike: nil,
            isPinned: pinned,
            useCount: 0,
            lastUsed: nil,
            appBundleIDs: []
        )
    }

    private func backups(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("vocabulary.corrupt") }
    }

    // MARK: - Round trip

    func testMissingFileStartsEmptyWithoutAWarning() throws {
        let store = VocabularyStore(directory: try makeDirectory())
        XCTAssertTrue(store.terms.isEmpty)
        XCTAssertNil(store.recoveryWarning)
        XCTAssertEqual(store.lastLoadResult, .missing)
    }

    func testTermsSurviveAReload() throws {
        let directory = try makeDirectory()
        let store = VocabularyStore(directory: directory)
        store.replaceAll([term("Kubernetes"), term("Avery", pinned: true)])
        XCTAssertNil(store.lastSaveError)

        let reloaded = VocabularyStore(directory: directory)
        XCTAssertEqual(reloaded.lastLoadResult, .loaded)
        XCTAssertEqual(reloaded.terms.map(\.text), ["Kubernetes", "Avery"])
        XCTAssertEqual(reloaded.terms.last?.isPinned, true)
    }

    func testUpsertInsertsThenUpdatesInPlace() throws {
        let directory = try makeDirectory()
        let store = VocabularyStore(directory: directory)
        var subject = term("Groq")
        store.upsert(subject)
        subject.text = "Groq Inc"
        store.upsert(subject)

        XCTAssertEqual(store.terms.count, 1)
        XCTAssertEqual(VocabularyStore(directory: directory).terms.first?.text, "Groq Inc")
    }

    func testDeleteRemovesAndPersists() throws {
        let directory = try makeDirectory()
        let store = VocabularyStore(directory: directory)
        let doomed = term("typo")
        store.replaceAll([term("keeper"), doomed])
        store.delete(id: doomed.id)

        XCTAssertEqual(store.terms.map(\.text), ["keeper"])
        XCTAssertEqual(VocabularyStore(directory: directory).terms.map(\.text), ["keeper"])
    }

    func testDeletingAnUnknownIDIsANoOp() throws {
        let store = VocabularyStore(directory: try makeDirectory())
        store.replaceAll([term("keeper")])
        store.delete(id: UUID())
        XCTAssertEqual(store.terms.map(\.text), ["keeper"])
    }

    // MARK: - Corruption discipline

    func testCorruptFileIsBackedUpAndTheStoreStartsEmpty() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("vocabulary.json")
        try Data("{ not json".utf8).write(to: fileURL)

        let store = VocabularyStore(directory: directory)
        XCTAssertEqual(store.lastLoadResult, .corrupt)
        XCTAssertTrue(store.terms.isEmpty)
        XCTAssertNotNil(store.recoveryWarning)

        let saved = try backups(in: directory)
        XCTAssertEqual(saved.count, 1)
        let backupURL = try XCTUnwrap(saved.first)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "{ not json")
    }

    func testCorruptFileIsCopiedNotMovedSoNothingIsErased() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("vocabulary.json")
        try Data("{ not json".utf8).write(to: fileURL)

        _ = VocabularyStore(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testASecondCorruptionNeverOverwritesTheEarlierBackup() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("vocabulary.json")

        try Data("first corruption".utf8).write(to: fileURL)
        _ = VocabularyStore(directory: directory)
        try Data("second corruption".utf8).write(to: fileURL)
        _ = VocabularyStore(directory: directory)

        let saved = try backups(in: directory)
        XCTAssertEqual(saved.count, 2)
        let contents = Set(try saved.map { try String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(contents, ["first corruption", "second corruption"])
    }

    func testSavingAfterACorruptionWritesAReadableFile() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("vocabulary.json")
        try Data("{ not json".utf8).write(to: fileURL)

        let store = VocabularyStore(directory: directory)
        store.replaceAll([term("recovered")])
        XCTAssertNil(store.lastSaveError)
        XCTAssertEqual(VocabularyStore(directory: directory).terms.map(\.text), ["recovered"])
    }

    func testAFutureFileVersionIsTreatedAsCorruptRatherThanSilentlyDropped() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("vocabulary.json")
        try Data(#"{"version": 999, "terms": []}"#.utf8).write(to: fileURL)

        let store = VocabularyStore(directory: directory)
        XCTAssertEqual(store.lastLoadResult, .corrupt)
        XCTAssertEqual(try backups(in: directory).count, 1)
    }
}
