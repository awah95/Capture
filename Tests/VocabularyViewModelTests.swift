import XCTest
@testable import Captur

/// Spec §7 and §10.4.
///
/// Three things are load-bearing here and each has a test that fails loudly if it
/// regresses:
///
/// 1. **The budget indicator reports what the ranker would actually send.** Not the
///    total, not "pins are exempt". `VocabularyRanker.select` is the only source of
///    every number, including the case where pinned terms alone overflow the 224-token
///    cap and the ranker truncates them like anything else.
/// 2. **A CSV import can never destroy a term it does not mention**, and one malformed
///    row costs the user that row only.
/// 3. **`useCount` / `lastUsed` / `appBundleIDs` survive every UI edit.** They are
///    ranking history the pipeline maintains; a typo fix that reset them would silently
///    demote a term the user relies on.
///
/// Every test builds its stores against a fresh temporary directory. Nothing here
/// touches Application Support — the owner's real vocabulary is seeded with terms their
/// transcription quality depends on.
@MainActor
final class VocabularyViewModelTests: XCTestCase {

    /// Fixed so the ranker's recency decay is deterministic.
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Fixtures

    /// An in-memory stand-in for the file seam, so CSV behaviour is tested without a
    /// filesystem and an unreadable file is a one-line arrangement.
    private final class FakeFiles {
        var contents: [URL: String] = [:]
        var readError: Error?
        var writeError: Error?

        func read(_ url: URL) throws -> String {
            if let readError { throw readError }
            guard let text = contents[url] else { throw CocoaError(.fileNoSuchFile) }
            return text
        }

        func write(_ text: String, to url: URL) throws {
            if let writeError { throw writeError }
            contents[url] = text
        }
    }

    private let csvURL = URL(fileURLWithPath: "/tmp/captur-test-vocabulary.csv")

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-vocab-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func term(_ text: String,
                      pinned: Bool = false,
                      uses: Int = 0,
                      daysAgo: Double? = nil,
                      soundsLike: String? = nil,
                      apps: Set<String> = []) -> VocabularyTerm {
        VocabularyTerm(
            id: UUID(),
            text: text,
            soundsLike: soundsLike,
            isPinned: pinned,
            useCount: uses,
            lastUsed: daysAgo.map { Date(timeIntervalSince1970: 1_000_000 - $0 * 86_400) },
            appBundleIDs: apps)
    }

    private func replacement(_ find: String,
                             _ replaceWith: String,
                             wholeWord: Bool = true,
                             caseSensitive: Bool = false,
                             enabled: Bool = true) -> Replacement {
        Replacement(id: UUID(), find: find, replaceWith: replaceWith,
                    wholeWordOnly: wholeWord, caseSensitive: caseSensitive, isEnabled: enabled)
    }

    private func makeModel(terms: [VocabularyTerm] = [],
                           replacements: [Replacement] = [],
                           reservedTokens: Int = 0,
                           files: FakeFiles = FakeFiles(),
                           directory: URL? = nil) throws -> VocabularyViewModel {
        let directory = try directory ?? makeDirectory()
        let vocabulary = VocabularyStore(directory: directory)
        if !terms.isEmpty { vocabulary.replaceAll(terms) }
        let replacementStore = ReplacementStore(directory: directory)
        if !replacements.isEmpty { replacementStore.replaceAll(replacements) }
        return VocabularyViewModel(
            vocabulary: vocabulary,
            replacements: replacementStore,
            now: { self.now },
            reservedTokens: reservedTokens,
            readFile: { try files.read($0) },
            writeFile: { try files.write($0, to: $1) })
    }

    /// What the pipeline would send for the model's current vocabulary. The indicator is
    /// compared against this rather than against a hard-coded number, so the two can
    /// never drift.
    private func rankerSelection(_ model: VocabularyViewModel,
                                 reservedTokens: Int = 0) -> VocabularySelection {
        VocabularyRanker.select(from: model.vocabulary.terms,
                                targetBundleID: nil,
                                now: now,
                                reservedTokens: reservedTokens)
    }

    /// Long enough that a few hundred of them cannot fit in 224 tokens.
    private func manyTerms(_ count: Int, pinned: Bool = false) -> [VocabularyTerm] {
        (0..<count).map { term("supercalifragilistic\($0)", pinned: pinned) }
    }

    // MARK: - Budget: it reports what the ranker would send

    func test_budgetCountsOnlyTheTermsTheRankerSelected() throws {
        let model = try makeModel(terms: manyTerms(400))
        let expected = rankerSelection(model)

        XCTAssertEqual(model.budget.fitCount, expected.terms.count)
        XCTAssertEqual(model.budget.totalCount, 400)
        XCTAssertLessThan(model.budget.fitCount, 400,
                          "400 long terms cannot fit in 224 tokens; an indicator that says they "
                          + "do is reporting the stored count, not the sent count")
    }

    func test_budgetTokensAndPromptComeFromTheSameRankerCall() throws {
        let model = try makeModel(terms: manyTerms(400))
        let expected = rankerSelection(model)

        XCTAssertEqual(model.budget.estimatedTokens, expected.estimatedTokens)
        XCTAssertEqual(model.budget.budgetTokens, VocabularyRanker.whisperPromptTokenBudget)
        XCTAssertEqual(model.promptPreview, expected.promptString)
        XCTAssertLessThanOrEqual(model.budget.estimatedTokens,
                                 VocabularyRanker.whisperPromptTokenBudget)
    }

    func test_sentIDsMatchTheRankerSelectionExactly() throws {
        let model = try makeModel(terms: manyTerms(400))
        let expected = Set(rankerSelection(model).terms.map(\.id))

        XCTAssertEqual(model.budget.sentIDs, expected)
        for sent in rankerSelection(model).terms {
            XCTAssertTrue(model.isSent(sent))
        }
        let dropped = model.vocabulary.terms.filter { !expected.contains($0.id) }
        XCTAssertFalse(dropped.isEmpty)
        for term in dropped {
            XCTAssertFalse(model.isSent(term),
                           "a term the ranker dropped must not be shown as sent")
        }
    }

    func test_headlineNamesBothTheSentAndTheStoredCount() throws {
        let model = try makeModel(terms: manyTerms(400))
        let fit = rankerSelection(model).terms.count

        XCTAssertEqual(model.budget.headline, "\(fit) of 400 terms fit the current budget")
    }

    func test_aSmallVocabularyFitsEntirely() throws {
        let model = try makeModel(terms: [term("Avery"), term("Acme"), term("Captur")])

        XCTAssertEqual(model.budget.fitCount, 3)
        XCTAssertEqual(model.budget.totalCount, 3)
        XCTAssertFalse(model.budget.isOverflowing)
    }

    func test_theStarterListFitsSoAFreshInstallSeesNoTruncation() throws {
        let model = try makeModel(terms: VocabularyStore.starterTerms.map { term($0) })

        XCTAssertEqual(model.budget.fitCount, VocabularyStore.starterTerms.count)
        XCTAssertNil(model.budget.pinnedNote, "nothing is pinned, so there is nothing to say")
    }

    // MARK: - Budget: pins

    func test_pinnedTermsThatFitAreAllCountedAsSent() throws {
        var terms = manyTerms(400)
        let pins = [term("Avery", pinned: true),
                    term("Acme", pinned: true),
                    term("Example Forms", pinned: true)]
        terms.append(contentsOf: pins)
        let model = try makeModel(terms: terms)

        XCTAssertEqual(model.budget.pinnedCount, 3)
        XCTAssertEqual(model.budget.pinnedNotSentCount, 0)
        for pin in pins {
            XCTAssertTrue(model.isSent(pin), "a pin that fits outranks every unpinned term")
        }
        XCTAssertEqual(model.budget.pinnedNote,
                       "All 3 pinned terms are sent first, ahead of everything else.")
    }

    /// The trap. `VocabularyRanker.select` sorts pins first and then **stops at the first
    /// term that does not fit** (`VocabularyRanker.swift:100-105`) — pins are not exempt
    /// from the 224-token cap. So when pins alone overflow, some pinned terms are silently
    /// dropped from the prompt, and the indicator's job is to stop that being silent.
    func test_overBudgetPinnedTermsAreReportedAsNotSent() throws {
        let model = try makeModel(terms: manyTerms(200, pinned: true))
        let expected = rankerSelection(model)

        XCTAssertEqual(model.budget.pinnedCount, 200)
        XCTAssertEqual(model.budget.fitCount, expected.terms.count)
        XCTAssertLessThan(expected.terms.count, 200, "sanity: 200 long pins cannot fit")
        XCTAssertEqual(model.budget.pinnedNotSentCount, 200 - expected.terms.count)

        let note = try XCTUnwrap(model.budget.pinnedNote)
        XCTAssertTrue(note.contains("NOT being sent"),
                      "a dropped pin must be stated, not implied: \(note)")
        XCTAssertTrue(note.contains("\(200 - expected.terms.count) of your 200 pinned terms"))
    }

    func test_pinnedTermsAreNeverCountedAsSentJustBecauseTheyArePinned() throws {
        let model = try makeModel(terms: manyTerms(200, pinned: true))
        let sent = Set(rankerSelection(model).terms.map(\.id))
        let droppedPins = model.vocabulary.terms.filter { !sent.contains($0.id) }

        XCTAssertFalse(droppedPins.isEmpty)
        for pin in droppedPins {
            XCTAssertTrue(pin.isPinned)
            XCTAssertFalse(model.isSent(pin),
                           "claiming a dropped pin is sent is the exact fiction §7.3 exists to prevent")
        }
    }

    func test_blankTermsCountInTheTotalButAreNeverSent() throws {
        let blank = term("   ")
        let model = try makeModel(terms: [term("real"), blank])

        XCTAssertEqual(model.budget.totalCount, 2)
        XCTAssertEqual(model.budget.fitCount, 1)
        XCTAssertFalse(model.isSent(blank))
    }

    func test_reservedTokensShrinkWhatTheIndicatorClaims() throws {
        let terms = manyTerms(400)
        let directory = try makeDirectory()
        let unreserved = try makeModel(terms: terms, directory: directory)
        let reserved = try makeModel(terms: terms, reservedTokens: 120)

        XCTAssertLessThan(reserved.budget.fitCount, unreserved.budget.fitCount)
        XCTAssertLessThanOrEqual(reserved.budget.estimatedTokens,
                                 VocabularyRanker.whisperPromptTokenBudget - 120)
    }

    func test_anEmptyVocabularyReportsZeroOfZeroRatherThanCrashing() throws {
        let model = try makeModel()

        XCTAssertEqual(model.budget.fitCount, 0)
        XCTAssertEqual(model.budget.totalCount, 0)
        XCTAssertEqual(model.budget.estimatedTokens, 0)
        XCTAssertNil(model.budget.pinnedNote)
        XCTAssertFalse(model.hasAnyTerms)
    }

    // MARK: - Search and create

    func test_creatingATermAddsIt() throws {
        let model = try makeModel()
        model.query = "Kubernetes"
        let id = model.createTerm()

        XCTAssertNotNil(id)
        XCTAssertEqual(model.vocabulary.terms.map(\.text), ["Kubernetes"])
        XCTAssertEqual(model.query, "", "the field clears so it is a search field again")
    }

    func test_creatingATermThatDiffersOnlyByCaseUpsertsRatherThanDuplicating() throws {
        let existing = term("Kubernetes", uses: 12, daysAgo: 2)
        let model = try makeModel(terms: [existing])
        model.query = "kubernetes"
        let id = model.createTerm()

        XCTAssertEqual(model.vocabulary.terms.count, 1)
        XCTAssertEqual(id, existing.id, "the create must land on the existing term")
        XCTAssertEqual(model.vocabulary.terms.first?.text, "Kubernetes",
                       "the stored casing is the user's original, not the search string")
    }

    func test_creatingATermWithSurroundingWhitespaceDoesNotDuplicate() throws {
        let existing = term("Example Forms")
        let model = try makeModel(terms: [existing])
        model.query = "  Example Forms  "
        model.createTerm()

        XCTAssertEqual(model.vocabulary.terms.count, 1)
    }

    func test_creatingATermWithDoubledInteriorWhitespaceDoesNotDuplicate() throws {
        let model = try makeModel(terms: [term("Example Forms")])
        model.query = "Example   Forms"
        model.createTerm()

        XCTAssertEqual(model.vocabulary.terms.count, 1)
    }

    func test_creatingAnExistingTermPreservesItsRankingHistory() throws {
        let existing = term("Acme", pinned: true, uses: 31, daysAgo: 4, soundsLike: "ack-me",
                            apps: ["com.apple.Safari"])
        let model = try makeModel(terms: [existing])
        model.query = "acme"
        model.createTerm()

        let stored = try XCTUnwrap(model.vocabulary.terms.first)
        XCTAssertEqual(stored.useCount, 31)
        XCTAssertEqual(stored.lastUsed, existing.lastUsed)
        XCTAssertEqual(stored.appBundleIDs, ["com.apple.Safari"])
        XCTAssertEqual(stored.isPinned, true)
        XCTAssertEqual(stored.soundsLike, "ack-me")
    }

    func test_creatingATermNormalizesTheStoredText() throws {
        let model = try makeModel()
        model.query = "  Example   Forms \n"
        model.createTerm()

        XCTAssertEqual(model.vocabulary.terms.first?.text, "Example Forms",
                       "a newline inside a term would break the comma-separated prompt")
    }

    func test_creatingABlankTermDoesNothing() throws {
        let model = try makeModel()
        model.query = "   \n "

        XCTAssertNil(model.createTerm())
        XCTAssertTrue(model.vocabulary.terms.isEmpty)
    }

    func test_theCreateAffordanceHidesWhenTheQueryAlreadyExists() throws {
        let model = try makeModel(terms: [term("Groq")])

        model.query = "Gr"
        XCTAssertEqual(model.pendingTermText, "Gr")

        model.query = "  groq "
        XCTAssertNil(model.pendingTermText,
                     "offering to add a term that exists invites the duplicate")

        model.query = ""
        XCTAssertNil(model.pendingTermText)
    }

    func test_searchFiltersCaseInsensitivelyAcrossBothColumns() throws {
        let model = try makeModel(terms: [
            term("Kubernetes", soundsLike: "koo-ber-net-ees"),
            term("Groq"),
            term("Acme")
        ])

        model.query = "GROQ"
        XCTAssertEqual((model.sentTerms + model.unsentTerms).map(\.text), ["Groq"])

        model.query = "net-ees"
        XCTAssertEqual((model.sentTerms + model.unsentTerms).map(\.text), ["Kubernetes"],
                       "the sounds-like hint is searchable — it is why the term is in the list")

        model.query = "zzz"
        XCTAssertFalse(model.hasVisibleTerms)
        XCTAssertTrue(model.hasAnyTerms)
    }

    func test_sentTermsAreListedInSendOrderAndUnsentTermsAlphabetically() throws {
        let model = try makeModel(terms: manyTerms(400))
        let expected = rankerSelection(model).terms.map(\.text)

        XCTAssertEqual(model.sentTerms.map(\.text), expected)
        let unsent = model.unsentTerms.map(\.text)
        XCTAssertEqual(unsent, unsent.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertTrue(Set(unsent).isDisjoint(with: Set(expected)))
    }

    // MARK: - Editing preserves ranking history

    func test_editingATermPreservesUseCountAndLastUsed() throws {
        let existing = term("Kubernets", uses: 47, daysAgo: 3)
        let model = try makeModel(terms: [existing])

        XCTAssertTrue(model.updateTerm(id: existing.id, text: "Kubernetes", soundsLike: nil))

        let stored = try XCTUnwrap(model.vocabulary.terms.first)
        XCTAssertEqual(stored.text, "Kubernetes")
        XCTAssertEqual(stored.useCount, 47,
                       "the pipeline maintains useCount; a typo fix that reset it would demote "
                       + "the term the user leans on most")
        XCTAssertEqual(stored.lastUsed, existing.lastUsed)
    }

    func test_editingATermPreservesThePinAndTheAppAffinity() throws {
        let existing = term("Acme", pinned: true, uses: 5, daysAgo: 1,
                            apps: ["com.apple.Safari", "com.tinyspeck.slackmacgap"])
        let model = try makeModel(terms: [existing])

        XCTAssertTrue(model.updateTerm(id: existing.id, text: "Acme 5", soundsLike: "ack-me five"))

        let stored = try XCTUnwrap(model.vocabulary.terms.first)
        XCTAssertEqual(stored.isPinned, true)
        XCTAssertEqual(stored.appBundleIDs, ["com.apple.Safari", "com.tinyspeck.slackmacgap"])
        XCTAssertEqual(stored.soundsLike, "ack-me five")
        XCTAssertEqual(stored.id, existing.id)
    }

    func test_editingATermToBlankIsRefusedAndTheOldTextIsKept() throws {
        let existing = term("Groq")
        let model = try makeModel(terms: [existing])

        XCTAssertFalse(model.updateTerm(id: existing.id, text: "   ", soundsLike: nil))
        XCTAssertEqual(model.vocabulary.terms.first?.text, "Groq")
        XCTAssertNotNil(model.lastError)
    }

    func test_renamingATermOntoAnExistingTermIsRefusedRatherThanSilentlyMerging() throws {
        let first = term("Groq", uses: 9)
        let second = term("Grok", uses: 2)
        let model = try makeModel(terms: [first, second])

        XCTAssertFalse(model.updateTerm(id: second.id, text: "groq", soundsLike: nil))
        XCTAssertEqual(model.vocabulary.terms.count, 2)
        XCTAssertEqual(model.vocabulary.terms.map(\.text), ["Groq", "Grok"])
        let error = try XCTUnwrap(model.lastError)
        XCTAssertTrue(error.contains("Groq"), "the message has to name the clash: \(error)")
    }

    func test_editingATermNormalizesWhitespaceInTheStoredText() throws {
        let existing = term("Groq")
        let model = try makeModel(terms: [existing])

        XCTAssertTrue(model.updateTerm(id: existing.id, text: " Groq   Inc ", soundsLike: "  "))
        XCTAssertEqual(model.vocabulary.terms.first?.text, "Groq Inc")
        XCTAssertNil(model.vocabulary.terms.first?.soundsLike,
                     "a hint of only whitespace is no hint, and the ranker would render it as one")
    }

    func test_editingAnUnknownIDIsANoOp() throws {
        let model = try makeModel(terms: [term("Groq")])

        XCTAssertFalse(model.updateTerm(id: UUID(), text: "Anything", soundsLike: nil))
        XCTAssertEqual(model.vocabulary.terms.map(\.text), ["Groq"])
    }

    func test_togglingAPinPreservesEverythingElse() throws {
        let existing = term("Acme", uses: 18, daysAgo: 6, soundsLike: "ack-me",
                            apps: ["com.apple.Safari"])
        let model = try makeModel(terms: [existing])

        model.togglePin(id: existing.id)

        let pinned = try XCTUnwrap(model.vocabulary.terms.first)
        XCTAssertTrue(pinned.isPinned)
        XCTAssertEqual(pinned.useCount, 18)
        XCTAssertEqual(pinned.lastUsed, existing.lastUsed)
        XCTAssertEqual(pinned.soundsLike, "ack-me")
        XCTAssertEqual(pinned.appBundleIDs, ["com.apple.Safari"])

        model.togglePin(id: existing.id)
        XCTAssertFalse(try XCTUnwrap(model.vocabulary.terms.first).isPinned)
    }

    func test_deletingATermRemovesItAndPersists() throws {
        let directory = try makeDirectory()
        let doomed = term("typo")
        let model = try makeModel(terms: [term("keeper"), doomed], directory: directory)

        model.deleteTerm(id: doomed.id)

        XCTAssertEqual(model.vocabulary.terms.map(\.text), ["keeper"])
        XCTAssertEqual(VocabularyStore(directory: directory).terms.map(\.text), ["keeper"])
    }

    // MARK: - Starter terms

    func test_addingStarterTermsMergesWithoutDuplicating() throws {
        let model = try makeModel(terms: [term("groq"), term("Mine")])

        let added = model.addStarterTerms()

        XCTAssertEqual(added, VocabularyStore.starterTerms.count - 1,
                       "\"groq\" already exists under a different casing")
        XCTAssertEqual(model.vocabulary.terms.filter {
            VocabularyViewModel.normalizedKey($0.text) == "groq"
        }.count, 1)
        XCTAssertEqual(model.addStarterTerms(), 0, "a second press adds nothing")
    }

    func test_addingStarterTermsNeverRemovesAUserTerm() throws {
        let mine = term("Kubernetes", pinned: true, uses: 40)
        let model = try makeModel(terms: [mine])

        model.addStarterTerms()

        let stored = try XCTUnwrap(model.vocabulary.terms.first { $0.id == mine.id })
        XCTAssertEqual(stored.useCount, 40)
        XCTAssertTrue(stored.isPinned)
    }

    // MARK: - CSV parsing

    func test_aQuotedFieldContainingACommaIsOneField() {
        let parse = VocabularyCSV.parse("text,soundsLike,pinned\n\"Example Forms, Inc\",,false\n")

        XCTAssertEqual(parse.errors, [])
        XCTAssertEqual(parse.rows.map(\.text), ["Example Forms, Inc"])
    }

    func test_escapedDoubleQuotesBecomeASingleQuote() {
        let parse = VocabularyCSV.parse("text,soundsLike,pinned\n\"He said \"\"hi\"\"\",,false\n")

        XCTAssertEqual(parse.errors, [])
        XCTAssertEqual(parse.rows.map(\.text), [#"He said "hi""#])
    }

    func test_aQuotedFieldContainingANewlineDoesNotSplitTheRow() {
        let parse = VocabularyCSV.parse("text,soundsLike,pinned\n\"Example\nForms\",,true\nGroq,,false\n")

        XCTAssertEqual(parse.errors, [], "the newline is inside quotes; it is not a row break")
        XCTAssertEqual(parse.rows.count, 2)
        XCTAssertEqual(parse.rows.first?.text, "Example Forms",
                       "the newline is collapsed: a term containing one would break the prompt list")
        XCTAssertEqual(parse.rows.first?.isPinned, true)
        XCTAssertEqual(parse.rows.last?.text, "Groq")
    }

    func test_crlfLineEndingsParse() {
        let parse = VocabularyCSV.parse("text,soundsLike,pinned\r\nGroq,,false\r\nAcme,ack-me,true\r\n")

        XCTAssertEqual(parse.errors, [])
        XCTAssertEqual(parse.rows.map(\.text), ["Groq", "Acme"])
        XCTAssertEqual(parse.rows.last?.soundsLike, "ack-me")
        XCTAssertEqual(parse.rows.last?.isPinned, true)
    }

    func test_aUTF8BOMIsStripped() {
        let parse = VocabularyCSV.parse("\u{FEFF}text,soundsLike,pinned\nGroq,,false\n")

        XCTAssertEqual(parse.errors, [])
        XCTAssertEqual(parse.rows.map(\.text), ["Groq"],
                       "an unstripped BOM makes the header unrecognisable and eats a real row")
    }

    func test_anEmptyFileYieldsNothingAndComplainsAboutNothing() {
        let parse = VocabularyCSV.parse("")

        XCTAssertEqual(parse.rows, [])
        XCTAssertEqual(parse.errors, [])
    }

    func test_aHeaderOnlyFileYieldsNoRows() {
        let parse = VocabularyCSV.parse("text,soundsLike,pinned\n")

        XCTAssertEqual(parse.rows, [])
        XCTAssertEqual(parse.errors, [])
    }

    func test_aHeaderlessFileIsTreatedAsData() {
        let parse = VocabularyCSV.parse("Groq\nAcme\n")

        XCTAssertEqual(parse.rows.map(\.text), ["Groq", "Acme"],
                       "a hand-written list of names has no header and must not lose its first name")
    }

    func test_aRowWithFewerColumnsLeavesTheMissingOnesUnstated() {
        let parse = VocabularyCSV.parse("text,soundsLike,pinned\nGroq\nAcme,ack-me\n")

        XCTAssertEqual(parse.errors, [])
        XCTAssertEqual(parse.rows.count, 2)
        XCTAssertNil(parse.rows[0].soundsLike)
        XCTAssertNil(parse.rows[0].isPinned, "absent is not false — see the import merge rules")
        XCTAssertEqual(parse.rows[1].soundsLike, "ack-me")
        XCTAssertNil(parse.rows[1].isPinned)
    }

    func test_aRowWithExtraEmptyColumnsIsAccepted() {
        let parse = VocabularyCSV.parse("text,soundsLike,pinned\nGroq,,false,,\n")

        XCTAssertEqual(parse.errors, [])
        XCTAssertEqual(parse.rows.map(\.text), ["Groq"])
    }

    func test_aRowWithExtraNonEmptyColumnsIsSkippedRatherThanTruncated() {
        let parse = VocabularyCSV.parse("text,soundsLike,pinned\nExample Forms, Inc,,false\n")

        XCTAssertEqual(parse.rows, [],
                       "an unquoted comma means the term is wrong; importing \"Example Forms\" "
                       + "silently would corrupt it")
        XCTAssertEqual(parse.errors.count, 1)
        XCTAssertEqual(parse.errors.first?.line, 2)
    }

    func test_aRowWithNoTermTextIsSkippedWithAReason() {
        let parse = VocabularyCSV.parse("text,soundsLike,pinned\n  ,ack-me,true\nGroq,,false\n")

        XCTAssertEqual(parse.rows.map(\.text), ["Groq"])
        XCTAssertEqual(parse.errors.count, 1)
        XCTAssertEqual(parse.errors.first?.line, 2)
    }

    /// The plan's requirement, stated exactly: a malformed row must not abort the import.
    func test_anUnparsablePinnedValueSkipsOnlyThatRow() {
        let parse = VocabularyCSV.parse(
            "text,soundsLike,pinned\nBefore,,false\nMiddle,,perhaps\nAfter,,true\n")

        XCTAssertEqual(parse.rows.map(\.text), ["Before", "After"],
                       "rows on both sides of the bad one must survive")
        XCTAssertEqual(parse.errors.count, 1)
        XCTAssertEqual(parse.errors.first?.line, 3)
    }

    func test_pinnedAcceptsTheCommonSpellingsOfYesAndNo() {
        let parse = VocabularyCSV.parse(
            "text,soundsLike,pinned\nA,,TRUE\nB,,yes\nC,,1\nD,,No\nE,,0\nF,,\n")

        XCTAssertEqual(parse.errors, [])
        XCTAssertEqual(parse.rows.map(\.isPinned), [true, true, true, false, false, nil])
    }

    func test_anUnterminatedQuoteSkipsOnlyItsOwnRow() {
        let parse = VocabularyCSV.parse("text,soundsLike,pinned\nGroq,,false\n\"Never closed,,\n")

        XCTAssertEqual(parse.rows.map(\.text), ["Groq"])
        XCTAssertEqual(parse.errors.count, 1)
        XCTAssertEqual(parse.errors.first?.line, 3)
    }

    func test_blankLinesAreIgnoredSilently() {
        let parse = VocabularyCSV.parse("text,soundsLike,pinned\n\nGroq,,false\n\n\nAcme,,true\n")

        XCTAssertEqual(parse.errors, [], "a trailing blank line is not a malformed row")
        XCTAssertEqual(parse.rows.map(\.text), ["Groq", "Acme"])
    }

    func test_errorsCarryTheSourceLineNumberEvenAfterAMultiLineField() {
        let parse = VocabularyCSV.parse(
            "text,soundsLike,pinned\n\"Two\nLines\",,false\nBad,,perhaps\n")

        XCTAssertEqual(parse.errors.count, 1)
        XCTAssertEqual(parse.errors.first?.line, 4,
                       "the quoted newline advanced the line counter, so the bad row is line 4")
    }

    // MARK: - CSV export and the round trip

    func test_exportWritesTheHeaderAndOneRowPerTerm() throws {
        let model = try makeModel(terms: [term("Groq"), term("Acme", pinned: true, soundsLike: "ack-me")])
        let text = VocabularyCSV.export(model.vocabulary.terms)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        XCTAssertEqual(lines.first, VocabularyCSV.header)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.contains("Acme,ack-me,true"), text)
    }

    func test_exportQuotesATermContainingACommaOrAQuote() {
        let text = VocabularyCSV.export([
            VocabularyTerm(id: UUID(), text: "Example Forms, Inc", soundsLike: nil,
                           isPinned: false, useCount: 0, lastUsed: nil, appBundleIDs: []),
            VocabularyTerm(id: UUID(), text: #"He said "hi""#, soundsLike: nil,
                           isPinned: false, useCount: 0, lastUsed: nil, appBundleIDs: [])
        ])

        XCTAssertTrue(text.contains("\"Example Forms, Inc\""), text)
        XCTAssertTrue(text.contains("\"He said \"\"hi\"\"\""), text)
    }

    /// The round trip the plan asks for: export → import → the identical set, including
    /// the pin and the hint, and including text that would break a naive writer.
    func test_exportRoundTripsTextPinsAndSoundsLike() throws {
        let files = FakeFiles()
        let original = [
            term("Example Forms, Inc", pinned: true, soundsLike: "example forms"),
            term(#"He said "hi""#, pinned: false, soundsLike: nil),
            term("Acme", pinned: true, soundsLike: nil),
            term("Kubernetes", pinned: false, soundsLike: "koo-ber-net-ees")
        ]
        let source = try makeModel(terms: original, files: files)
        source.exportTerms(to: csvURL)
        XCTAssertNotNil(source.lastExport)

        let destination = try makeModel(files: files)
        destination.importTerms(from: csvURL)

        let round = destination.vocabulary.terms
        XCTAssertEqual(Set(round.map(\.text)), Set(original.map(\.text)))
        for term in original {
            let match = try XCTUnwrap(round.first { $0.text == term.text },
                                      "\(term.text) did not survive the round trip")
            XCTAssertEqual(match.isPinned, term.isPinned, "the pin was lost for \(term.text)")
            XCTAssertEqual(match.soundsLike, term.soundsLike,
                           "the hint was lost for \(term.text)")
        }
    }

    func test_reExportingARoundTrippedListProducesTheIdenticalFile() throws {
        let files = FakeFiles()
        let original = [term("Example Forms, Inc", pinned: true, soundsLike: "example"),
                        term("Acme")]
        let source = try makeModel(terms: original, files: files)
        source.exportTerms(to: csvURL)
        let first = try XCTUnwrap(files.contents[csvURL])

        let destination = try makeModel(files: files)
        destination.importTerms(from: csvURL)
        let second = URL(fileURLWithPath: "/tmp/captur-test-vocabulary-2.csv")
        destination.exportTerms(to: second)

        XCTAssertEqual(files.contents[second], first, "the round trip is not yet a fixed point")
    }

    func test_anExportFailureIsReportedAndClaimsNothing() throws {
        let files = FakeFiles()
        files.writeError = CocoaError(.fileWriteNoPermission)
        let model = try makeModel(terms: [term("Groq")], files: files)

        model.exportTerms(to: csvURL)

        XCTAssertNil(model.lastExport, "never report a file that was not written")
        XCTAssertNotNil(model.lastError)
    }

    // MARK: - CSV import into the store

    func test_importMergesAndNeverReplacesTheWholeList() throws {
        let files = FakeFiles()
        files.contents[csvURL] = "text,soundsLike,pinned\nGroq,,false\nAcme,ack-me,true\n"
        let keeper = term("Kubernetes", uses: 12)
        let model = try makeModel(terms: [keeper], files: files)

        model.importTerms(from: csvURL)

        XCTAssertEqual(Set(model.vocabulary.terms.map(\.text)), ["Kubernetes", "Groq", "Acme"],
                       "a file that mentions two terms must not delete the hundred it does not")
        XCTAssertEqual(model.lastImport?.added, 2)
        XCTAssertEqual(model.lastImport?.skipped, [])
    }

    /// The dangerous case: a partly-parsed file. It must add the good rows, report the
    /// bad one, and leave everything it never mentioned alone.
    func test_aPartialImportKeepsTheGoodRowsAndDestroysNothing() throws {
        let files = FakeFiles()
        files.contents[csvURL] = "text,soundsLike,pinned\nGroq,,false\nBad,,perhaps\nAcme,,true\n"
        let keeper = term("Kubernetes", uses: 12, daysAgo: 1)
        let model = try makeModel(terms: [keeper], files: files)

        model.importTerms(from: csvURL)

        XCTAssertEqual(Set(model.vocabulary.terms.map(\.text)), ["Kubernetes", "Groq", "Acme"])
        let result = try XCTUnwrap(model.lastImport)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.skipped.first?.line, 3)
        XCTAssertNil(result.fileError, "a bad row is not a bad file")

        let survivor = try XCTUnwrap(model.vocabulary.terms.first { $0.id == keeper.id })
        XCTAssertEqual(survivor.useCount, 12)
    }

    func test_importingATermThatAlreadyExistsUpdatesItAndKeepsItsRankingHistory() throws {
        let files = FakeFiles()
        files.contents[csvURL] = "text,soundsLike,pinned\nkubernetes,koo-ber-net-ees,true\n"
        let existing = term("Kubernetes", uses: 31, daysAgo: 2, apps: ["com.apple.Safari"])
        let model = try makeModel(terms: [existing], files: files)

        model.importTerms(from: csvURL)

        XCTAssertEqual(model.vocabulary.terms.count, 1, "a casing difference is not a new term")
        let stored = try XCTUnwrap(model.vocabulary.terms.first)
        XCTAssertEqual(stored.id, existing.id)
        XCTAssertEqual(stored.text, "Kubernetes", "the stored spelling wins over the file's casing")
        XCTAssertEqual(stored.soundsLike, "koo-ber-net-ees")
        XCTAssertTrue(stored.isPinned)
        XCTAssertEqual(stored.useCount, 31, "a CSV carries no use count, so it cannot reset one")
        XCTAssertEqual(stored.lastUsed, existing.lastUsed)
        XCTAssertEqual(stored.appBundleIDs, ["com.apple.Safari"])
        XCTAssertEqual(model.lastImport?.updated, 1)
        XCTAssertEqual(model.lastImport?.added, 0)
    }

    func test_anUnstatedPinnedColumnLeavesAnExistingPinAlone() throws {
        let files = FakeFiles()
        files.contents[csvURL] = "Acme\n"
        let existing = term("Acme", pinned: true, soundsLike: "ack-me")
        let model = try makeModel(terms: [existing], files: files)

        model.importTerms(from: csvURL)

        let stored = try XCTUnwrap(model.vocabulary.terms.first)
        XCTAssertTrue(stored.isPinned, "a one-column list of names must not unpin what it lists")
        XCTAssertEqual(stored.soundsLike, "ack-me")
        XCTAssertEqual(model.lastImport?.unchanged, 1)
    }

    func test_aStatedPinnedColumnWins() throws {
        let files = FakeFiles()
        files.contents[csvURL] = "text,soundsLike,pinned\nAcme,,false\n"
        let model = try makeModel(terms: [term("Acme", pinned: true)], files: files)

        model.importTerms(from: csvURL)

        XCTAssertFalse(try XCTUnwrap(model.vocabulary.terms.first).isPinned)
        XCTAssertEqual(model.lastImport?.updated, 1)
    }

    func test_importingAnEmptyFileChangesNothing() throws {
        let files = FakeFiles()
        files.contents[csvURL] = ""
        let model = try makeModel(terms: [term("Kubernetes")], files: files)

        model.importTerms(from: csvURL)

        XCTAssertEqual(model.vocabulary.terms.map(\.text), ["Kubernetes"])
        XCTAssertEqual(model.lastImport?.summary,
                       "That file had no term rows, so nothing changed.")
    }

    func test_importingAHeaderOnlyFileCannotWipeTheList() throws {
        let files = FakeFiles()
        files.contents[csvURL] = "text,soundsLike,pinned\n"
        let model = try makeModel(terms: [term("Kubernetes"), term("Acme")], files: files)

        model.importTerms(from: csvURL)

        XCTAssertEqual(Set(model.vocabulary.terms.map(\.text)), ["Kubernetes", "Acme"])
    }

    func test_aFileThatCannotBeReadIsReportedAndChangesNothing() throws {
        let files = FakeFiles()
        files.readError = CocoaError(.fileReadNoPermission)
        let model = try makeModel(terms: [term("Kubernetes")], files: files)

        model.importTerms(from: csvURL)

        XCTAssertEqual(model.vocabulary.terms.map(\.text), ["Kubernetes"])
        let result = try XCTUnwrap(model.lastImport)
        XCTAssertNotNil(result.fileError)
        XCTAssertEqual(result.added, 0)
        XCTAssertTrue(result.summary.contains("Nothing was changed"), result.summary)
    }

    func test_duplicateRowsWithinOneFileBecomeOneTerm() throws {
        let files = FakeFiles()
        files.contents[csvURL] = "text,soundsLike,pinned\nAcme,,false\nACME,ack-me,true\n"
        let model = try makeModel(files: files)

        model.importTerms(from: csvURL)

        XCTAssertEqual(model.vocabulary.terms.count, 1)
        let stored = try XCTUnwrap(model.vocabulary.terms.first)
        XCTAssertEqual(stored.soundsLike, "ack-me", "the later row states the hint")
        XCTAssertTrue(stored.isPinned)
    }

    func test_theImportSummaryNamesAddedUpdatedAndSkipped() throws {
        let files = FakeFiles()
        files.contents[csvURL] =
            "text,soundsLike,pinned\nGroq,,false\nNew,,false\nAcme,ack-me,true\nBad,,perhaps\n"
        let model = try makeModel(terms: [term("Acme")], files: files)

        model.importTerms(from: csvURL)

        let summary = try XCTUnwrap(model.lastImport?.summary)
        XCTAssertTrue(summary.contains("added 2"), summary)
        XCTAssertTrue(summary.contains("updated 1"), summary)
        XCTAssertTrue(summary.contains("1 row skipped"), summary)
    }

    func test_importedTermsAreNormalizedSoTheyCannotDuplicateLater() throws {
        let files = FakeFiles()
        files.contents[csvURL] = "text,soundsLike,pinned\n\"  Example   Forms \",,false\n"
        let model = try makeModel(files: files)

        model.importTerms(from: csvURL)
        XCTAssertEqual(model.vocabulary.terms.map(\.text), ["Example Forms"])

        model.query = "example forms"
        model.createTerm()
        XCTAssertEqual(model.vocabulary.terms.count, 1)
    }

    // MARK: - Replacements

    func test_replacementsSurviveAReloadInOrder() throws {
        let directory = try makeDirectory()
        let model = try makeModel(
            replacements: [replacement("wordpress", "WordPress"),
                           replacement("ackme", "Acme")],
            directory: directory)

        XCTAssertEqual(model.replacements.replacements.map(\.find), ["wordpress", "ackme"])
        XCTAssertEqual(ReplacementStore(directory: directory).replacements.map(\.find),
                       ["wordpress", "ackme"])
    }

    func test_addingAReplacementSeedsItFromTheSearchFieldAndLeavesItInert() throws {
        let model = try makeModel()
        model.query = "ackme"

        let id = model.addReplacement()

        let added = try XCTUnwrap(model.replacements.replacements.first { $0.id == id })
        XCTAssertEqual(added.find, "ackme")
        XCTAssertEqual(added.replaceWith, "")
        XCTAssertFalse(added.isEnabled,
                       "an empty replaceWith is a legitimate delete-this-word rule, so the engine "
                       + "cannot skip a half-typed one — the new rule has to arrive switched off")
        XCTAssertEqual(ReplacementEngine.apply([added], to: "ackme five"), "ackme five",
                       "a half-typed rule must not eat the word it names")
        XCTAssertEqual(model.query, "")
    }

    func test_movingAReplacementReordersAndPersists() throws {
        let directory = try makeDirectory()
        let model = try makeModel(
            replacements: [replacement("a", "1"), replacement("b", "2"), replacement("c", "3")],
            directory: directory)

        model.moveReplacements(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(model.replacements.replacements.map(\.find), ["c", "a", "b"])
        XCTAssertEqual(ReplacementStore(directory: directory).replacements.map(\.find),
                       ["c", "a", "b"])
    }

    func test_updatingAndDeletingAReplacement() throws {
        let rule = replacement("ackme", "Acme")
        let model = try makeModel(replacements: [rule])

        var edited = rule
        edited.replaceWith = "Acme 5"
        edited.caseSensitive = true
        model.updateReplacement(edited)
        XCTAssertEqual(model.replacements.replacements.first?.replaceWith, "Acme 5")
        XCTAssertTrue(try XCTUnwrap(model.replacements.replacements.first).caseSensitive)

        model.deleteReplacement(id: rule.id)
        XCTAssertTrue(model.replacements.replacements.isEmpty)
    }

    func test_thePreviewRunsTheRealEngineInOrder() throws {
        let model = try makeModel(replacements: [
            replacement("ackme", "Acme"),
            replacement("Acme", "Acme 5", caseSensitive: true)
        ])
        model.previewInput = "I use ackme every day."

        XCTAssertEqual(model.previewOutput, "I use Acme 5 every day.",
                       "rule 2 operates on rule 1's output, per §7.2")
    }

    func test_thePreviewIgnoresADisabledRule() throws {
        let model = try makeModel(replacements: [replacement("ackme", "Acme", enabled: false)])
        model.previewInput = "ackme"

        XCTAssertEqual(model.previewOutput, "ackme")
    }

    func test_replacementSearchFiltersBothColumns() throws {
        let model = try makeModel(replacements: [
            replacement("ackme", "Acme"),
            replacement("wordpress", "WordPress")
        ])

        model.query = "WORD"
        XCTAssertEqual(model.visibleReplacements.map(\.find), ["wordpress"])

        model.query = "Acme"
        XCTAssertEqual(model.visibleReplacements.map(\.find), ["ackme"])
    }

    // MARK: - Honesty surfaces

    func test_theTermsTabSaysTheVocabularyIsNotSentYet() throws {
        let model = try makeModel(terms: [term("Acme")])
        model.tab = .terms

        if VocabularyViewModel.pipelineSendsVocabulary {
            XCTAssertNil(model.unwiredNotice)
        } else {
            let notice = try XCTUnwrap(
                model.unwiredNotice,
                "DictationPipeline passes vocabularyPrompt: \"\" — a budget indicator for a "
                + "prompt nothing sends has to say so")
            XCTAssertTrue(notice.contains("Task 16"), notice)
        }
    }

    func test_theReplacementsTabSaysNothingAppliesThemYet() throws {
        let model = try makeModel()
        model.tab = .replacements

        if VocabularyViewModel.pipelineAppliesReplacements {
            XCTAssertNil(model.unwiredNotice)
        } else {
            let notice = try XCTUnwrap(model.unwiredNotice)
            XCTAssertTrue(notice.contains("ReplacementEngine.apply"), notice)
        }
    }

    func test_aCorruptVocabularyFileSurfacesTheRecoveryWarningWithoutDefeatingIt() throws {
        let directory = try makeDirectory()
        try Data("{ not json".utf8)
            .write(to: directory.appendingPathComponent("vocabulary.json"))

        let model = try makeModel(directory: directory)

        XCTAssertEqual(model.recoveryWarnings.count, 1)
        XCTAssertTrue(model.vocabulary.terms.isEmpty)
        XCTAssertTrue(try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix("vocabulary.corrupt") },
            "the screen must not have suppressed the backup")

        model.dismissRecoveryWarnings()
        XCTAssertTrue(model.recoveryWarnings.isEmpty)
    }

    func test_aCorruptReplacementsFileSurfacesItsOwnWarning() throws {
        let directory = try makeDirectory()
        try Data("{ not json".utf8)
            .write(to: directory.appendingPathComponent("replacements.json"))

        let model = try makeModel(directory: directory)

        XCTAssertEqual(model.recoveryWarnings.count, 1)
        XCTAssertTrue(model.replacements.replacements.isEmpty)
    }

    func test_aFutureReplacementsFileVersionIsTreatedAsCorruptRatherThanDropped() throws {
        let directory = try makeDirectory()
        try Data(#"{"version": 999, "replacements": []}"#.utf8)
            .write(to: directory.appendingPathComponent("replacements.json"))

        let store = ReplacementStore(directory: directory)

        XCTAssertEqual(store.lastLoadResult, .corrupt)
        XCTAssertNotNil(store.recoveryWarning)
    }

    func test_aFreshReplacementStoreIsEmptyRatherThanSeeded() throws {
        let store = ReplacementStore(directory: try makeDirectory())

        XCTAssertTrue(store.replacements.isEmpty,
                      "a shipped guess about what the user is misheard as would rewrite words "
                      + "they said correctly")
        XCTAssertEqual(store.lastLoadResult, .missing)
        XCTAssertNil(store.recoveryWarning)
    }

    // MARK: - Normalization rule

    func test_normalizationTrimsCollapsesAndFoldsCaseButKeepsDiacritics() {
        XCTAssertEqual(VocabularyViewModel.normalizedKey("  Example   Forms \n"), "example forms")
        XCTAssertEqual(VocabularyViewModel.normalizedDisplay(" Example \t Forms "), "Example Forms")
        XCTAssertNotEqual(VocabularyViewModel.normalizedKey("Zoë"),
                          VocabularyViewModel.normalizedKey("Zoe"),
                          "these are two people's names, not a typo")
    }
}
