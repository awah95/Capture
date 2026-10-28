import AppKit
import XCTest
@testable import Captur

@MainActor
final class InserterTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = .withUniqueName()
    }

    override func tearDown() {
        pasteboard.clearContents()
        pasteboard = nil
        super.tearDown()
    }

    private func makePublisher(ttl: TimeInterval = 3600) -> ClipboardPublisher {
        ClipboardPublisher(pasteboard: pasteboard, ttl: ttl)
    }

    func testPublishWritesMarkedItemAndPlainText() {
        let publisher = makePublisher()
        let captureID = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)

        _ = publisher.publish(
            "draft text",
            captureID: captureID,
            isFinal: false,
            now: now
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "draft text")
        XCTAssertNotNil(pasteboard.data(forType: ClipboardPublisher.markerType))
        XCTAssertTrue(pasteboard.types?.contains(ClipboardPublisher.plainTextType) == true)
        XCTAssertTrue(pasteboard.types?.contains(ClipboardPublisher.markerType) == true)
        XCTAssertEqual(
            publisher.currentMarker(),
            TranscriptMarker(
                captureID: captureID,
                timestamp: now,
                isFinal: false,
                expiresAt: now.addingTimeInterval(3600),
                text: "draft text"
            )
        )
    }

    func testFinalReplacesItsOwnDraft() {
        let publisher = makePublisher()
        let captureID = UUID()
        let receipt = publisher.publish("draft", captureID: captureID, isFinal: false)

        let updated = publisher.replaceDraftWithFinal(
            "final",
            captureID: captureID,
            expecting: receipt
        )

        XCTAssertNotNil(updated)
        XCTAssertEqual(publisher.currentMarker()?.text, "final")
        XCTAssertEqual(publisher.currentMarker()?.isFinal, true)
    }

    func testFinalDoesNotOverwriteUnrelatedClipboard() {
        let publisher = makePublisher()
        let captureID = UUID()
        let receipt = publisher.publish("draft", captureID: captureID, isFinal: false)

        pasteboard.clearContents()
        pasteboard.setString("something the user copied", forType: .string)

        let updated = publisher.replaceDraftWithFinal(
            "final",
            captureID: captureID,
            expecting: receipt
        )

        XCTAssertNil(updated)
        XCTAssertEqual(pasteboard.string(forType: .string), "something the user copied")
        XCTAssertNil(publisher.currentMarker())
    }

    func testFinalDoesNotReplaceDifferentCaptureMarker() {
        let publisher = makePublisher()
        let captureA = UUID()
        let captureB = UUID()
        _ = publisher.publish("draft B", captureID: captureB, isFinal: false)
        let forgedReceipt = ClipboardPublisher.Receipt(
            captureID: captureA,
            changeCount: pasteboard.changeCount
        )

        let updated = publisher.replaceDraftWithFinal(
            "final A",
            captureID: captureA,
            expecting: forgedReceipt
        )

        XCTAssertNil(updated)
        XCTAssertEqual(publisher.currentMarker()?.captureID, captureB)
        XCTAssertEqual(publisher.currentMarker()?.text, "draft B")
    }

    func testFinalDoesNotReplaceWithReceiptFromDifferentCapture() {
        let publisher = makePublisher()
        let captureID = UUID()
        _ = publisher.publish("draft", captureID: captureID, isFinal: false)
        let wrongReceipt = ClipboardPublisher.Receipt(
            captureID: UUID(),
            changeCount: pasteboard.changeCount
        )

        let updated = publisher.replaceDraftWithFinal(
            "final",
            captureID: captureID,
            expecting: wrongReceipt
        )

        XCTAssertNil(updated)
        XCTAssertEqual(publisher.currentMarker()?.text, "draft")
    }

    func testExpiredTranscriptIsNeitherReadableNorReplaceable() {
        let publisher = makePublisher()
        let captureID = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let receipt = publisher.publish(
            "draft",
            captureID: captureID,
            isFinal: false,
            now: now
        )
        let expired = now.addingTimeInterval(3601)

        XCTAssertNotNil(publisher.readableTranscript(now: now))
        XCTAssertNil(publisher.readableTranscript(now: expired))
        XCTAssertNil(
            publisher.replaceDraftWithFinal(
                "late final",
                captureID: captureID,
                expecting: receipt,
                now: expired
            )
        )
        XCTAssertEqual(publisher.currentMarker()?.text, "draft")
    }

    func testFinalMarkerCannotBeReplacedAgain() {
        let publisher = makePublisher()
        let captureID = UUID()
        let receipt = publisher.publish("final", captureID: captureID, isFinal: true)

        let updated = publisher.replaceDraftWithFinal(
            "different final",
            captureID: captureID,
            expecting: receipt
        )

        XCTAssertNil(updated)
        XCTAssertEqual(publisher.currentMarker()?.text, "final")
    }

    func testUnrelatedClipboardIsNotReadable() {
        let publisher = makePublisher()
        pasteboard.clearContents()
        pasteboard.setString("just some text", forType: .string)

        XCTAssertNil(publisher.readableTranscript())
    }

    func testFreshFinalPublishesWhenNoDraftExisted() {
        let publisher = makePublisher()
        let captureID = UUID()

        let receipt = publisher.publish(
            "final only",
            captureID: captureID,
            isFinal: true
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "final only")
        XCTAssertEqual(receipt.captureID, captureID)
        XCTAssertEqual(publisher.currentMarker()?.isFinal, true)
    }

    func testTemporaryPasteboardTextRestoresWhileStillOwned() {
        pasteboard.setString("before", forType: .string)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        let ownedChangeCount = pasteboard.changeCount

        XCTAssertTrue(
            restorePasteboardIfOwned(
                pasteboard,
                snapshot: snapshot,
                ownedChangeCount: ownedChangeCount
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "before")
    }

    func testTemporaryPasteboardTextDoesNotOverwriteNewUserCopy() {
        pasteboard.setString("before", forType: .string)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        let ownedChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)

        XCTAssertFalse(
            restorePasteboardIfOwned(
                pasteboard,
                snapshot: snapshot,
                ownedChangeCount: ownedChangeCount
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testFullPasteboardSnapshotRestoresMultipleTypesByteIdentical() {
        let customType = NSPasteboard.PasteboardType("com.quickcapture.tests.custom")
        let customData = Data([0x01, 0x02, 0x03, 0xFF, 0x00])
        let tiffLikeData = Data([0x4D, 0x4D, 0x00, 0x2A, 0x01, 0x02, 0x03])

        let item = NSPasteboardItem()
        item.setData(customData, forType: customType)
        item.setData(tiffLikeData, forType: .tiff)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        let ownedChangeCount = pasteboard.changeCount

        XCTAssertTrue(
            restorePasteboardIfOwned(
                pasteboard,
                snapshot: snapshot,
                ownedChangeCount: ownedChangeCount
            )
        )

        XCTAssertTrue(pasteboard.types?.contains(customType) == true)
        XCTAssertTrue(pasteboard.types?.contains(.tiff) == true)
        XCTAssertEqual(pasteboard.data(forType: customType), customData)
        XCTAssertEqual(pasteboard.data(forType: .tiff), tiffLikeData)
    }

    func testEmptyPriorClipboardRestoresToEmpty() {
        pasteboard.clearContents()
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.setString("transcript", forType: .string)
        let ownedChangeCount = pasteboard.changeCount

        XCTAssertTrue(
            restorePasteboardIfOwned(
                pasteboard,
                snapshot: snapshot,
                ownedChangeCount: ownedChangeCount
            )
        )

        XCTAssertEqual(pasteboard.pasteboardItems?.count ?? 0, 0)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testFullPasteboardSnapshotOwnershipGuardPreventsRestore() {
        let customType = NSPasteboard.PasteboardType("com.quickcapture.tests.custom-guard")
        let customData = Data([0x10, 0x20, 0x30])

        let item = NSPasteboardItem()
        item.setData(customData, forType: customType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        let ownedChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)

        XCTAssertFalse(
            restorePasteboardIfOwned(
                pasteboard,
                snapshot: snapshot,
                ownedChangeCount: ownedChangeCount
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
        XCTAssertNil(pasteboard.data(forType: customType))
    }

    /// Spec §8/§17: nothing inserted **or copied**. A clipboard fallback would satisfy
    /// the first half and break the second.
    func testSecureFieldIsRefusedRatherThanCopiedToTheClipboard() {
        XCTAssertEqual(
            planInsertion(
                axTrusted: true,
                focusedElementKind: .secure,
                axWrite: .notAttempted,
                cgEventAvailable: true
            ),
            .refusedSecureField
        )
        XCTAssertEqual(
            planInsertion(
                axTrusted: true,
                focusedElementKind: .secure,
                axWrite: .confirmed,
                cgEventAvailable: false
            ),
            .refusedSecureField
        )
    }

    /// The regression this pins, found on real hardware.
    ///
    /// A dictation into Chrome was recorded as `insertedDirect` with 8 ms of insert
    /// time, and no text appeared anywhere — not at the caret, not on the clipboard.
    /// `AXUIElementSetAttributeValue` had returned `.success`, which means the message
    /// was accepted, not that the document changed; Chrome and most web text fields
    /// accept it and do nothing. Because "accepted" was read as "inserted", the paste
    /// and clipboard rungs below it could never be reached and the transcript existed
    /// nowhere. An unconfirmed write must fall through.
    func testAnAcceptedButUnconfirmedAccessibilityWriteFallsThroughToPaste() {
        XCTAssertEqual(
            planInsertion(
                axTrusted: true,
                focusedElementKind: .text,
                axWrite: .accepted,
                cgEventAvailable: true
            ),
            .pastedViaKeyboard,
            "An AX write nothing can verify is not an insertion"
        )
    }

    /// …and with no paste available it must still reach the clipboard, never claim success.
    func testAnAcceptedButUnconfirmedWriteWithNoPasteStillReachesTheClipboard() {
        guard case .clipboardFallback = planInsertion(
            axTrusted: true,
            focusedElementKind: .text,
            axWrite: .accepted,
            cgEventAvailable: false
        ) else {
            return XCTFail("An unconfirmable write with no paste path must leave the text somewhere")
        }
    }

    func testSuccessfulAccessibilitySetWinsWithoutCGEvents() {
        XCTAssertEqual(
            planInsertion(
                axTrusted: true,
                focusedElementKind: .text,
                axWrite: .confirmed,
                cgEventAvailable: false
            ),
            .insertedDirect
        )
    }

    func testFailedAccessibilitySetUsesKeyboardPaste() {
        for result: AXWriteResult in [.refused, .accepted, .notAttempted] {
            XCTAssertEqual(
                planInsertion(
                    axTrusted: true,
                    focusedElementKind: .text,
                    axWrite: result,
                    cgEventAvailable: true
                ),
                .pastedViaKeyboard
            )
        }
    }

    func testNoFocusedElementUsesKeyboardPaste() {
        XCTAssertEqual(
            planInsertion(
                axTrusted: true,
                focusedElementKind: .none,
                axWrite: .notAttempted,
                cgEventAvailable: true
            ),
            .pastedViaKeyboard
        )
    }

    func testUntrustedProcessUsesKeyboardPaste() {
        XCTAssertEqual(
            planInsertion(
                axTrusted: false,
                focusedElementKind: .none,
                axWrite: .notAttempted,
                cgEventAvailable: true
            ),
            .pastedViaKeyboard
        )
    }

    func testMissingCGEventsUsesMarkedClipboardFallback() {
        let failedAXPlans = [
            planInsertion(
                axTrusted: true,
                focusedElementKind: .text,
                axWrite: .refused,
                cgEventAvailable: false
            ),
            planInsertion(
                axTrusted: true,
                focusedElementKind: .none,
                axWrite: .notAttempted,
                cgEventAvailable: false
            ),
            planInsertion(
                axTrusted: false,
                focusedElementKind: .none,
                axWrite: .notAttempted,
                cgEventAvailable: false
            )
        ]

        XCTAssertEqual(
            failedAXPlans,
            Array(
                repeating: .clipboardFallback(reason: "keyboard paste unavailable"),
                count: 3
            )
        )
    }

    // MARK: Secure-field detection — unavailable is not the same answer as negative

    func testASecureSubroleIsTheSecureField() {
        XCTAssertEqual(
            classifyFocusedElement(
                role: kAXTextFieldRole as String,
                subrole: kAXSecureTextFieldSubrole as String
            ),
            .secure
        )
    }

    /// An ordinary AppKit text field exposes no subrole at all, so a missing subrole can
    /// never mean secure — reading it that way would refuse every plain text field.
    func testAMissingSubroleOnARealRoleIsAnOrdinaryTextField() {
        XCTAssertEqual(
            classifyFocusedElement(role: kAXTextFieldRole as String, subrole: nil),
            .text
        )
        XCTAssertEqual(
            classifyFocusedElement(role: kAXTextAreaRole as String, subrole: nil),
            .text
        )
    }

    /// The decision the prompt asks to be explicit about: an element that answers
    /// nothing is recorded as `unknownRole` and then treated as *not* secure, because
    /// refusing here means nothing inserted and nothing copied in every app that does
    /// not speak accessibility — the exact failure the ladder exists to prevent — while
    /// every real secure field on this platform does advertise its subrole.
    func testAnElementThatAnswersNothingIsUnknownAndNotTreatedAsSecure() {
        XCTAssertEqual(classifyFocusedElement(role: nil, subrole: nil), .unknownRole)

        XCTAssertEqual(
            planInsertion(
                axTrusted: true,
                focusedElementKind: .unknownRole,
                axWrite: .notAttempted,
                cgEventAvailable: true
            ),
            .pastedViaKeyboard
        )
    }

    /// A confirmed write into an unknown-role element is an insertion: the value came
    /// back changed, and a secure field never hands back its plaintext to compare.
    func testAConfirmedWriteIntoAnUnknownRoleElementCounts() {
        XCTAssertEqual(
            planInsertion(
                axTrusted: true,
                focusedElementKind: .unknownRole,
                axWrite: .confirmed,
                cgEventAvailable: false
            ),
            .insertedDirect
        )
    }

    // MARK: The preceding-character read, which is allowed to lie

    func testPrecedingCharacterIsNilAtTheStartOfAField() {
        XCTAssertNil(AXFocus.precedingCharacter(caretLocation: 0, characterBeforeCaret: "x"))
    }

    func testPrecedingCharacterIsNilWhenTheCaretCannotBeRead() {
        XCTAssertNil(AXFocus.precedingCharacter(caretLocation: nil, characterBeforeCaret: "x"))
    }

    /// The failure mode this guards is not a crash. An app that answers "success" with
    /// the wrong string would silently rewrite what the user said, so anything that is
    /// not exactly one grapheme is treated as no answer at all.
    func testPrecedingCharacterIsNilForEveryDoubtfulAnswer() {
        XCTAssertNil(AXFocus.precedingCharacter(caretLocation: 5, characterBeforeCaret: nil))
        XCTAssertNil(AXFocus.precedingCharacter(caretLocation: 5, characterBeforeCaret: ""))
        XCTAssertNil(AXFocus.precedingCharacter(caretLocation: 5, characterBeforeCaret: "the whole line"))
        XCTAssertNil(AXFocus.precedingCharacter(caretLocation: 5, characterBeforeCaret: "ab"))
    }

    func testPrecedingCharacterAcceptsOneGrapheme() {
        XCTAssertEqual(AXFocus.precedingCharacter(caretLocation: 5, characterBeforeCaret: "d"), "d")
        XCTAssertEqual(AXFocus.precedingCharacter(caretLocation: 5, characterBeforeCaret: " "), " ")
        XCTAssertEqual(AXFocus.precedingCharacter(caretLocation: 5, characterBeforeCaret: "🙂"), "🙂")
        XCTAssertEqual(AXFocus.precedingCharacter(caretLocation: 5, characterBeforeCaret: "\r\n"), "\r\n")
    }

    // MARK: The ladder end to end, behind the seam

    /// The claim that is not about insertion at all: on the refusal path the pasteboard
    /// is not merely "not published to", it is byte-for-byte what the user left there.
    func testSecureFieldRefusalTouchesNeitherTheFieldNorTheClipboard() async {
        pasteboard.clearContents()
        pasteboard.setString("something the user copied", forType: .string)
        let changeCountBefore = pasteboard.changeCount

        let target = FakeInsertionTarget(kind: .secure, precedingCharacter: "d")
        let paste = PasteRecorder()
        let inserter = Inserter(
            pasteboard: pasteboard,
            environment: environment(target: target, paste: paste)
        )

        let outcome = await inserter.insert("And then we shipped")

        XCTAssertEqual(outcome, .refusedSecureField)
        XCTAssertEqual(pasteboard.string(forType: .string), "something the user copied")
        XCTAssertEqual(pasteboard.changeCount, changeCountBefore, "the clipboard was written")
        XCTAssertTrue(target.writtenTexts.isEmpty, "a secure field was written to")
        XCTAssertEqual(paste.postCount, 0, "⌘V was posted at a password field")
    }

    /// A secure field is never asked what is in it either — reading the character before
    /// the caret there is reading the password.
    func testASecureFieldIsNeverReadForContext() async {
        let target = FakeInsertionTarget(kind: .secure, precedingCharacter: "d")
        let inserter = Inserter(
            pasteboard: pasteboard,
            environment: environment(target: target, paste: PasteRecorder())
        )

        _ = await inserter.insert("And then we shipped")

        XCTAssertEqual(target.precedingCharacterReads, 0)
    }

    /// Smart capitalization and spacing reach the text that is actually inserted, not
    /// just the pure function's return value.
    func testTheTextWrittenCarriesTheCapitalizationAndSpacingDecision() async {
        let target = FakeInsertionTarget(
            kind: .text,
            precedingCharacter: "d",
            value: "we tried",
            writeResult: .confirmed
        )
        let inserter = Inserter(
            pasteboard: pasteboard,
            environment: environment(target: target, paste: PasteRecorder())
        )

        let outcome = await inserter.insert("And then we shipped")

        XCTAssertEqual(outcome, .insertedDirect)
        XCTAssertEqual(target.writtenTexts, [" and then we shipped"])
    }

    func testPinnedTermsReachTheInsertedText() async {
        let target = FakeInsertionTarget(
            kind: .text,
            precedingCharacter: "d",
            value: "we tried",
            writeResult: .confirmed
        )
        let inserter = Inserter(
            pasteboard: pasteboard,
            environment: environment(
                target: target,
                paste: PasteRecorder(),
                pinnedTerms: ["Captur"]
            )
        )

        _ = await inserter.insert("Captur is ready")

        XCTAssertEqual(target.writtenTexts, [" Captur is ready"])
    }

    /// A direct insertion leaves the clipboard alone — the whole point of the first rung.
    func testAConfirmedDirectInsertionDoesNotTouchTheClipboard() async {
        pasteboard.clearContents()
        pasteboard.setString("user copy", forType: .string)
        let changeCountBefore = pasteboard.changeCount

        let target = FakeInsertionTarget(kind: .text, value: "", writeResult: .confirmed)
        let inserter = Inserter(
            pasteboard: pasteboard,
            environment: environment(target: target, paste: PasteRecorder())
        )

        let outcome = await inserter.insert("hello")

        XCTAssertEqual(outcome, .insertedDirect)
        XCTAssertEqual(pasteboard.changeCount, changeCountBefore)
    }

    /// The Chrome regression, now executed rather than reasoned about: an `accepted` but
    /// unconfirmed write must actually post ⌘V, and the clipboard must be put back after
    /// the paste is confirmed.
    func testAnUnconfirmedWriteFallsThroughToAPasteThatRestoresTheClipboard() async {
        pasteboard.clearContents()
        pasteboard.setString("user copy", forType: .string)

        let target = FakeInsertionTarget(kind: .text, value: "before", writeResult: .accepted)
        let paste = PasteRecorder { target.value = "before and then" }
        let inserter = Inserter(
            pasteboard: pasteboard,
            environment: environment(target: target, paste: paste)
        )

        let outcome = await inserter.insert("and then")

        XCTAssertEqual(outcome, .pastedViaKeyboard)
        XCTAssertEqual(paste.postCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "user copy")
    }

    /// …and when the paste cannot be confirmed the transcript deliberately stays on the
    /// clipboard. A replaced clipboard is a nuisance; a dictation that exists nowhere is
    /// the failure this ladder was rebuilt to prevent.
    func testAnUnconfirmablePasteLeavesTheTranscriptOnTheClipboard() async {
        pasteboard.clearContents()
        pasteboard.setString("user copy", forType: .string)

        // The element accepts everything and never changes: the Chrome shape exactly.
        let target = FakeInsertionTarget(kind: .text, value: "unchanged", writeResult: .accepted)
        let inserter = Inserter(
            pasteboard: pasteboard,
            environment: environment(target: target, paste: PasteRecorder())
        )

        let outcome = await inserter.insert("and then")

        guard case .clipboardFallback = outcome else {
            return XCTFail("an unconfirmable paste must not report success: \(outcome)")
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "and then")
    }

    /// The paste rung re-reads focus, because the user may have moved on while the
    /// transcript was in flight.
    func testThePasteRungReReadsFocus() async {
        let target = FakeInsertionTarget(kind: .text, value: "before", writeResult: .accepted)
        let paste = PasteRecorder { target.value = "before and then" }
        var focusReads = 0
        var environment = self.environment(target: target, paste: paste)
        environment.focusedTarget = {
            focusReads += 1
            return target
        }

        _ = await Inserter(pasteboard: pasteboard, environment: environment).insert("and then")

        XCTAssertEqual(focusReads, 2, "focus must be read again before ⌘V is posted")
    }

    /// The race the re-read exists to catch: the caret is in a password box by the time
    /// the paste would fire. The transcript is on the clipboard by then, so this refusal
    /// has to clean up after itself.
    func testACaretThatMovedIntoASecureFieldMidFlightIsRefusedAndTheClipboardRestored() async {
        pasteboard.clearContents()
        pasteboard.setString("user copy", forType: .string)

        let firstTarget = FakeInsertionTarget(kind: .text, value: "before", writeResult: .accepted)
        let secureTarget = FakeInsertionTarget(kind: .secure, value: nil)
        let paste = PasteRecorder()
        var targets: [FakeInsertionTarget] = [firstTarget, secureTarget]
        var environment = self.environment(target: firstTarget, paste: paste)
        environment.focusedTarget = { targets.isEmpty ? nil : targets.removeFirst() }

        let outcome = await Inserter(pasteboard: pasteboard, environment: environment)
            .insert("and then")

        XCTAssertEqual(outcome, .refusedSecureField)
        XCTAssertEqual(paste.postCount, 0, "⌘V was posted into a password field")
        XCTAssertEqual(pasteboard.string(forType: .string), "user copy")
    }

    // MARK: Seams

    /// Stands in for the focused element. Nothing here touches the AX tree, the real
    /// clipboard, or any other running app — the ladder cannot be exercised for real
    /// without typing into whatever the owner happens to have open.
    func testUnchangedSelectionEditNeverTouchesEditorOrClipboard() async {
        let target = FakeInsertionTarget(kind: .text, value: "Original", writeResult: .confirmed)
        let paste = PasteRecorder()
        pasteboard.setString("Previous clipboard", forType: .string)
        var env = environment(target: target, paste: paste)
        env.selectionContext = { _ in XCTFail("No context read needed for a no-op"); return Task { .empty } }
        let inserter = Inserter(pasteboard: pasteboard, environment: env)
        _ = await inserter.insertSelectionEdit("Original", originalSelection: "Original", targetBundleID: "test")
        XCTAssertTrue(target.writtenTexts.isEmpty)
        XCTAssertEqual(paste.postCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Previous clipboard")
    }

    func testSelectionEditPreservesCapitalizationAndChecksOriginalSelection() async {
        let target = FakeInsertionTarget(kind: .text, precedingCharacter: "a", value: "before", writeResult: .confirmed)
        var env = environment(target: target, paste: PasteRecorder())
        env.selectionContext = { _ in Task { ContextSnapshot(selectedText: "Original") } }
        let inserter = Inserter(pasteboard: pasteboard, environment: env)
        let outcome = await inserter.insertSelectionEdit("UPPERCASE", originalSelection: "Original", targetBundleID: "test")
        XCTAssertEqual(outcome, .insertedDirect)
        XCTAssertEqual(target.writtenTexts, ["UPPERCASE"])
    }

    func testChangedSelectionPublishesResultWithoutWritingToEditor() async {
        let target = FakeInsertionTarget(kind: .text, value: "before", writeResult: .confirmed)
        var env = environment(target: target, paste: PasteRecorder())
        env.selectionContext = { _ in Task { ContextSnapshot(selectedText: "Different") } }
        let inserter = Inserter(pasteboard: pasteboard, environment: env)
        let outcome = await inserter.insertSelectionEdit("Edited", originalSelection: "Original", targetBundleID: "test")
        if case .clipboardFallback = outcome {} else { XCTFail("Expected clipboard fallback") }
        XCTAssertTrue(target.writtenTexts.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "Edited")
    }

    func testSelectionEditInProtectedFieldDoesNotWriteOrPublish() async {
        let target = FakeInsertionTarget(kind: .secure)
        var env = environment(target: target, paste: PasteRecorder())
        env.selectionContext = { _ in Task { ContextSnapshot(protectedField: true) } }
        let inserter = Inserter(pasteboard: pasteboard, environment: env)
        let outcome = await inserter.insertSelectionEdit("Edited", originalSelection: "Original", targetBundleID: "test")
        XCTAssertEqual(outcome, .refusedSecureField)
        XCTAssertTrue(target.writtenTexts.isEmpty)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    private final class FakeInsertionTarget: InsertionTarget {
        let kind: FocusedElementKind
        var value: String?
        var writeResult: AXWriteResult
        var writtenTexts: [String] = []
        var precedingCharacterReads = 0

        private let preceding: Character?

        init(
            kind: FocusedElementKind,
            precedingCharacter: Character? = nil,
            value: String? = "",
            writeResult: AXWriteResult = .refused
        ) {
            self.kind = kind
            preceding = precedingCharacter
            self.value = value
            self.writeResult = writeResult
        }

        func precedingCharacter() -> Character? {
            precedingCharacterReads += 1
            return preceding
        }

        func write(_ text: String) -> AXWriteResult {
            writtenTexts.append(text)
            return writeResult
        }

        func textValue() -> String? { value }
    }

    /// Stands in for ⌘V. `onPost` is where a test says what a landed paste looks like.
    private final class PasteRecorder {
        private(set) var postCount = 0
        private let onPost: () -> Void

        init(onPost: @escaping () -> Void = {}) {
            self.onPost = onPost
        }

        func post() {
            postCount += 1
            onPost()
        }
    }

    private func environment(
        target: FakeInsertionTarget,
        paste: PasteRecorder,
        pinnedTerms: Set<String> = []
    ) -> Inserter.Environment {
        Inserter.Environment(
            accessibilityTrusted: { true },
            focusedTarget: { target },
            pinnedTerms: { pinnedTerms },
            makePaste: { { paste.post() } },
            pasteSettleDelay: {}
        )
    }
}
