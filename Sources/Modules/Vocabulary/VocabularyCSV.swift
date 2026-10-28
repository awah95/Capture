import Foundation

/// One row the import refused, with the line it came from.
///
/// Errors are per-row on purpose. A single bad line in a hand-edited file must cost
/// the user that line and nothing else, and "the import failed" tells them nothing
/// they can act on.
struct CSVRowError: Error, Equatable, Identifiable, Sendable {
    let line: Int
    let reason: String

    /// Line numbers are unique within one parse, so they identify a row.
    var id: Int { line }
}

/// A parsed term row. `soundsLike` and `isPinned` are optional to mean **not stated**
/// rather than "empty" — a one-column list of names must not silently unpin and
/// de-hint every term it mentions.
struct VocabularyCSVRow: Equatable, Sendable {
    let line: Int
    let text: String
    let soundsLike: String?
    let isPinned: Bool?
}

struct VocabularyCSVParse: Equatable, Sendable {
    var rows: [VocabularyCSVRow] = []
    var errors: [CSVRowError] = []
}

/// Reads and writes the vocabulary as CSV.
///
/// Pure: strings in, strings out. The file seam lives in the view model so the whole
/// minefield below is testable without a filesystem.
///
/// CSV is a minefield and this parser is deliberately hand-rolled rather than a
/// `split(separator: ",")`, because every one of these appears in real exported files:
/// quoted fields containing commas, `""` escapes, newlines inside a quoted field,
/// CRLF line endings, and a UTF-8 BOM in front of the header. A row it cannot make
/// sense of is **skipped with a reason**, never allowed to abort the import — see
/// `docs/wiring/task24-wiring.md` for the per-case table.
enum VocabularyCSV {

    /// Written on export, tolerated but not required on import.
    static let header = "text,soundsLike,pinned"

    /// `text`, `soundsLike`, `pinned`. `useCount`, `lastUsed` and `appBundleIDs` are
    /// deliberately absent: they are ranking history the pipeline maintains, and a
    /// file the user hand-edits has no business resetting them.
    static let columnCount = 3

    // MARK: - Import

    static func parse(_ input: String) -> VocabularyCSVParse {
        var source = Substring(input)
        // A BOM in front of the header makes the header unrecognisable, which silently
        // eats the first real term instead of the header. Excel writes one by default.
        if source.first == "\u{FEFF}" { source = source.dropFirst() }

        var records = scan(source).filter { !$0.isBlank }
        if let first = records.first, isHeader(first) { records.removeFirst() }

        var parse = VocabularyCSVParse()
        for record in records {
            switch row(from: record) {
            case .success(let row): parse.rows.append(row)
            case .failure(let error): parse.errors.append(error)
            }
        }
        return parse
    }

    /// Turns one scanned record into a row, or into the reason it was refused.
    ///
    /// Every refusal is scoped to its own row: the caller keeps going. A hand-edited
    /// file with one bad line is the common case, and losing the other 99 lines over it
    /// would be indefensible.
    private static func row(from record: RawRecord) -> Result<VocabularyCSVRow, CSVRowError> {
        func refuse(_ reason: String) -> Result<VocabularyCSVRow, CSVRowError> {
            .failure(CSVRowError(line: record.line, reason: reason))
        }

        if record.isUnterminated {
            return refuse("a quoted field was never closed, so the rest of the file could not be "
                          + "read as columns. The row was skipped.")
        }

        // Trailing empty columns are harmless — a spreadsheet adds them. A row with
        // *content* past the last known column almost always means an unquoted comma
        // inside the term ("Example Forms, Inc"), and importing the fragment before the
        // comma would corrupt the term rather than fail to import it.
        if record.fields.count > columnCount,
           record.fields.dropFirst(columnCount).contains(where: { !isBlank($0) }) {
            return refuse("\(record.fields.count) columns where at most \(columnCount) were "
                          + "expected — a comma inside a term has to be quoted. The row was skipped.")
        }

        let text = collapsed(record.fields[0])
        guard !text.isEmpty else {
            return refuse("no term text. The row was skipped.")
        }

        // A column that is absent, or present but blank, means **not stated**: the
        // import leaves the corresponding value alone. Without that, a one-column list
        // of names would unpin and de-hint every term it mentions.
        var soundsLike: String?
        if record.fields.count > 1 {
            let hint = collapsed(record.fields[1])
            if !hint.isEmpty { soundsLike = hint }
        }

        var isPinned: Bool?
        if record.fields.count > 2 {
            let raw = record.fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                guard let value = boolean(raw) else {
                    return refuse("“\(raw)” is not a yes/no value for pinned. The row was skipped.")
                }
                isPinned = value
            }
        }

        return .success(VocabularyCSVRow(line: record.line, text: text,
                                         soundsLike: soundsLike, isPinned: isPinned))
    }

    /// Generous on input, because the file may well have been written by hand or by a
    /// spreadsheet that helpfully localised `TRUE`.
    private static func boolean(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "yes", "y", "1", "pinned", "pin": return true
        case "false", "no", "n", "0", "unpinned": return false
        default: return nil
        }
    }

    private static func isHeader(_ record: RawRecord) -> Bool {
        guard let first = record.fields.first else { return false }
        // Only the first column is checked, so a two-column hand-written file with a
        // `text,hint` header is still recognised. A file with no header at all keeps its
        // first row as data — a bare list of names is a perfectly ordinary import.
        return ["text", "term"].contains(first.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased())
    }

    // MARK: - Export

    static func export(_ terms: [VocabularyTerm]) -> String {
        var lines = [header]
        for term in terms {
            lines.append([quoted(term.text),
                          quoted(term.soundsLike ?? ""),
                          term.isPinned ? "true" : "false"].joined(separator: ","))
        }
        // A trailing newline, so appending to the file by hand does not join two rows.
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes only when it has to, so an export stays readable, and doubles interior
    /// quotes so the round trip is exact.
    private static func quoted(_ value: String) -> String {
        let needsQuotes = value.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Scanning

    /// One record, with the 1-based line it began on so an error can point at it.
    private struct RawRecord {
        var line: Int
        var fields: [String]
        /// The record ran to end-of-input inside a quoted field.
        var isUnterminated: Bool

        /// A blank line: one empty field and nothing else. Not an error.
        var isBlank: Bool {
            !isUnterminated && fields.count == 1
                && fields[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// A single forward pass, tracking whether it is inside a quoted field.
    ///
    /// This is the part `split(separator: ",")` cannot do: `,`, `\n`, `\r\n` and `""`
    /// all mean something different inside quotes than outside, and the line counter has
    /// to keep advancing through a quoted newline or every error after it points at the
    /// wrong row.
    private static func scan(_ source: Substring) -> [RawRecord] {
        var records: [RawRecord] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var recordLine = 1

        let characters = Array(source)
        var index = 0

        func endRecord(unterminated: Bool) {
            fields.append(field)
            field = ""
            records.append(RawRecord(line: recordLine, fields: fields, isUnterminated: unterminated))
            fields = []
            recordLine = line
        }

        while index < characters.count {
            let character = characters[index]

            if inQuotes {
                if character == "\"" {
                    // `""` is an escaped quote; a lone `"` closes the field.
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                    } else {
                        inQuotes = false
                        index += 1
                    }
                } else if character.isNewline {
                    // Normalised to `\n`, so CRLF inside a quoted field is one break.
                    field.append("\n")
                    line += 1
                    index += 1
                } else {
                    field.append(character)
                    index += 1
                }
                continue
            }

            if character == "\"", field.isEmpty {
                inQuotes = true
                index += 1
            } else if character == "," {
                fields.append(field)
                field = ""
                index += 1
            } else if character.isNewline {
                // `isNewline`, not `== "\r"` or `== "\n"`: Swift merges CRLF into a
                // *single* `Character`, so comparing against "\r" never matches a
                // Windows line ending and a whole CRLF file parses as one giant row.
                line += 1
                index += 1
                endRecord(unterminated: false)
            } else {
                // A quote in the middle of an unquoted field (`a"b`) is a literal
                // character. Rejecting it would refuse rows a human would call fine.
                field.append(character)
                index += 1
            }
        }

        // Input that did not end with a line break still has one last record — and an
        // input that ended mid-quote has to be reported, not silently dropped.
        if inQuotes || !field.isEmpty || !fields.isEmpty {
            endRecord(unterminated: inQuotes)
        }
        return records
    }

    // MARK: - Field cleanup

    /// Trims, and collapses every run of whitespace — including a newline that arrived
    /// inside a quoted field — to a single space. A term containing a line break would
    /// break the comma-separated list it ends up inside.
    private static func collapsed(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
