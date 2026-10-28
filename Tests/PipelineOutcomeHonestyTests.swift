import XCTest
@testable import Captur

/// Two holes that three separate agents found from three different directions this
/// session, both of the same shape: **the record says a dictation succeeded when it
/// did not.**
///
/// 1. A secure field is refused — nothing inserted, nothing copied — and
///    `DictationRecordDraft.applyTranscript` still stamped `outcome = .inserted`, so
///    the capsule reported success and the stats counted words that reached nobody.
/// 2. A capture whose segment permanently failed is stored `.inserted` carrying
///    `TranscriptStitcher.failureMarker`, and `recoverUnfinished()` filters on
///    `case .failed` — so crash recovery silently skipped exactly the records that
///    still had audio worth re-sending.
///
/// The governing rule for this project is *never lose what was said, and always say
/// what happened*. Both of these broke the second half of it.
final class PipelineOutcomeHonestyTests: XCTestCase {

    // MARK: - A refused secure field is not an insertion

    func testARefusedSecureFieldIsRecordedAsFailedNotInserted() {
        var record = Self.blankRecord()

        DictationRecordDraft.applyTranscript(
            to: &record,
            rawText: "my password is hunter2",
            finalText: "my password is hunter2",
            insertionOutcome: .refusedSecureField,
            whisperSeconds: 0.2,
            insertSeconds: 0.01,
            totalSeconds: 1.0)

        guard case .failed(let reason) = record.outcome else {
            return XCTFail("a refusal is not an insertion; got \(record.outcome)")
        }
        XCTAssertTrue(reason.lowercased().contains("secure"),
                      "the reason must say why, not just that it failed: \(reason)")
    }

    func testARefusedSecureFieldStillKeepsTheTranscriptForHistory() {
        // Spec §17: "Nothing inserted or copied; text available in History." Refusing
        // to insert must not also throw the words away — that would be the one failure
        // mode worse than inserting them in the wrong place.
        var record = Self.blankRecord()

        DictationRecordDraft.applyTranscript(
            to: &record,
            rawText: "this must not appear",
            finalText: "this must not appear",
            insertionOutcome: .refusedSecureField,
            whisperSeconds: 0.2,
            insertSeconds: 0.01,
            totalSeconds: 1.0)

        XCTAssertEqual(record.finalText, "this must not appear")
        XCTAssertEqual(record.wordCount, 4)
        XCTAssertEqual(record.insertionOutcome, "refusedSecureField")
    }

    func testEveryOtherOutcomeIsStillRecordedAsInserted() {
        for outcome in [InsertionOutcome.insertedDirect,
                        .pastedViaKeyboard,
                        .clipboardFallback(reason: "no accessibility permission")] {
            var record = Self.blankRecord()
            DictationRecordDraft.applyTranscript(
                to: &record,
                rawText: "hello",
                finalText: "hello",
                insertionOutcome: outcome,
                whisperSeconds: 0.1,
                insertSeconds: 0.01,
                totalSeconds: 0.5)
            XCTAssertEqual(record.outcome, .inserted,
                           "\(outcome) reached the user one way or another")
        }
    }

    // MARK: - A partial transcript is retryable

    func testAPartialTranscriptIsRecognizedAsPartial() {
        var record = Self.blankRecord()
        record.finalText = "the first part \(TranscriptStitcher.failureMarker) the third part"
        XCTAssertTrue(record.isPartialTranscript)
    }

    func testAnOrdinaryTranscriptIsNotPartial() {
        var record = Self.blankRecord()
        record.finalText = "nothing was lost here"
        XCTAssertFalse(record.isPartialTranscript)
    }

    func testAPartialTranscriptIsWorthRecoveringEvenThoughItSaysInserted() {
        // The bug: `.inserted` + a marker is how a partial failure is stored, and
        // recovery only looked at `case .failed`.
        var record = Self.blankRecord()
        record.outcome = .inserted
        record.finalText = "half of it \(TranscriptStitcher.failureMarker)"
        record.audioFileName = "session.flac"

        XCTAssertTrue(record.isWorthRecovering)
    }

    func testAFailedRecordIsWorthRecovering() {
        var record = Self.blankRecord()
        record.outcome = .failed(reason: DictationPipeline.transcriptionFailedMessage)
        record.audioFileName = "session.flac"
        XCTAssertTrue(record.isWorthRecovering)
    }

    func testACleanInsertionIsNotWorthRecovering() {
        var record = Self.blankRecord()
        record.outcome = .inserted
        record.finalText = "all of it arrived"
        record.audioFileName = "session.flac"
        XCTAssertFalse(record.isWorthRecovering)
    }

    func testARecordWithNoAudioIsNeverWorthRecovering() {
        // The retention sweep purged the audio; there is nothing left to re-send, and
        // offering a retry that cannot work is worse than offering none.
        var record = Self.blankRecord()
        record.outcome = .failed(reason: "whatever")
        record.audioFileName = nil
        XCTAssertFalse(record.isWorthRecovering)
    }

    func testACancelledRecordIsNotWorthRecovering() {
        // Cancelling is a decision, not a failure. Spec §4.1 keeps the audio so nothing
        // spoken is lost, but re-transcribing it behind the user's back is not recovery.
        var record = Self.blankRecord()
        record.outcome = .cancelled
        record.audioFileName = "session.flac"
        XCTAssertFalse(record.isWorthRecovering)
    }

    func testARefusedSecureFieldIsNotAutomaticallyRecovered() {
        // It is `.failed` and it has audio, so the naive rule would re-run it — and a
        // retry would try to insert the password text again, possibly somewhere else.
        // Re-insertion here is the user's call, from History.
        var record = Self.blankRecord()
        DictationRecordDraft.applyTranscript(
            to: &record,
            rawText: "secret",
            finalText: "secret",
            insertionOutcome: .refusedSecureField,
            whisperSeconds: 0.1,
            insertSeconds: 0.01,
            totalSeconds: 0.4)
        record.audioFileName = "session.flac"

        XCTAssertFalse(record.isWorthRecovering,
                       "a refusal already has its transcript; recovery is for missing text")
    }

    // MARK: - Helper

    private static func blankRecord() -> DictationRecord {
        DictationRecord(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            speakingDuration: 3,
            rawText: "",
            finalText: "",
            modeID: Mode.verbatim.id,
            targetBundleID: nil,
            targetAppName: nil,
            wordCount: 0,
            rawWordCount: 0,
            segmentCount: 1,
            timings: Timings(captureMs: 3_000, convertMs: 0, uploadMs: 0, whisperMs: 0,
                             llmMs: 0, insertMs: 0, totalMs: 0),
            insertionOutcome: "",
            retryCount: 0,
            editDistanceRawToFinal: 0,
            audioFileName: nil,
            audioBytes: 0,
            estimatedCostUSD: 0,
            vocabularyTermsSent: 0,
            voiceProcessingActive: true,
            outcome: .inserted)
    }
}
