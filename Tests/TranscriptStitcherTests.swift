import XCTest
@testable import Captur

/// The stitcher is pure text in / text out, so every seam case can be driven
/// deterministically — no audio, no network, no Whisper.
final class TranscriptStitcherTests: XCTestCase {

    /// Default silence is 0.8s: under the 1.5s sentence-break threshold, so
    /// punctuation repair is *armed* unless a test says otherwise.
    private func r(_ i: Int, _ t: String?, silence: TimeInterval = 0.8) -> SegmentResult {
        SegmentResult(index: i, text: t, precedingSilence: silence)
    }

    // MARK: - Ordering

    func test_joinsInIndexOrderRegardlessOfCompletionOrder() {
        let out = TranscriptStitcher.stitch([
            r(2, "the third part"),
            r(0, "This is"),
            r(1, "the second part and"),
        ], repairSeams: true)
        XCTAssertEqual(out, "This is the second part and the third part")
    }

    func test_singleSegmentIsReturnedUnchanged() {
        XCTAssertEqual(
            TranscriptStitcher.stitch([r(0, "just the one segment.")], repairSeams: true),
            "just the one segment."
        )
    }

    func test_emptyInputProducesEmptyString() {
        XCTAssertEqual(TranscriptStitcher.stitch([], repairSeams: true), "")
        XCTAssertEqual(TranscriptStitcher.stitch([], repairSeams: false), "")
    }

    // MARK: - Duplicate seam words (Whisper re-emitting the prompt tail)

    func test_removesDuplicatedSeamWordsFromThePromptTail() {
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship the feature"),
            r(1, "ship the feature on Friday"),
        ], repairSeams: true)
        XCTAssertEqual(out, "we should ship the feature on Friday")
    }

    func test_overlapMatchIgnoresCaseAndPunctuation() {
        // "Feature," on the left must match "feature" on the right.
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship the Feature,"),
            r(1, "feature on Friday", silence: 2.5),
        ], repairSeams: true)
        XCTAssertEqual(out, "we should ship the Feature, on Friday")
    }

    func test_overlapUpToFourWordsIsRemoved() {
        let out = TranscriptStitcher.stitch([
            r(0, "one two three four five"),
            r(1, "two three four five six"),
        ], repairSeams: true)
        XCTAssertEqual(out, "one two three four five six")
    }

    func test_overlapCoveringTheEntireIncomingSegmentDropsIt() {
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship the feature"),
            r(1, "the feature"),
            r(2, "on Friday"),
        ], repairSeams: true)
        XCTAssertEqual(out, "we should ship the feature on Friday")
    }

    // MARK: - Mid-sentence punctuation damage

    func test_repairsMidSentencePunctuationAcrossAShortPause() {
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship the feature."),
            r(1, "On Friday if the tests pass", silence: 0.7),
        ], repairSeams: true)
        XCTAssertEqual(out, "we should ship the feature on Friday if the tests pass")
    }

    func test_keepsPunctuationAcrossALongPause() {
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship the feature."),
            r(1, "Separately, the docs need work", silence: 2.5),
        ], repairSeams: true)
        XCTAssertEqual(out, "we should ship the feature. Separately, the docs need work")
    }

    func test_lowercasesAStrandedCapitalEvenWithoutATerminalFullStop() {
        // Whisper does not always punctuate the tail of a segment; the stray
        // capital on the next one is damage all the same.
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship the feature"),
            r(1, "On Friday if the tests pass", silence: 0.7),
        ], repairSeams: true)
        XCTAssertEqual(out, "we should ship the feature on Friday if the tests pass")
    }

    func test_keepsAQuestionMarkAcrossAShortPause() {
        // "?" is a deliberate sentence end — Whisper does not emit it by accident
        // mid-clause the way it emits a full stop.
        let out = TranscriptStitcher.stitch([
            r(0, "did we ship it?"),
            r(1, "On Friday we can check", silence: 0.7),
        ], repairSeams: true)
        XCTAssertEqual(out, "did we ship it? On Friday we can check")
    }

    func test_keepsAnExclamationMarkAcrossAShortPause() {
        let out = TranscriptStitcher.stitch([
            r(0, "we shipped it!"),
            r(1, "On Friday no less", silence: 0.7),
        ], repairSeams: true)
        XCTAssertEqual(out, "we shipped it! On Friday no less")
    }

    func test_keepsAnEllipsisAcrossAShortPause() {
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship the feature..."),
            r(1, "On Friday maybe", silence: 0.7),
        ], repairSeams: true)
        XCTAssertEqual(out, "we should ship the feature... On Friday maybe")
    }

    // MARK: - Things that must never be lowercased

    func test_neverLowercasesAProperNounAcrossASeam() {
        let out = TranscriptStitcher.stitch([
            r(0, "I spoke to him."),
            r(1, "Sarah agreed with the plan", silence: 0.7),
        ], repairSeams: true)
        XCTAssertEqual(out, "I spoke to him. Sarah agreed with the plan")
    }

    func test_neverLowercasesAPlaceOrOrganizationAcrossASeam() {
        XCTAssertEqual(
            TranscriptStitcher.stitch([
                r(0, "we sent the box."),
                r(1, "London was the destination", silence: 0.7),
            ], repairSeams: true),
            "we sent the box. London was the destination"
        )
        XCTAssertEqual(
            TranscriptStitcher.stitch([
                r(0, "we heard back."),
                r(1, "Microsoft announced the deal", silence: 0.7),
            ], repairSeams: true),
            "we heard back. Microsoft announced the deal"
        )
    }

    func test_neverLowercasesThePronounI() {
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship it."),
            r(1, "I think so anyway", silence: 0.7),
        ], repairSeams: true)
        XCTAssertEqual(out, "we should ship it. I think so anyway")
    }

    func test_neverLowercasesAnAcronym() {
        // "JSON" is tagged OtherWord by NLTagger, so only the all-caps guard stops
        // this becoming "jSON".
        let out = TranscriptStitcher.stitch([
            r(0, "the export is broken."),
            r(1, "JSON parsing broke last night", silence: 0.7),
        ], repairSeams: true)
        XCTAssertEqual(out, "the export is broken. JSON parsing broke last night")
    }

    // MARK: - Kill switch

    func test_seamRepairCanBeDisabled() {
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship the feature."),
            r(1, "On Friday", silence: 0.7),
        ], repairSeams: false)
        XCTAssertEqual(out, "we should ship the feature. On Friday")
    }

    func test_duplicateRemovalIsAlsoDisabled() {
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship the feature"),
            r(1, "ship the feature on Friday"),
        ], repairSeams: false)
        XCTAssertEqual(out, "we should ship the feature ship the feature on Friday")
    }

    func test_disablingRepairStillOrdersCollapsesAndMarks() {
        let out = TranscriptStitcher.stitch([
            r(1, "  second   "),
            r(0, "first"),
            r(3, "\n fourth \n"),
            r(2, nil),
        ], repairSeams: false)
        XCTAssertEqual(out, "first second […] fourth")
    }

    // MARK: - Failures and empties

    func test_marksAFailedSegmentWithoutLosingTheRest() {
        let out = TranscriptStitcher.stitch([
            r(0, "first"), r(1, nil), r(2, "third"),
        ], repairSeams: true)
        XCTAssertEqual(out, "first […] third")
    }

    func test_marksAFailedLeadingSegment() {
        let out = TranscriptStitcher.stitch([
            r(0, nil), r(1, "second"),
        ], repairSeams: true)
        XCTAssertEqual(out, "[…] second")
    }

    func test_allFailedSegmentsProduceOnlyMarkers() {
        let out = TranscriptStitcher.stitch([
            r(0, nil), r(1, nil), r(2, nil),
        ], repairSeams: true)
        XCTAssertEqual(out, "[…] […] […]")
    }

    func test_doesNotRepairAcrossAFailedSegment() {
        // Content is missing, so we cannot claim the seam is mid-sentence.
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship the feature."),
            r(1, nil),
            r(2, "On Friday if the tests pass", silence: 0.7),
        ], repairSeams: true)
        XCTAssertEqual(out, "we should ship the feature. […] On Friday if the tests pass")
    }

    func test_emptySegmentsAreDroppedNotMarked() {
        XCTAssertEqual(
            TranscriptStitcher.stitch([r(0, "kept"), r(1, "   ")], repairSeams: true),
            "kept"
        )
    }

    func test_onlyEmptySegmentsProduceEmptyString() {
        XCTAssertEqual(
            TranscriptStitcher.stitch([r(0, ""), r(1, "  \n ")], repairSeams: true),
            ""
        )
    }

    func test_droppedEmptySegmentStillLetsNeighboursSeam() {
        let out = TranscriptStitcher.stitch([
            r(0, "we should ship the feature."),
            r(1, "   "),
            r(2, "On Friday if the tests pass", silence: 0.7),
        ], repairSeams: true)
        XCTAssertEqual(out, "we should ship the feature on Friday if the tests pass")
    }

    // MARK: - Whitespace

    func test_collapsesWhitespaceAndTrims() {
        let out = TranscriptStitcher.stitch([
            r(0, "  spaced   out  "),
            r(1, "\n text \n"),
        ], repairSeams: true)
        XCTAssertEqual(out, "spaced out text")
    }

    func test_collapsesWhitespaceWhenRepairIsOff() {
        let out = TranscriptStitcher.stitch([
            r(0, "  spaced   out  "),
            r(1, "\t\ttext\n\nhere"),
        ], repairSeams: false)
        XCTAssertEqual(out, "spaced out text here")
    }
}
