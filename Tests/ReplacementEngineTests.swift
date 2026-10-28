import XCTest
@testable import Captur

/// Text replacements run on the raw transcript, before any LLM reshaping — so
/// they are pure string algebra and every rule can be pinned exactly.
///
/// The load-bearing property is *exactly once*: a rule whose replacement text
/// contains its own search text ("cat" → "cat and dog") must not re-read what it
/// just wrote. A naive repeated-scan implementation loops forever on that.
final class ReplacementEngineTests: XCTestCase {

    // MARK: - Helpers

    private func rule(_ find: String,
                      _ replaceWith: String,
                      wholeWordOnly: Bool = false,
                      caseSensitive: Bool = true,
                      isEnabled: Bool = true) -> Replacement {
        Replacement(id: UUID(),
                    find: find,
                    replaceWith: replaceWith,
                    wholeWordOnly: wholeWordOnly,
                    caseSensitive: caseSensitive,
                    isEnabled: isEnabled)
    }

    // MARK: - Core behaviour

    func test_appliesALiteralSubstitution() {
        let result = ReplacementEngine.apply([rule("btw", "by the way")],
                                             to: "btw I finished it")
        XCTAssertEqual(result, "by the way I finished it")
    }

    func test_replacesEveryOccurrenceInOnePass() {
        let result = ReplacementEngine.apply([rule("btw", "by the way")],
                                             to: "btw and btw again")
        XCTAssertEqual(result, "by the way and by the way again")
    }

    func test_wholeWordOnlyDoesNotMatchInsideALongerWord() {
        let result = ReplacementEngine.apply([rule("cat", "dog", wholeWordOnly: true)],
                                             to: "the cat is in a category")
        XCTAssertEqual(result, "the dog is in a category")
    }

    func test_withoutWholeWordOnlySubstringsAreMatched() {
        // The same rule, unanchored, deliberately does hit "category".
        let result = ReplacementEngine.apply([rule("cat", "dog")],
                                             to: "the cat is in a category")
        XCTAssertEqual(result, "the dog is in a dogegory")
    }

    func test_wholeWordOnlyMatchesWhenBoundedByPunctuation() {
        let result = ReplacementEngine.apply([rule("cat", "dog", wholeWordOnly: true)],
                                             to: "a cat, and a (cat).")
        XCTAssertEqual(result, "a dog, and a (dog).")
    }

    func test_caseInsensitiveMatchingPreservesTheReplacementCasing() {
        // The replacement text is typed by the user and is used verbatim — the
        // engine never tries to mirror the source's casing.
        let result = ReplacementEngine.apply(
            [rule("iphone", "iPhone", caseSensitive: false)],
            to: "IPHONE, iphone and IPhone")
        XCTAssertEqual(result, "iPhone, iPhone and iPhone")
    }

    func test_caseSensitiveRuleIgnoresDifferentlyCasedText() {
        let result = ReplacementEngine.apply([rule("iphone", "iPhone", caseSensitive: true)],
                                             to: "IPHONE and iphone")
        XCTAssertEqual(result, "IPHONE and iPhone")
    }

    func test_supportsAMultiLineReplacement() {
        let result = ReplacementEngine.apply([rule("sig", "Thanks,\nAvery\n")],
                                             to: "sig")
        XCTAssertEqual(result, "Thanks,\nAvery\n")
    }

    func test_matchesAcrossTextThatContainsNewlines() {
        let result = ReplacementEngine.apply([rule("todo", "TODO")],
                                             to: "line one\ntodo\nline three")
        XCTAssertEqual(result, "line one\nTODO\nline three")
    }

    func test_skipsDisabledRules() {
        let result = ReplacementEngine.apply([rule("btw", "by the way", isEnabled: false)],
                                             to: "btw hello")
        XCTAssertEqual(result, "btw hello")
    }

    func test_appliesRulesInOrderSoLaterRulesSeeEarlierOutput() {
        let result = ReplacementEngine.apply([rule("a", "b"), rule("b", "c")],
                                             to: "a")
        XCTAssertEqual(result, "c")
    }

    func test_reversingRuleOrderChangesTheResult() {
        // Order is meaningful: rule 2 no longer has any "b" to act on.
        let result = ReplacementEngine.apply([rule("b", "c"), rule("a", "b")],
                                             to: "a")
        XCTAssertEqual(result, "b")
    }

    // MARK: - The exactly-once property

    func test_aRuleWhoseOutputContainsItsOwnFindAppliesExactlyOnce() {
        let result = ReplacementEngine.apply([rule("cat", "cat and dog")],
                                             to: "the cat sat")
        XCTAssertEqual(result, "the cat and dog sat")
    }

    func test_aSelfContainingRuleAppliesOncePerOriginalOccurrence() {
        let result = ReplacementEngine.apply([rule("cat", "cat and dog")],
                                             to: "cat cat")
        XCTAssertEqual(result, "cat and dog cat and dog")
    }

    func test_aRuleThatGrowsTheTextIsNotReappliedByALaterIdenticalPass() {
        // "hi" → "hi hi" must double exactly once, not explode.
        let result = ReplacementEngine.apply([rule("hi", "hi hi")], to: "hi")
        XCTAssertEqual(result, "hi hi")
    }

    // MARK: - Literal treatment of user input

    func test_treatsRegexMetacharactersInFindLiterally() {
        let result = ReplacementEngine.apply([rule("a.b", "X")],
                                             to: "axb and a.b")
        XCTAssertEqual(result, "axb and X")
    }

    func test_treatsRegexQuantifiersAndGroupsInFindLiterally() {
        let result = ReplacementEngine.apply([rule("(foo)+", "bar")],
                                             to: "(foo)+ foofoo")
        XCTAssertEqual(result, "bar foofoo")
    }

    func test_treatsDollarAndBackslashInReplacementLiterally() {
        // "$1" must not be read as a capture-group reference and "\n" must stay
        // two characters, not become a newline.
        let result = ReplacementEngine.apply([rule("x", "$1 \\n")], to: "x")
        XCTAssertEqual(result, "$1 \\n")
    }

    func test_treatsABackslashOnlyReplacementLiterally() {
        let result = ReplacementEngine.apply([rule("x", "\\")], to: "ax")
        XCTAssertEqual(result, "a\\")
    }

    // MARK: - Degenerate input

    func test_anEmptyFindIsANoOp() {
        let result = ReplacementEngine.apply([rule("", "something")],
                                             to: "untouched text")
        XCTAssertEqual(result, "untouched text")
    }

    func test_emptyInputTextReturnsEmpty() {
        XCTAssertEqual(ReplacementEngine.apply([rule("a", "b")], to: ""), "")
    }

    func test_noRulesReturnsTheTextUnchanged() {
        XCTAssertEqual(ReplacementEngine.apply([], to: "hello there"), "hello there")
    }

    func test_aRuleThatMatchesNothingLeavesTheTextAlone() {
        XCTAssertEqual(ReplacementEngine.apply([rule("zzz", "!")], to: "hello"), "hello")
    }

    func test_anEmptyReplacementDeletesTheMatch() {
        let result = ReplacementEngine.apply([rule(" um,", "")],
                                             to: "so, um, anyway")
        XCTAssertEqual(result, "so, anyway")
    }

    // MARK: - Positional and overlap edge cases

    func test_matchesAtTheVeryStartAndVeryEndOfTheText() {
        let result = ReplacementEngine.apply([rule("ab", "X")], to: "ab middle ab")
        XCTAssertEqual(result, "X middle X")
    }

    func test_theWholeTextCanBeASingleMatch() {
        XCTAssertEqual(ReplacementEngine.apply([rule("all", "none")], to: "all"), "none")
    }

    func test_overlappingCandidatesAreConsumedLeftToRightWithoutOverlap() {
        // "aaaa" holds three overlapping "aa" candidates; a left-to-right,
        // non-overlapping pass takes the first and the third character pair.
        let result = ReplacementEngine.apply([rule("aa", "b")], to: "aaaa")
        XCTAssertEqual(result, "bb")
    }

    func test_anOddOverlapLeavesTheTrailingCharacter() {
        let result = ReplacementEngine.apply([rule("aa", "b")], to: "aaa")
        XCTAssertEqual(result, "ba")
    }

    // MARK: - Unicode

    func test_handlesUnicodeAndEmojiInBothFields() {
        let result = ReplacementEngine.apply([rule("shrug", "¯\\_(ツ)_/¯ 🤷")],
                                             to: "shrug done")
        XCTAssertEqual(result, "¯\\_(ツ)_/¯ 🤷 done")
    }

    func test_matchesAnEmojiFindWithoutCorruptingSurroundingText() {
        let result = ReplacementEngine.apply([rule("🐈", "cat")], to: "a 🐈 and a 🐕")
        XCTAssertEqual(result, "a cat and a 🐕")
    }

    func test_handlesAccentedCharactersCaseInsensitively() {
        let result = ReplacementEngine.apply([rule("café", "coffee", caseSensitive: false)],
                                             to: "CAFÉ time")
        XCTAssertEqual(result, "coffee time")
    }

    // MARK: - Mixed rule sets

    func test_appliesAMixOfEnabledAndDisabledRulesInOrder() {
        let rules = [
            rule("btw", "by the way"),
            rule("imo", "in my opinion", isEnabled: false),
            rule("cat", "cat and dog", wholeWordOnly: true)
        ]
        let result = ReplacementEngine.apply(rules, to: "btw imo the cat in the category")
        XCTAssertEqual(result, "by the way imo the cat and dog in the category")
    }

    // MARK: - Model

    func test_replacementRoundTripsThroughCoding() throws {
        let original = rule("btw", "by the way", wholeWordOnly: true, caseSensitive: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Replacement.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
