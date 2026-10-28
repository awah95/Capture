import Foundation

/// Derives optional, *non-destructive* views of a Thought's verbatim transcript:
/// a cleaned rendering and a short title. The verbatim text is always the
/// authoritative source — this type never mutates or replaces it, it only
/// produces derived data the caller stores alongside it.
///
/// The derivation here is fully local and deterministic (whitespace/sentence
/// tidy-up, bulleting, title extraction) so a Thought stays completely useful
/// with no network and no text model. A higher-quality LLM cleanup can be layered
/// on later without changing the contract: verbatim is never overwritten.
struct ThoughtProcessor: Sendable {

    /// How to render the cleaned view of a thought.
    enum Style: String, Codable, CaseIterable, Sendable, Identifiable {
        case verbatim   // no cleaned view — keep only the raw transcript
        case clean      // tidy prose
        case bullets    // one bullet per sentence
        case journal    // a single tidy reflective paragraph
        case idea       // tidy prose + a short generated title

        var id: String { rawValue }
        var label: String {
            switch self {
            case .verbatim: return "Verbatim only"
            case .clean:    return "Clean prose"
            case .bullets:  return "Bulleted notes"
            case .journal:  return "Journal entry"
            case .idea:     return "Idea + title"
            }
        }
    }

    func derive(from verbatim: String, style: Style) -> (cleaned: String?, title: String?) {
        let trimmed = verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        let title = Self.generateTitle(from: trimmed)
        switch style {
        case .verbatim:
            return (nil, title)
        case .clean, .journal:
            return (Self.tidyProse(trimmed), title)
        case .bullets:
            return (Self.bulleted(trimmed), title)
        case .idea:
            return (Self.tidyProse(trimmed), title)
        }
    }

    // MARK: - Local transforms

    /// Collapses runs of whitespace, normalises spacing around sentence
    /// punctuation, and upper-cases the first letter of each sentence.
    static func tidyProse(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = splitSentences(collapsed)
        let cased = sentences.map { capitalizeFirst($0) }
        return cased.joined(separator: " ")
    }

    static func bulleted(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let sentences = splitSentences(collapsed).map { capitalizeFirst($0) }
        return sentences.map { "• " + $0 }.joined(separator: "\n")
    }

    /// A short title: the first several words of the thought, tidied.
    static func generateTitle(from text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "Untitled thought" }
        let words = collapsed.split(whereSeparator: \.isWhitespace)
        let head = words.prefix(8).joined(separator: " ")
        let stripped = head.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?—- "))
        let titled = capitalizeFirst(stripped)
        return words.count > 8 ? titled + "…" : titled
    }

    // MARK: - Helpers

    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let piece = current.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { result.append(piece) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [text] : result
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }
}
