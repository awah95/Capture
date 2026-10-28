import Foundation
import NaturalLanguage

/// What the insertion ladder should actually carry: the transcript cased for the spot
/// the caret is in, and whether a separating space belongs in front of it.
struct InsertionDecision: Equatable {
    var text: String
    var prependsSpace: Bool
}

/// Smart capitalization and spacing (spec §8).
///
/// Every rule here is a *pure* function of the transcript, one character of context,
/// and the pinned vocabulary — deliberately, because the character it depends on comes
/// from an accessibility read that lies in exactly the apps where insertion is hardest.
/// Keeping the decision pure is what lets the lying be tested.
enum InsertionContext {

    /// `precedingCharacter` is nil when the AX read failed — the text is then
    /// returned unchanged, because guessing is worse than doing nothing.
    static func prepare(
        _ text: String,
        precedingCharacter: Character?,
        pinnedTerms: Set<String>
    ) -> InsertionDecision {
        guard let precedingCharacter else {
            // No context read means no context decisions. Nothing is inferred from the
            // transcript alone: a mid-sentence-looking transcript at the start of an
            // empty field is a perfectly ordinary sentence.
            return InsertionDecision(text: text, prependsSpace: false)
        }

        return InsertionDecision(
            text: casedText(text, after: precedingCharacter, pinnedTerms: pinnedTerms),
            prependsSpace: needsSpace(before: text, after: precedingCharacter)
        )
    }

    /// The single string the ladder hands to every rung, space already attached.
    ///
    /// The space is part of the payload rather than a separate keystroke because each
    /// rung inserts exactly once — a second write would double the failure surface of
    /// the one operation that has already proved it can silently do nothing.
    static func payload(
        _ text: String,
        precedingCharacter: Character?,
        pinnedTerms: Set<String>
    ) -> String {
        let decision = prepare(text, precedingCharacter: precedingCharacter, pinnedTerms: pinnedTerms)
        return decision.prependsSpace ? " " + decision.text : decision.text
    }

    // MARK: Spacing

    /// Punctuation that belongs to the word *before* it. A leading opening quote or
    /// bracket is punctuation too, but it opens something new and still wants its
    /// space — without this distinction dictation lands as `said"And then"`.
    private static let punctuationAttachingToPreviousWord: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "…", ")", "]", "}", "»", "”", "’", "'", "%", "‰"
    ]

    private static func needsSpace(before text: String, after preceding: Character) -> Bool {
        // Spec §8: only a word character earns a space. Note that this leaves an
        // insertion directly after "." or "," with none, even though "," is one of the
        // characters that triggers lowercasing — a gap in the spec, kept as written
        // because the spec is the authority on the rule and this is a taste call.
        guard isWordCharacter(preceding) else { return false }
        guard let first = text.first else { return false }
        // Never double a space — neither the caret's nor one the transcript brought.
        guard !first.isWhitespace else { return false }
        return !punctuationAttachingToPreviousWord.contains(first)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    // MARK: Capitalization

    private static func casedText(
        _ text: String,
        after preceding: Character,
        pinnedTerms: Set<String>
    ) -> String {
        // Spec §8's three triggers, and only those: a word character, a comma, or a
        // semicolon. After a period, a colon, a newline or an opening bracket the
        // transcript is starting a sentence and keeps its capital.
        guard isWordCharacter(preceding) || preceding == "," || preceding == ";" else {
            return text
        }

        guard let letterIndex = firstLetterIndexOfOpeningWord(in: text) else { return text }

        let word = word(in: text, containing: letterIndex)
        guard !isAcronym(word),
              !isEnglishFirstPersonPronoun(word),
              !isPinned(word, openingTextOf: text, pinnedTerms: pinnedTerms),
              !NameTagger.shared.tagsPersonalOrPlaceName(in: text, at: letterIndex) else {
            return text
        }

        // Locale-independent on purpose: `Character.lowercased()` maps I to i, while
        // `lowercased(with: Locale(identifier: "tr_TR"))` maps it to ı. The text's
        // language is the dictation's, not the machine's, so the system locale gets no
        // vote over an English transcript. Replacing by Character range also survives
        // a mapping that changes length (İ lowercases to two scalars).
        var cased = text
        cased.replaceSubrange(letterIndex...letterIndex, with: text[letterIndex].lowercased())
        return cased
    }

    /// The first letter, provided only opening punctuation precedes it.
    ///
    /// Scanning stops at whitespace or a digit rather than running on to the next word:
    /// if the transcript opens with "2 Sprints left" or an emoji, the word the caret is
    /// joining is not a word at all, and the capitalisation of whatever follows it is
    /// none of our business.
    private static func firstLetterIndexOfOpeningWord(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter { return index }
            if character.isWhitespace || character.isNumber { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    /// The word around `letterIndex`, without the punctuation hanging off either end.
    private static func word(in text: String, containing letterIndex: String.Index) -> String {
        var end = letterIndex
        while end < text.endIndex, isWordCharacter(text[end]) || text[end] == "'" || text[end] == "’" {
            end = text.index(after: end)
        }
        return String(text[letterIndex..<end])
            .trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
    }

    /// All-caps, and at least two letters long — "API", "IBM", "AWS2".
    ///
    /// The two-letter floor matters: it is the difference between preserving acronyms
    /// and preserving *every* capitalised word, which would switch mid-sentence
    /// lowercasing off altogether. A lone "A" is an article and gets lowercased.
    private static func isAcronym(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    /// The single-letter capital English never lowercases. "A" is an article; "I" is not.
    private static func isEnglishFirstPersonPronoun(_ word: String) -> Bool {
        word == "I"
    }

    /// Case-insensitively, because a pin records *that* a term's spelling is deliberate,
    /// not which case the user happened to type into the vocabulary screen.
    ///
    /// A multi-word pinned term protects its first word only when the transcript really
    /// opens with the whole term — otherwise pinning "Open Brain" would freeze the
    /// ordinary verb "Open" for good.
    private static func isPinned(
        _ word: String,
        openingTextOf text: String,
        pinnedTerms: Set<String>
    ) -> Bool {
        let word = word.lowercased()
        let text = text.lowercased()

        for term in pinnedTerms {
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !term.isEmpty else { continue }
            if term == word { return true }
            if term.contains(" "), textOpens(text, with: term) { return true }
        }
        return false
    }

    /// Prefix match that stops at a word boundary, so "Open Brainstorm" is not the
    /// pinned "Open Brain".
    private static func textOpens(_ text: String, with term: String) -> Bool {
        guard text.hasPrefix(term) else { return false }
        let next = text.index(text.startIndex, offsetBy: term.count)
        guard next < text.endIndex else { return true }
        return !isWordCharacter(text[next])
    }
}

/// The one shared `NLTagger`, behind a lock.
///
/// Construction is what costs: measured at ~0.23 ms per fresh tagger against ~0.01 ms
/// per reuse. Neither is large next to the 800 ms p50 budget, but insertion has been
/// measured at up to 332 ms of it and this runs on every single dictation, so the free
/// 20x is worth taking.
///
/// The instance is mutable state — it carries the last string it was handed — which is
/// why the lock is not optional: `string` is reassigned and read inside one critical
/// section, so one insertion's text can never answer the next insertion's question.
/// `@unchecked Sendable` is the lock's promise, not an assumption about `NLTagger`.
final class NameTagger: @unchecked Sendable {
    static let shared = NameTagger()

    private let lock = NSLock()
    private let tagger = NLTagger(tagSchemes: [.nameType])

    private static let constructionLock = NSLock()
    private static var constructions = 0

    /// How many taggers have been built, so a test can prove the cache is real.
    ///
    /// A wall-clock assertion cannot do that job: a per-call construction costs ~0.23 ms,
    /// which disappears inside any timing bound loose enough not to flake on a busy
    /// machine — the mutation "build a fresh tagger every call" survived a 500-iteration
    /// budget test. Counting is the only version of this claim that holds.
    static var constructionCount: Int {
        constructionLock.lock()
        defer { constructionLock.unlock() }
        return constructions
    }

    init() {
        Self.constructionLock.lock()
        Self.constructions += 1
        Self.constructionLock.unlock()
    }

    /// Spec §8 asks for personal *or place* names. `.nameType` also offers
    /// `.organizationName`, deliberately not honoured here: the spec names two of the
    /// three, and the organisation names it would add in practice ("API", "IBM") are
    /// already protected by the acronym rule.
    ///
    /// The tag is read at the first *letter*, not at `startIndex`: asked at the start of
    /// `"And then" he said` the tagger answers about the quotation mark — measured.
    func tagsPersonalOrPlaceName(in text: String, at index: String.Index) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        tagger.string = text
        let tag = tagger.tag(at: index, unit: .word, scheme: .nameType).0
        return tag == .personalName || tag == .placeName
    }
}
