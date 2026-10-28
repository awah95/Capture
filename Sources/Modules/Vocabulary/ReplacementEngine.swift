import Foundation

/// One user-configured text substitution, applied to a transcript before any
/// LLM reshaping. Everything here is typed by the user, so both `find` and
/// `replaceWith` are treated as literal text — never as a regular expression
/// and never as a substitution template.
struct Replacement: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var find: String
    var replaceWith: String
    var wholeWordOnly: Bool
    var caseSensitive: Bool
    var isEnabled: Bool
}

/// Applies a user's text replacements to a transcript.
///
/// Whisper reliably mishears the same handful of things — a name, a piece of
/// jargon, a shorthand the user says constantly — so the fix belongs in the
/// user's own rule list rather than in a prompt. These run before any LLM step
/// so the model sees the corrected words.
///
/// The property that makes this non-trivial: **each rule gets exactly one
/// left-to-right pass**, and the text a rule writes is never re-scanned by that
/// same rule. Without that, a perfectly reasonable rule like
/// `"cat"` → `"cat and dog"` either loops forever or runs away. Matching is done
/// once over the input string and the output is assembled from the resulting
/// non-overlapping match list, so the exactly-once guarantee is structural
/// rather than a guard bolted on afterwards.
enum ReplacementEngine {

    /// Applies enabled replacements in array order, one left-to-right pass each,
    /// never re-scanning text a rule has already written.
    ///
    /// Rules compose in order: rule 2 operates on rule 1's output. A rule with an
    /// empty `find`, or one whose pattern cannot be compiled, is skipped rather
    /// than allowed to fail the whole transcript — a bad rule must never cost the
    /// user their dictation.
    static func apply(_ replacements: [Replacement], to text: String) -> String {
        replacements.reduce(text) { current, replacement in
            applyOne(replacement, to: current)
        }
    }

    // MARK: - A single rule

    private static func applyOne(_ replacement: Replacement, to text: String) -> String {
        guard replacement.isEnabled, !replacement.find.isEmpty, !text.isEmpty else { return text }
        guard let regex = makeRegex(for: replacement) else { return text }

        let source = text as NSString
        let matches = regex.matches(in: text,
                                    options: [],
                                    range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        // Matches arrive in ascending order and never overlap, so a single
        // forward walk that copies the gaps and substitutes the matches is all
        // that is needed — and the substituted text is never looked at again.
        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            guard range.location != NSNotFound,
                  range.length > 0,
                  range.location >= cursor else { continue }
            if range.location > cursor {
                result += source.substring(with: NSRange(location: cursor,
                                                         length: range.location - cursor))
            }
            result += replacement.replaceWith
            cursor = range.location + range.length
        }
        if cursor < source.length {
            result += source.substring(from: cursor)
        }
        return result
    }

    /// Compiles the user's literal search text into a regex.
    ///
    /// `escapedPattern(for:)` is what keeps the input literal: a user who types
    /// `a.b` means those three characters, not "a, any character, b".
    private static func makeRegex(for replacement: Replacement) -> NSRegularExpression? {
        var pattern = NSRegularExpression.escapedPattern(for: replacement.find)
        if replacement.wholeWordOnly {
            pattern = "\\b" + pattern + "\\b"
        }
        let options: NSRegularExpression.Options = replacement.caseSensitive ? [] : [.caseInsensitive]
        return try? NSRegularExpression(pattern: pattern, options: options)
    }
}
