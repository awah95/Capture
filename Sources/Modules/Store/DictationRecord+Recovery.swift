import Foundation

/// What "this dictation still owes the user text" means, in one place.
///
/// Three separate agents reached for `finalText.contains(TranscriptStitcher.failureMarker)`
/// independently this session — the stats aggregator, the History screen and crash
/// recovery — and one of them (recovery) did not, which is how it came to silently skip
/// exactly the records that still had audio worth re-sending. A substring scan repeated
/// in three files is a rule nobody owns; here it is a rule with a name.
extension DictationRecord {

    /// A transcript with a hole in it: at least one segment failed permanently and
    /// `TranscriptStitcher` left a marker where its words should have been.
    ///
    /// This is a **weak signal by construction** — a user who literally dictates the
    /// marker text is a false positive. It is acceptable for deciding whether to offer a
    /// retry, and it is the reason the real fix belongs in the pipeline: a partial
    /// success should be written as its own outcome rather than inferred from prose.
    var isPartialTranscript: Bool {
        rawText.contains(TranscriptStitcher.failureMarker)
            || finalText.contains(TranscriptStitcher.failureMarker)
    }

    /// The insertion was refused because the caret was in a password field.
    ///
    /// Read from the logged string rather than the enum because that is what survives in
    /// the file; `InsertionOutcome` is deliberately not persisted as a case.
    var wasRefusedForSecureField: Bool {
        insertionOutcome == "refusedSecureField"
    }

    /// Whether re-running transcription could still put words in front of the user.
    ///
    /// The question is **"is text missing?"**, not "did something go wrong":
    ///
    /// - `.failed` with audio — yes. This is the case recovery was written for.
    /// - `.inserted` **with a marker** — yes, and this is the one that was being missed.
    ///   It is stored as a success because text really did reach the cursor; part of it
    ///   just never arrived.
    /// - `.cancelled` — no. Cancelling is a decision, not a failure. The audio is kept
    ///   (spec §4.1, so nothing spoken is ever lost) but re-transcribing it behind the
    ///   user's back is not recovery.
    /// - **A secure-field refusal — no**, even though it is `.failed` and has audio. Its
    ///   transcript already exists and is in History; nothing is missing. Re-running it
    ///   would try to insert password text again, somewhere the user has since moved to.
    ///   Re-insertion there is the user's call, from History.
    /// - No audio (purged by the retention sweep) — no. Offering a retry that cannot
    ///   work is worse than offering none.
    var isWorthRecovering: Bool {
        guard audioFileName != nil, !wasRefusedForSecureField else { return false }
        switch outcome {
        case .failed: return true
        case .inserted: return isPartialTranscript
        case .cancelled: return false
        }
    }
}
