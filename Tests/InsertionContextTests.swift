import NaturalLanguage
import XCTest
@testable import Captur

final class InsertionContextTests: XCTestCase {
    func test_lowercasesTheFirstLetterMidSentence() {
        let d = InsertionContext.prepare("And then we shipped", precedingCharacter: "d", pinnedTerms: [])
        XCTAssertEqual(d.text, "and then we shipped")
        XCTAssertTrue(d.prependsSpace)
    }

    func test_keepsCapitalAfterSentenceEndingPunctuation() {
        let d = InsertionContext.prepare("And then we shipped", precedingCharacter: ".", pinnedTerms: [])
        XCTAssertEqual(d.text, "And then we shipped")
    }

    func test_keepsCapitalAtTheStartOfAnEmptyField() {
        let d = InsertionContext.prepare("Hello there", precedingCharacter: nil, pinnedTerms: [])
        XCTAssertEqual(d.text, "Hello there")
        XCTAssertFalse(d.prependsSpace)
    }

    func test_neverLowercasesAnAcronym() {
        let d = InsertionContext.prepare("API keys rotate", precedingCharacter: "e", pinnedTerms: [])
        XCTAssertEqual(d.text, "API keys rotate")
    }

    func test_neverLowercasesAPinnedVocabularyTerm() {
        let d = InsertionContext.prepare("Captur is ready", precedingCharacter: "e", pinnedTerms: ["Captur"])
        XCTAssertEqual(d.text, "Captur is ready")
    }

    func test_neverLowercasesARecognizedPersonalName() {
        let d = InsertionContext.prepare("Sarah agreed", precedingCharacter: "e", pinnedTerms: [])
        XCTAssertEqual(d.text, "Sarah agreed")
    }

    func test_doesNotDoubleAnExistingSpace() {
        let d = InsertionContext.prepare("more words", precedingCharacter: " ", pinnedTerms: [])
        XCTAssertFalse(d.prependsSpace)
    }

    func test_doesNotPrependSpaceBeforePunctuation() {
        let d = InsertionContext.prepare(", and also", precedingCharacter: "d", pinnedTerms: [])
        XCTAssertFalse(d.prependsSpace)
    }

    // MARK: The AX read failing is a first-class input, not an edge case

    /// The read that feeds this is `kAXStringForRangeParameterizedAttribute` — the same
    /// class of API as the write that once reported success while a whole dictation
    /// vanished. When it answers nothing, the text must come out byte-identical: a
    /// wrong preceding character silently rewrites what the user said.
    func test_aFailedPrecedingCharacterReadNeverChangesTheText() {
        let midSentenceLooking = "And then we shipped"
        let d = InsertionContext.prepare(midSentenceLooking, precedingCharacter: nil, pinnedTerms: [])
        XCTAssertEqual(d.text, midSentenceLooking)
        XCTAssertFalse(d.prependsSpace)
    }

    // MARK: Which preceding characters trigger the lowercase

    func test_lowercasesAfterAComma() {
        let d = InsertionContext.prepare("And then", precedingCharacter: ",", pinnedTerms: [])
        XCTAssertEqual(d.text, "and then")
    }

    func test_lowercasesAfterASemicolon() {
        let d = InsertionContext.prepare("And then", precedingCharacter: ";", pinnedTerms: [])
        XCTAssertEqual(d.text, "and then")
    }

    /// Spec §8 names exactly three triggers — word character, comma, semicolon. A colon
    /// is not one of them, and a sentence after a colon usually is capitalised.
    func test_keepsCapitalAfterAColon() {
        let d = InsertionContext.prepare("And then", precedingCharacter: ":", pinnedTerms: [])
        XCTAssertEqual(d.text, "And then")
    }

    func test_lowercasesAfterADigitBecauseADigitIsAWordCharacter() {
        let d = InsertionContext.prepare("And then", precedingCharacter: "3", pinnedTerms: [])
        XCTAssertEqual(d.text, "and then")
        XCTAssertTrue(d.prependsSpace)
    }

    func test_treatsAnUnderscoreAsAWordCharacter() {
        let d = InsertionContext.prepare("And then", precedingCharacter: "_", pinnedTerms: [])
        XCTAssertEqual(d.text, "and then")
        XCTAssertTrue(d.prependsSpace)
    }

    // MARK: Spacing

    /// Documents a **spec gap**, deliberately implemented as spec §8 words it: the space
    /// is prepended only after a *word character*, so an insertion straight after "." or
    /// "," gets none. Fixing it is a one-line change to `prependsSpace`; it is not made
    /// here because the spec is the authority and this is a taste call, not a bug in the
    /// code. See the report accompanying this task.
    func test_doesNotPrependSpaceAfterSentencePunctuation_documentsASpecGap() {
        XCTAssertFalse(
            InsertionContext.prepare("And then", precedingCharacter: ".", pinnedTerms: []).prependsSpace)
        XCTAssertFalse(
            InsertionContext.prepare("and then", precedingCharacter: ",", pinnedTerms: []).prependsSpace)
    }

    /// "does not already begin with punctuation" means punctuation that belongs to the
    /// *previous* word. An opening quote or bracket opens something new and still wants
    /// its space, or dictation lands as `said"And then"`.
    func test_prependsSpaceBeforeOpeningPunctuation() {
        XCTAssertTrue(
            InsertionContext.prepare("\"And then\"", precedingCharacter: "d", pinnedTerms: []).prependsSpace)
        XCTAssertTrue(
            InsertionContext.prepare("(and then)", precedingCharacter: "d", pinnedTerms: []).prependsSpace)
    }

    func test_doesNotPrependSpaceBeforeEachClosingPunctuationMark() {
        for text in [", and", ". And", "; and", ": and", "! And", "? And", ") and", "] and"] {
            XCTAssertFalse(
                InsertionContext.prepare(text, precedingCharacter: "d", pinnedTerms: []).prependsSpace,
                "\(text) opens with punctuation that attaches to the previous word")
        }
    }

    func test_doesNotDoubleASpaceTheTextAlreadyCarries() {
        let d = InsertionContext.prepare(" and then", precedingCharacter: "d", pinnedTerms: [])
        XCTAssertFalse(d.prependsSpace)
    }

    // MARK: What counts as the first letter

    /// A leading quotation mark is not the first letter, and `NLTagger` asked at
    /// `startIndex` answers about the quote, not the word — measured.
    func test_lowercasesThroughALeadingQuotationMark() {
        let d = InsertionContext.prepare("\"And then\" he said", precedingCharacter: "d", pinnedTerms: [])
        XCTAssertEqual(d.text, "\"and then\" he said")
    }

    /// A first token that is a digit or an emoji is left completely alone rather than
    /// scanning forward past the whitespace to some later word: whatever word came next
    /// is not the one the caret is joining, so its capitalisation is none of our business.
    func test_leavesTextAloneWhenTheFirstTokenIsNotAWord() {
        for text in ["2 Sprints left", "🙂 And then"] {
            XCTAssertEqual(
                InsertionContext.prepare(text, precedingCharacter: "d", pinnedTerms: []).text,
                text)
        }
    }

    /// Leading punctuation of any kind is skipped to reach the first letter — an ellipsis
    /// resuming a sentence gets the same treatment as an opening quote, because in both
    /// cases the word behind it is the one the caret is joining.
    func test_lowercasesThroughLeadingPunctuationThatIsNotAWord() {
        XCTAssertEqual(
            InsertionContext.prepare("…And then", precedingCharacter: "d", pinnedTerms: []).text,
            "…and then")
    }

    func test_emptyTextIsUnchangedAndGetsNoSpace() {
        let d = InsertionContext.prepare("", precedingCharacter: "d", pinnedTerms: [])
        XCTAssertEqual(d.text, "")
        XCTAssertFalse(d.prependsSpace)
    }

    // MARK: Casing must be Unicode- and locale-correct

    /// Locale-independent lowercasing, on purpose. `"I".lowercased(with: tr_TR)` is "ı" —
    /// a Turkish system locale must not rewrite an English transcript, because the text's
    /// language is the dictation's, not the machine's.
    func test_lowercasingDoesNotFollowTheSystemLocale() {
        let d = InsertionContext.prepare("Iterate on it", precedingCharacter: "d", pinnedTerms: [])
        XCTAssertEqual(d.text, "iterate on it")
        XCTAssertFalse(d.text.hasPrefix("ı"), "Turkish dotless i must not appear in English text")
    }

    /// The one single-letter capital English never lowercases.
    func test_keepsTheEnglishPronounI() {
        let d = InsertionContext.prepare("I shipped it", precedingCharacter: "d", pinnedTerms: [])
        XCTAssertEqual(d.text, "I shipped it")
    }

    /// The guard against "preserve anything capitalised", which would silently switch
    /// mid-sentence lowercasing off altogether. A lone "A" is an article, not an acronym.
    func test_lowercasesASingleLetterArticle() {
        let d = InsertionContext.prepare("A meeting was booked", precedingCharacter: "d", pinnedTerms: [])
        XCTAssertEqual(d.text, "a meeting was booked")
    }

    /// …and the same guard from the other side: an ordinary capitalised word that happens
    /// to be a common noun is not a name and is not an acronym.
    func test_lowercasesAnOrdinaryCapitalisedWord() {
        for (text, expected) in [
            ("Ships are big", "ships are big"),
            ("Interesting point", "interesting point"),
            ("Then we left", "then we left")
        ] {
            XCTAssertEqual(
                InsertionContext.prepare(text, precedingCharacter: "d", pinnedTerms: []).text,
                expected)
        }
    }

    // MARK: Pinned vocabulary

    func test_pinnedTermMatchIgnoresCase() {
        let d = InsertionContext.prepare("Captur is ready", precedingCharacter: "e", pinnedTerms: ["captur"])
        XCTAssertEqual(d.text, "Captur is ready")
    }

    /// A multi-word pinned term protects its first word only when the text really opens
    /// with the whole term — otherwise pinning "Open Brain" would freeze the verb "Open".
    func test_multiWordPinnedTermProtectsOnlyTheActualTerm() {
        XCTAssertEqual(
            InsertionContext.prepare("Open Brain is ready", precedingCharacter: "d", pinnedTerms: ["Open Brain"]).text,
            "Open Brain is ready")
        XCTAssertEqual(
            InsertionContext.prepare("Open the door", precedingCharacter: "d", pinnedTerms: ["Open Brain"]).text,
            "open the door")
    }

    func test_anUnrelatedPinnedTermDoesNotProtectAnything() {
        let d = InsertionContext.prepare("And then", precedingCharacter: "d", pinnedTerms: ["Captur", "Groq"])
        XCTAssertEqual(d.text, "and then")
    }

    // MARK: The cached NLTagger

    /// One `NLTagger` is reused across insertions, and it holds the last string it was
    /// given. That is state, so this interleaves the two answers in both orders: a leak
    /// shows up as the previous call's verdict applied to this call's text.
    func test_theCachedNameTaggerDoesNotLeakStateBetweenCalls() {
        let name = "Sarah agreed"
        let notAName = "And then we shipped"

        for _ in 0..<3 {
            XCTAssertEqual(
                InsertionContext.prepare(name, precedingCharacter: "d", pinnedTerms: []).text,
                "Sarah agreed")
            XCTAssertEqual(
                InsertionContext.prepare(notAName, precedingCharacter: "d", pinnedTerms: []).text,
                "and then we shipped")
            XCTAssertEqual(
                InsertionContext.prepare(notAName, precedingCharacter: "d", pinnedTerms: []).text,
                "and then we shipped")
            XCTAssertEqual(
                InsertionContext.prepare(name, precedingCharacter: "d", pinnedTerms: []).text,
                "Sarah agreed")
        }
    }

    /// A pinned term must not stick to the next insertion either — the pinned set is an
    /// argument, and nothing in the cache may outlive the call.
    func test_pinnedProtectionDoesNotCarryIntoTheNextCall() {
        XCTAssertEqual(
            InsertionContext.prepare("Captur is ready", precedingCharacter: "d", pinnedTerms: ["Captur"]).text,
            "Captur is ready")
        XCTAssertEqual(
            InsertionContext.prepare("Captur is ready", precedingCharacter: "d", pinnedTerms: []).text,
            "captur is ready")
    }

    /// The claim the timing test below cannot make. Under the mutation "construct a
    /// tagger per call" the 500-iteration budget test still passed — 0.23 ms each is
    /// invisible inside any bound loose enough to be stable — so the cache is asserted by
    /// counting instead. Compared before-and-after rather than to 1, so test order
    /// cannot matter.
    func test_theNameTaggerIsBuiltOnceNoMatterHowManyInsertions() {
        _ = InsertionContext.prepare("Sarah agreed", precedingCharacter: "d", pinnedTerms: [])
        let constructionsSoFar = NameTagger.constructionCount

        for _ in 0..<50 {
            _ = InsertionContext.prepare("Sarah agreed", precedingCharacter: "d", pinnedTerms: [])
        }

        XCTAssertEqual(
            NameTagger.constructionCount,
            constructionsSoFar,
            "an NLTagger was constructed per insertion")
    }

    /// The same claim measured rather than counted, and measured *relatively* so the
    /// answer does not depend on how fast or how busy the machine is: the baseline is
    /// what a per-call construction costs here, right now. An absolute bound cannot do
    /// this — one loose enough to be stable is one a 0.23 ms regression hides inside.
    func test_theNameCheckIsFasterThanBuildingATaggerEveryCall() {
        let iterations = 300
        let sample = "Sarah agreed"

        let baselineStarted = Date()
        for _ in 0..<iterations {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = sample
            _ = tagger.tag(at: sample.startIndex, unit: .word, scheme: .nameType)
        }
        let perCallConstruction = Date().timeIntervalSince(baselineStarted)

        _ = InsertionContext.prepare(sample, precedingCharacter: "d", pinnedTerms: [])
        let started = Date()
        for _ in 0..<iterations {
            _ = InsertionContext.prepare(sample, precedingCharacter: "d", pinnedTerms: [])
        }
        let shared = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            shared,
            perCallConstruction / 2,
            "\(iterations) preparations took \(shared * 1000) ms against "
                + "\(perCallConstruction * 1000) ms of per-call construction — the shared tagger is gone")
    }

    /// The whole pipeline has 800 ms p50 and insertion has been measured at 8–332 ms of
    /// it, so the name check has to be background noise. A hard ceiling only: the two
    /// tests above are what actually pin the cache.
    func test_preparingIsFastEnoughForTheLatencyBudget() {
        _ = InsertionContext.prepare("warm up", precedingCharacter: "d", pinnedTerms: [])

        let started = Date()
        for _ in 0..<500 {
            _ = InsertionContext.prepare("Sarah agreed and then we shipped", precedingCharacter: "d", pinnedTerms: [])
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 1.0, "500 preparations took \(elapsed * 1000) ms — the shared tagger is gone")
    }

    /// The shared tagger is guarded by a lock; this is what would trip over its absence.
    func test_preparingIsSafeFromSeveralThreadsAtOnce() {
        let results = NSMutableArray()
        let guardLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let text = index.isMultiple(of: 2) ? "Sarah agreed" : "And then we shipped"
            let prepared = InsertionContext.prepare(text, precedingCharacter: "d", pinnedTerms: [])
            guardLock.lock()
            results.add(prepared.text)
            guardLock.unlock()
        }

        XCTAssertEqual(results.count, 64)
        for case let text as String in results {
            XCTAssertTrue(
                text == "Sarah agreed" || text == "and then we shipped",
                "unexpected result under concurrency: \(text)")
        }
    }

    // MARK: The single string the ladder actually carries

    func test_payloadCarriesTheSpaceItDecidedOn() {
        XCTAssertEqual(
            InsertionContext.payload("And then", precedingCharacter: "d", pinnedTerms: []),
            " and then")
        XCTAssertEqual(
            InsertionContext.payload(", and then", precedingCharacter: "d", pinnedTerms: []),
            ", and then")
        XCTAssertEqual(
            InsertionContext.payload("And then", precedingCharacter: nil, pinnedTerms: []),
            "And then")
    }
}
