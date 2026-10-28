import Foundation
import NaturalLanguage

/// One segment's transcription outcome. Segments are cut at silence boundaries and
/// transcribed concurrently, so these arrive in arbitrary order and are reassembled
/// by `index`, never by arrival.
struct SegmentResult: Equatable, Sendable {
    let index: Int
    /// `nil` means this segment permanently failed to transcribe. Empty or
    /// whitespace-only means it simply held no speech.
    let text: String?
    /// Silence observed at the START of this segment — the length of the pause that
    /// caused the cut before it. Short pauses mean the sentence was still running.
    let precedingSilence: TimeInterval
    /// Transport/model attempts made for this segment. Local engines normally make
    /// one; Groq may make up to three when a retryable request fails.
    let attemptCount: Int

    init(index: Int,
         text: String?,
         precedingSilence: TimeInterval,
         attemptCount: Int = 1) {
        self.index = index
        self.text = text
        self.precedingSilence = precedingSilence
        self.attemptCount = max(0, attemptCount)
    }
}

/// Reassembles concurrently-transcribed segments into one clean transcript.
///
/// Two artefacts of the segmented pipeline are repaired at each seam:
///
/// 1. **Duplicated words.** Each segment after the first is sent to Whisper with the
///    tail of the previous one as its `prompt`, which gives continuity across the cut
///    but makes Whisper occasionally re-emit part of that prompt. The longest 1–4 word
///    overlap is dropped from the incoming segment.
/// 2. **Mid-sentence punctuation.** Cuts fire after ~600 ms of silence, and people pause
///    that long mid-sentence constantly. Each segment is punctuated independently, so
///    Whisper closes segment N with a full stop and capitalises segment N+1. When the
///    pause was short, the stop is removed and the next word lowercased — unless that
///    word is a name, which must survive intact.
enum TranscriptStitcher {

    /// Stands in for a segment that permanently failed, so the gap is visible instead
    /// of silently swallowing the rest of the transcript.
    static let failureMarker = "[…]"

    /// Whisper re-emits at most a few prompt words, and a wider window starts matching
    /// ordinary repeated phrases ("we should ... we should").
    private static let maxOverlapWords = 4

    /// A pause at or above this is treated as a genuine sentence break, so its
    /// punctuation is Whisper being right rather than Whisper being cut off.
    private static let sentenceBreakSilence: TimeInterval = 1.5

    /// - Parameter repairSeams: user-facing kill switch. When false, segments are only
    ///   ordered, whitespace-normalised and joined — no text is altered or removed.
    static func stitch(_ results: [SegmentResult], repairSeams: Bool) -> String {
        var accumulated = ""
        // Repairs need a real, complete predecessor; a failure marker is neither.
        var canRepairAgainstTail = false

        for result in results.sorted(by: { $0.index < $1.index }) {
            guard let rawText = result.text else {
                accumulated = appending(failureMarker, to: accumulated)
                canRepairAgainstTail = false
                continue
            }

            let collapsed = collapsingWhitespace(rawText)
            if collapsed.isEmpty { continue }        // silence, not a failure — drop it

            var incoming = collapsed
            if repairSeams, canRepairAgainstTail, !accumulated.isEmpty {
                incoming = removingDuplicatedOverlap(with: accumulated, from: incoming)
                if incoming.isEmpty { continue }     // the whole segment was an echo

                if result.precedingSilence < sentenceBreakSilence,
                   let repaired = repairingSentenceBreak(tail: accumulated, head: incoming) {
                    accumulated = repaired.tail
                    incoming = repaired.head
                }
            }

            accumulated = appending(incoming, to: accumulated)
            canRepairAgainstTail = true
        }

        return accumulated
    }

    // MARK: - Joining

    private static func appending(_ piece: String, to text: String) -> String {
        text.isEmpty ? piece : text + " " + piece
    }

    /// Every run of whitespace — including newlines Whisper inserts around sentences —
    /// becomes a single space, and the ends are trimmed.
    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Duplicate seam words

    /// Drops the longest 1–4 word run that ends `tail` and begins `head`, comparing
    /// case-insensitively and ignoring punctuation.
    private static func removingDuplicatedOverlap(with tail: String, from head: String) -> String {
        let tailWords = tail.split(separator: " ").map(String.init)
        let headWords = head.split(separator: " ").map(String.init)
        let widest = min(maxOverlapWords, tailWords.count, headWords.count)
        guard widest >= 1 else { return head }

        for length in stride(from: widest, through: 1, by: -1) {
            let tailKeys = tailWords.suffix(length).map(comparisonKey)
            // A run of pure punctuation normalises to nothing and must not "match".
            if tailKeys.contains(where: { $0.isEmpty }) { continue }
            let headKeys = headWords.prefix(length).map(comparisonKey)
            if tailKeys == headKeys {
                return headWords.dropFirst(length).joined(separator: " ")
            }
        }
        return head
    }

    /// Letters and digits only, lowercased — so "Feature," and "feature" are one word.
    private static func comparisonKey(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Mid-sentence punctuation

    /// Returns the corrected pair when the seam looks like a sentence cut in half,
    /// or `nil` when the punctuation should be left exactly as Whisper wrote it.
    private static func repairingSentenceBreak(
        tail: String,
        head: String
    ) -> (tail: String, head: String)? {
        guard endsMidSentence(tail) else { return nil }
        guard let firstWord = head.split(separator: " ").first.map(String.init) else { return nil }
        guard startsWithRepairableCapital(firstWord), !isProperName(head) else { return nil }

        var repairedTail = tail
        if repairedTail.hasSuffix(".") { repairedTail.removeLast() }
        let repairedHead = head.prefix(1).lowercased() + head.dropFirst()
        return (repairedTail, repairedHead)
    }

    /// "?" and "!" are deliberate — Whisper does not emit them by accident mid-clause
    /// the way it emits a full stop — and an ellipsis is a trailing-off, not a cut.
    private static func endsMidSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        if last == "?" || last == "!" || last == "…" { return false }
        if text.hasSuffix("..") { return false }
        return true
    }

    /// A capital that can safely be pushed down: not the pronoun "I", not an acronym.
    private static func startsWithRepairableCapital(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I\u{2019}") { return false }
        let letters = word.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return false }   // API, NDA
        return true
    }

    /// Whether the first word of `text` is a personal, place or organisation name.
    ///
    /// The tagger is given the whole segment because it needs surrounding words to
    /// resolve a name — in isolation even "Sarah" comes back as `.other`. Anything
    /// other than a confident `.otherWord` is treated as a name: wrongly *keeping* a
    /// capital is a cosmetic blemish, wrongly destroying someone's name is not.
    private static func isProperName(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .word, scheme: .nameType)
        switch tag {
        case .some(.otherWord): return false
        default: return true
        }
    }
}
