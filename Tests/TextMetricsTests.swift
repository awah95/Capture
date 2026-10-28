import XCTest
@testable import Captur

final class TextMetricsTests: XCTestCase {
    // MARK: - Word count

    func testEmptyStringHasNoWords() {
        XCTAssertEqual(TextMetrics.wordCount(""), 0)
    }

    func testWhitespaceOnlyStringHasNoWords() {
        XCTAssertEqual(TextMetrics.wordCount("   "), 0)
        XCTAssertEqual(TextMetrics.wordCount(" \t\n \u{00A0} "), 0)
    }

    func testPunctuationDoesNotInflateTheCount() {
        XCTAssertEqual(TextMetrics.wordCount("hello, world!"), 2)
        XCTAssertEqual(TextMetrics.wordCount("Wait — what?"), 2)
        XCTAssertEqual(TextMetrics.wordCount("..."), 0)
        XCTAssertEqual(TextMetrics.wordCount("? ! ;"), 0)
    }

    func testRepeatedSeparatorsCollapse() {
        XCTAssertEqual(TextMetrics.wordCount("one    two\t\tthree"), 3)
    }

    func testMultiLineTextCountsEveryLine() {
        let text = """
        First line here.
        Second line too!

        Third.
        """
        XCTAssertEqual(TextMetrics.wordCount(text), 7)
    }

    /// Documented choice: an apostrophized form is ONE word — "don't" is one
    /// spoken word, and splitting it would overstate dictation throughput.
    func testApostrophizedFormIsOneWord() {
        XCTAssertEqual(TextMetrics.wordCount("don't"), 1)
        XCTAssertEqual(TextMetrics.wordCount("don\u{2019}t"), 1)
        XCTAssertEqual(TextMetrics.wordCount("it's Avery's file"), 3)
    }

    /// Documented choice: a hyphenated form is ONE word — it is spoken as one
    /// unit, so "well-known" counts once.
    func testHyphenatedFormIsOneWord() {
        XCTAssertEqual(TextMetrics.wordCount("well-known"), 1)
        XCTAssertEqual(TextMetrics.wordCount("a well-known case"), 3)
        XCTAssertEqual(TextMetrics.wordCount("state-of-the-art"), 1)
    }

    func testTrailingAndLeadingPunctuationIsStripped() {
        XCTAssertEqual(TextMetrics.wordCount("\"quoted\" (aside)"), 2)
        XCTAssertEqual(TextMetrics.wordCount("-- dash --"), 1)
    }

    func testUnicodeWordsCount() {
        XCTAssertEqual(TextMetrics.wordCount("café naïve"), 2)
        XCTAssertEqual(TextMetrics.wordCount("日本語 テスト"), 2)
        XCTAssertEqual(TextMetrics.wordCount("emoji 🎉 counts as nothing"), 4)
    }

    func testNumbersAndAlphanumericsCount() {
        XCTAssertEqual(TextMetrics.wordCount("ship 3 builds"), 3)
        XCTAssertEqual(TextMetrics.wordCount("version 2.1.4"), 2)
    }

    // MARK: - Normalized edit distance

    func testIdenticalTextHasZeroDistance() {
        XCTAssertEqual(TextMetrics.normalizedEditDistance("one two three", "one two three"), 0.0, accuracy: 1e-9)
    }

    func testBothEmptyHasZeroDistanceNotNaN() {
        let value = TextMetrics.normalizedEditDistance("", "")
        XCTAssertFalse(value.isNaN)
        XCTAssertEqual(value, 0.0, accuracy: 1e-9)

        let whitespace = TextMetrics.normalizedEditDistance("   ", "\n\t")
        XCTAssertFalse(whitespace.isNaN)
        XCTAssertEqual(whitespace, 0.0, accuracy: 1e-9)
    }

    func testOneEmptySideHasFullDistance() {
        XCTAssertEqual(TextMetrics.normalizedEditDistance("", "one two"), 1.0, accuracy: 1e-9)
        XCTAssertEqual(TextMetrics.normalizedEditDistance("one two", ""), 1.0, accuracy: 1e-9)
    }

    func testFullyDisjointTextHasFullDistance() {
        XCTAssertEqual(
            TextMetrics.normalizedEditDistance("alpha beta gamma", "one two three"),
            1.0,
            accuracy: 1e-9
        )
    }

    func testOneWordChangedInTenIsATenth() {
        let a = "one two three four five six seven eight nine ten"
        let b = "one two three four five six seven eight nine eleven"
        XCTAssertEqual(TextMetrics.normalizedEditDistance(a, b), 0.1, accuracy: 1e-9)
    }

    func testOneWordDeletedFromTenIsATenth() {
        let a = "one two three four five six seven eight nine ten"
        let b = "one two three four five six seven eight nine"
        XCTAssertEqual(TextMetrics.normalizedEditDistance(a, b), 0.1, accuracy: 1e-9)
    }

    func testOneWordInsertedIntoNineIsATenth() {
        let a = "one two three four five six seven eight nine"
        let b = "one two three four five six seven eight nine ten"
        XCTAssertEqual(TextMetrics.normalizedEditDistance(a, b), 0.1, accuracy: 1e-9)
    }

    func testDistanceIsSymmetric() {
        let a = "the quick brown fox jumps"
        let b = "the slow brown dog jumps over"
        XCTAssertEqual(
            TextMetrics.normalizedEditDistance(a, b),
            TextMetrics.normalizedEditDistance(b, a),
            accuracy: 1e-9
        )
    }

    func testDistanceStaysWithinUnitRange() {
        let pairs = [
            ("hello there friend", "hello"),
            ("a b c d e f g", "z"),
            ("one", "one two three four")
        ]
        for (a, b) in pairs {
            let value = TextMetrics.normalizedEditDistance(a, b)
            XCTAssertGreaterThanOrEqual(value, 0.0)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
    }

    /// The metric answers "how much is the LLM changing my words", so it must be
    /// blind to punctuation and casing the mode adds for readability.
    func testPunctuationAndCasingOnlyChangesReadAsZero() {
        XCTAssertEqual(
            TextMetrics.normalizedEditDistance("hello world", "Hello, world!"),
            0.0,
            accuracy: 1e-9
        )
    }

    func testCompletelyReplacedHalfOfTheWords() {
        let a = "one two three four"
        let b = "one two nine ten"
        XCTAssertEqual(TextMetrics.normalizedEditDistance(a, b), 0.5, accuracy: 1e-9)
    }

    func testLongInputsStayCheap() {
        let a = (0..<400).map { "word\($0)" }.joined(separator: " ")
        let b = (0..<400).map { $0 == 200 ? "changed" : "word\($0)" }.joined(separator: " ")
        let start = Date()
        let value = TextMetrics.normalizedEditDistance(a, b)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(value, 1.0 / 400.0, accuracy: 1e-9)
        XCTAssertLessThan(elapsed, 1.0, "400-word edit distance took \(elapsed)s")
    }
}
