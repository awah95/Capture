import XCTest
@testable import Captur

final class ThoughtProcessorTests: XCTestCase {
    private let p = ThoughtProcessor()

    func testVerbatimStyleProducesNoCleanedButATitle() {
        let (cleaned, title) = p.derive(from: "  just  some   raw words ", style: .verbatim)
        XCTAssertNil(cleaned)
        XCTAssertEqual(title, "Just some raw words")
    }

    func testCleanStyleTidiesProse() {
        let (cleaned, _) = p.derive(from: "hello   world. how are  you", style: .clean)
        XCTAssertEqual(cleaned, "Hello world. How are you")
    }

    func testBulletsStyleSplitsSentences() {
        let (cleaned, _) = p.derive(from: "first thing. second thing. third", style: .bullets)
        XCTAssertEqual(cleaned, "• First thing.\n• Second thing.\n• Third")
    }

    func testTitleTruncatesLongThoughts() {
        let long = "one two three four five six seven eight nine ten"
        let (_, title) = p.derive(from: long, style: .idea)
        XCTAssertEqual(title, "One two three four five six seven eight…")
    }

    func testEmptyInputYieldsNothing() {
        let (cleaned, title) = p.derive(from: "   ", style: .clean)
        XCTAssertNil(cleaned)
        XCTAssertNil(title)
    }
}
