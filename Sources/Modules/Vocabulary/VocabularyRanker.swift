import Foundation

/// A single custom-vocabulary entry: a name, piece of jargon, product name or
/// acronym the user wants spelled a specific way.
///
/// `useCount`, `lastUsed` and `appBundleIDs` are the ranking signals — they are
/// maintained by whoever records a dictation, not by the ranker, which is pure.
struct VocabularyTerm: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var text: String
    var soundsLike: String?
    var isPinned: Bool
    var useCount: Int
    var lastUsed: Date?
    /// Bundle IDs of the apps this term has previously been dictated into.
    var appBundleIDs: Set<String>
}

/// The subset of a vocabulary that fits inside Whisper's prompt budget, plus
/// enough accounting for the UI to explain the truncation ("38 of 112 terms fit
/// the current budget").
struct VocabularySelection: Equatable {
    /// The terms that fit, in the order they appear in `promptString`.
    let terms: [VocabularyTerm]
    /// Exactly what goes into Whisper's `prompt` parameter.
    let promptString: String
    let estimatedTokens: Int
    /// How many terms existed before truncation — the denominator in the UI.
    let totalTermCount: Int

    static let empty = VocabularySelection(
        terms: [], promptString: "", estimatedTokens: 0, totalTermCount: 0
    )
}

/// Ranks a vocabulary by relevance and truncates it to Whisper's prompt budget.
///
/// Groq caps the `prompt` parameter at 224 tokens, and a real vocabulary is far
/// larger than that, so the list can never simply be dumped. The ranker orders
/// terms by how likely they are to be needed *right now* and sends the longest
/// prefix of that ranking which fits — leaving room for the continuity tail that
/// non-first segments carry in the same parameter (`reservedTokens`).
///
/// Pure and deterministic: no clock, no I/O, no shared state. Identical input
/// always yields an identical prompt, because a prompt that flapped between
/// requests would make transcription non-reproducible.
enum VocabularyRanker {
    /// Groq's hard cap on the Whisper `prompt` parameter. Verified API limit.
    static let whisperPromptTokenBudget = 224

    /// Weight of a term used in the app currently being dictated into. Sized to
    /// dominate a frequency difference (log2 growth) without ever out-ranking a
    /// pin, which is a manual override.
    private static let appAffinityBonus = 5.0

    /// Recency is worth this much at the moment of use, halving every
    /// `recencyHalfLifeDays`.
    private static let recencyWeight = 10.0
    private static let recencyHalfLifeDays = 14.0

    private static let separator = ", "

    // MARK: - Selection

    static func select(
        from terms: [VocabularyTerm],
        targetBundleID: String?,
        now: Date,
        reservedTokens: Int
    ) -> VocabularySelection {
        let totalTermCount = terms.count

        // A term with no printable text can never be sent, but it still counts
        // toward the total the user sees — the denominator is what they stored.
        let candidates = terms.filter { !trimmed($0.text).isEmpty }

        // Clamp both ends: a caller reserving more than the budget must not
        // produce a negative allowance, and a negative reservation must not
        // inflate the budget past Groq's cap.
        let available = min(max(whisperPromptTokenBudget - reservedTokens, 0), whisperPromptTokenBudget)

        guard available > 0, !candidates.isEmpty else {
            return VocabularySelection(
                terms: [], promptString: "", estimatedTokens: 0, totalTermCount: totalTermCount
            )
        }

        let ranked = rank(candidates, targetBundleID: targetBundleID, now: now)

        var selected: [VocabularyTerm] = []
        var fragments: [String] = []
        var characterCount = 0

        for term in ranked {
            let fragment = promptFragment(for: term)
            let addition = fragments.isEmpty
                ? fragment.count
                : separator.count + fragment.count

            // Stop at the first term that does not fit rather than skipping it
            // and packing a shorter one behind it. The selection stays a prefix
            // of the ranking, so "38 of 112 fit" honestly means *the top 38*.
            guard estimatedTokens(forCharacterCount: characterCount + addition) <= available else {
                break
            }

            characterCount += addition
            fragments.append(fragment)
            selected.append(term)
        }

        let promptString = fragments.joined(separator: separator)
        return VocabularySelection(
            terms: selected,
            promptString: promptString,
            estimatedTokens: estimatedTokens(in: promptString),
            totalTermCount: totalTermCount
        )
    }

    // MARK: - Ranking

    static func rank(
        _ terms: [VocabularyTerm],
        targetBundleID: String?,
        now: Date
    ) -> [VocabularyTerm] {
        let scored = terms.map {
            (term: $0, score: score(for: $0, targetBundleID: targetBundleID, now: now))
        }
        return scored.sorted { lhs, rhs in
            // A pin is a manual override: it outranks every unpinned term
            // regardless of score.
            if lhs.term.isPinned != rhs.term.isPinned { return lhs.term.isPinned }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            // Deterministic tie-breaks, so the prompt never flaps between two
            // equally-scored terms.
            if lhs.term.text != rhs.term.text { return lhs.term.text < rhs.term.text }
            return lhs.term.id.uuidString < rhs.term.id.uuidString
        }
        .map(\.term)
    }

    /// `log2(useCount + 1)` + `10 * 0.5^(daysSinceUse / 14)` + `5` when the term
    /// has been dictated into the app being targeted now.
    ///
    /// Frequency grows logarithmically so a term used 500 times cannot bury the
    /// rest of the vocabulary; recency decays with a 14-day half-life, and a term
    /// never used contributes nothing from it.
    private static func score(
        for term: VocabularyTerm,
        targetBundleID: String?,
        now: Date
    ) -> Double {
        let frequencyScore = log2(Double(max(term.useCount, 0)) + 1)

        var recencyScore = 0.0
        if let lastUsed = term.lastUsed {
            // A clock skew that puts `lastUsed` in the future must not score
            // above a term used this instant.
            let days = max(now.timeIntervalSince(lastUsed) / 86_400, 0)
            recencyScore = recencyWeight * pow(0.5, days / recencyHalfLifeDays)
        }

        var affinityScore = 0.0
        if let targetBundleID, term.appBundleIDs.contains(targetBundleID) {
            affinityScore = appAffinityBonus
        }

        return frequencyScore + recencyScore + affinityScore
    }

    // MARK: - Prompt rendering

    /// A term renders as its text, or as `text (soundsLike)` when a pronunciation
    /// hint exists.
    ///
    /// Whisper's `prompt` is a *text prior*: the decoder is biased toward the
    /// strings it contains, so the canonical spelling has to lead — putting the
    /// phonetic form first would bias toward the misspelling we are trying to
    /// fix. The parenthetical places the acoustic hint immediately beside the
    /// spelling, which is how such glosses appear in natural text, and its cost
    /// is charged to the same budget as everything else.
    private static func promptFragment(for term: VocabularyTerm) -> String {
        let text = trimmed(term.text)
        guard let hint = term.soundsLike.map(trimmed), !hint.isEmpty else { return text }
        return "\(text) (\(hint))"
    }

    private static func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Token estimation

    /// Estimates Whisper tokens from characters:
    ///
    ///     tokens = ceil(ceil(characters / 4) * 1.15)
    ///
    /// English averages roughly 4 characters per token; the 15% margin on top is
    /// deliberate over-estimation. Sending a few terms fewer than strictly
    /// necessary is invisible to the user, while overshooting Groq's 224-token
    /// cap fails the request outright.
    static func estimatedTokens(in string: String) -> Int {
        estimatedTokens(forCharacterCount: string.count)
    }

    private static func estimatedTokens(forCharacterCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        let base = ceil(Double(count) / 4.0)
        return Int(ceil(base * 1.15))
    }
}
