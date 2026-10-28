import Foundation

/// Word-level text measurements for dictation stats.
///
/// Both metrics are computed over the SAME tokenizer, so a word counted for WPM
/// is the same unit compared for edit distance. Nothing here allocates beyond the
/// token arrays; inputs are at most a few hundred words.
///
/// **What counts as a word** (documented so the numbers stay explainable):
/// a run of characters that contains at least one letter or digit. Apostrophes
/// (straight or curly) and hyphens are *internal* characters, so `don't` and
/// `well-known` are each ONE word — they are spoken as one unit, and splitting
/// them would overstate dictation throughput. A `.` or `,` between two digits is
/// also internal, so `2.1.4` and `1,000` count once. Everything else — spaces,
/// newlines, tabs, quotes, dashes, emoji, standalone punctuation — is a
/// separator, and a run with no letter or digit in it (`...`, `--`, `🎉`) is not
/// a word at all.
enum TextMetrics {
    /// Number of words in `text`. Empty and whitespace-only strings return 0.
    static func wordCount(_ text: String) -> Int {
        words(in: text).count
    }

    /// Normalized 0…1 Levenshtein distance over WORDS, not characters:
    /// word-level edit distance divided by the length of the longer word
    /// sequence.
    ///
    /// Identical text → 0.0. Fully disjoint text → 1.0. Two empty strings → 0.0
    /// (never NaN — the zero-length case short-circuits before the division).
    /// Comparison is case-insensitive so that punctuation and capitalization a
    /// mode adds for readability do not register as the LLM "changing my words".
    static func normalizedEditDistance(_ a: String, _ b: String) -> Double {
        let left = words(in: a).map { $0.lowercased() }
        let right = words(in: b).map { $0.lowercased() }

        let longest = max(left.count, right.count)
        guard longest > 0 else { return 0.0 }

        let distance = levenshtein(left, right)
        return Double(distance) / Double(longest)
    }

    // MARK: - Tokenizing

    /// Splits `text` into words using the rules documented on the enum. Leading
    /// and trailing internal characters are trimmed, so `'quoted'` tokenizes as
    /// `quoted`.
    static func words(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var words: [String] = []
        var current = ""
        var currentHasAlphanumeric = false
        let characters = Array(text)

        func flush() {
            defer {
                current = ""
                currentHasAlphanumeric = false
            }
            guard currentHasAlphanumeric else { return }
            let trimmed = current.trimmingCharacters(in: Self.internalCharacters)
            guard !trimmed.isEmpty else { return }
            words.append(trimmed)
        }

        for index in characters.indices {
            let character = characters[index]
            if character.isLetter || character.isNumber {
                current.append(character)
                currentHasAlphanumeric = true
            } else if isInternal(character) {
                current.append(character)
            } else if isDigitSeparator(character, at: index, in: characters) {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()

        return words
    }

    /// Characters that never split a word and are trimmed from its edges.
    private static let internalCharacters = CharacterSet(charactersIn: "-'\u{2018}\u{2019}")

    private static func isInternal(_ character: Character) -> Bool {
        character == "-" || character == "'" || character == "\u{2018}" || character == "\u{2019}"
    }

    /// `.` and `,` hold a number together (`2.1.4`, `1,000`) but only when they
    /// sit between two digits — a sentence-ending period still splits.
    private static func isDigitSeparator(
        _ character: Character,
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        guard character == "." || character == "," else { return false }
        guard index > 0, index + 1 < characters.count else { return false }
        return characters[index - 1].isNumber && characters[index + 1].isNumber
    }

    // MARK: - Distance

    /// Two-row Levenshtein: O(n·m) time, O(min(n, m)) space. At a few hundred
    /// words per side this is microseconds, so it can run on every dictation.
    private static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        // Iterate over the longer sequence so the rows stay as short as possible.
        let (rowSource, columnSource) = a.count <= b.count ? (a, b) : (b, a)

        var previous = Array(0...rowSource.count)
        var current = [Int](repeating: 0, count: rowSource.count + 1)

        for columnIndex in 1...columnSource.count {
            current[0] = columnIndex
            let columnWord = columnSource[columnIndex - 1]
            for rowIndex in 1...rowSource.count {
                let substitutionCost = rowSource[rowIndex - 1] == columnWord ? 0 : 1
                current[rowIndex] = min(
                    previous[rowIndex] + 1,                       // deletion
                    current[rowIndex - 1] + 1,                    // insertion
                    previous[rowIndex - 1] + substitutionCost     // substitution
                )
            }
            swap(&previous, &current)
        }

        return previous[rowSource.count]
    }
}
