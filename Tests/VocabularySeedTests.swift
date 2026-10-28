import XCTest
@testable import Captur

/// The starter vocabulary exists so common product and technical terms transcribe
/// correctly the first time the app is used, rather than only after the user discovers
/// the Vocabulary screen. These tests pin the two rules that make that safe: seed only
/// a genuinely fresh install, and never resurrect a list the user deliberately emptied.
@MainActor
final class VocabularySeedTests: XCTestCase {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_seedsAFreshInstall() throws {
        let store = VocabularyStore(directory: try tempDir(), seedIfEmpty: ["Acme", "Avery"])

        XCTAssertEqual(store.terms.map(\.text), ["Acme", "Avery"])
    }

    func test_doesNotSeedWhenAVocabularyFileAlreadyExists() throws {
        let directory = try tempDir()
        let first = VocabularyStore(directory: directory, seedIfEmpty: ["Acme"])
        first.replaceAll([])

        let second = VocabularyStore(directory: directory, seedIfEmpty: ["Acme"])

        XCTAssertTrue(second.terms.isEmpty,
                      "a user who cleared their vocabulary must not have it handed back on next launch")
    }

    func test_doesNotDisturbAnExistingVocabulary() throws {
        let directory = try tempDir()
        let first = VocabularyStore(directory: directory)
        first.upsert(VocabularyTerm(id: UUID(), text: "Example Forms", soundsLike: nil,
                                    isPinned: false, useCount: 0, lastUsed: nil, appBundleIDs: []))

        let second = VocabularyStore(directory: directory, seedIfEmpty: ["Acme", "Avery"])

        XCTAssertEqual(second.terms.map(\.text), ["Example Forms"])
    }

    func test_seedingIsSkippedWhenNoStarterListIsGiven() throws {
        let store = VocabularyStore(directory: try tempDir())

        XCTAssertTrue(store.terms.isEmpty)
    }

    func test_starterTermsCarryTheNamesWhisperActuallyGetsWrong() {
        XCTAssertTrue(VocabularyStore.starterTerms.contains("Captur"))
        XCTAssertTrue(VocabularyStore.starterTerms.contains("Groq"))
        XCTAssertTrue(VocabularyStore.starterTerms.contains("SwiftUI"))
    }

    func test_theStarterListFitsComfortablyInsideWhispersPromptBudget() {
        let terms = VocabularyStore.starterTerms.map {
            VocabularyTerm(id: UUID(), text: $0, soundsLike: nil, isPinned: false,
                           useCount: 0, lastUsed: nil, appBundleIDs: [])
        }

        let selection = VocabularyRanker.select(from: terms, targetBundleID: nil,
                                                now: Date(), reservedTokens: 0)

        XCTAssertEqual(selection.terms.count, terms.count,
                       "every starter term should fit — a starter list that is already truncated "
                       + "would crowd out the terms the user adds themselves")
        XCTAssertLessThanOrEqual(selection.estimatedTokens,
                                 VocabularyRanker.whisperPromptTokenBudget)
    }
}
