import Foundation
import Observation

// MARK: - Supporting types

/// What the token-budget indicator says, spec §7.3.
///
/// Every number here comes from one `VocabularyRanker.select` call. Nothing is
/// recomputed, re-ranked or re-estimated locally, because a budget indicator that
/// disagrees with the pipeline is a comforting fiction — the whole point of the screen
/// is to show the user *what Whisper will actually receive*.
struct VocabularyBudget: Equatable, Sendable {
    /// Terms the ranker selected: exactly what would be sent.
    let fitCount: Int
    /// Terms stored, including any the ranker can never send (blank text).
    let totalCount: Int
    let estimatedTokens: Int
    let budgetTokens: Int
    let pinnedCount: Int
    /// Pinned terms the ranker did **not** select. Normally zero; non-zero when pins
    /// alone overflow the 224-token cap, which the ranker resolves by truncating them
    /// like anything else.
    let pinnedNotSentCount: Int
    /// The ids that were selected, so a row can say whether it is being sent.
    let sentIDs: Set<UUID>

    /// Spec §7.3's sentence, verbatim in shape: "38 of 112 terms fit the current budget".
    var headline: String {
        "\(fitCount) of \(totalCount) term\(totalCount == 1 ? "" : "s") fit the current budget"
    }

    var tokenDetail: String {
        "\(estimatedTokens) of \(budgetTokens) tokens"
    }

    /// The pin story, and the only place this screen is allowed to talk about pins being
    /// "always included" — because when they overflow, they are not.
    var pinnedNote: String? {
        guard pinnedCount > 0 else { return nil }
        guard pinnedNotSentCount > 0 else {
            return "All \(pinnedCount) pinned term\(pinnedCount == 1 ? " is" : "s are") sent first, "
                + "ahead of everything else."
        }
        return "\(pinnedNotSentCount) of your \(pinnedCount) pinned terms do not fit and are "
            + "NOT being sent. Whisper's prompt is capped at \(budgetTokens) tokens and pins are "
            + "not exempt — unpin something, or shorten a “sounds like” hint."
    }

    var isOverflowing: Bool { fitCount < totalCount }
}

/// The outcome of one CSV import, reported per row.
struct VocabularyImportResult: Equatable, Sendable {
    var added = 0
    var updated = 0
    /// Rows that named a term already stored with the same values. Counted so a
    /// re-import of an export can say "30 already matched" instead of "nothing to import".
    var unchanged = 0
    var skipped: [CSVRowError] = []
    /// Set when the file itself could not be read. Distinct from a row error: nothing
    /// was changed at all.
    var fileError: String?

    var summary: String {
        if let fileError { return fileError }

        var parts: [String] = []
        if added > 0 { parts.append("added \(added)") }
        if updated > 0 { parts.append("updated \(updated)") }
        if unchanged > 0 { parts.append("\(unchanged) already matched") }

        if parts.isEmpty, skipped.isEmpty {
            return "That file had no term rows, so nothing changed."
        }

        var sentence = parts.isEmpty
            ? "No terms were imported"
            : "Imported: " + parts.joined(separator: ", ")
        if skipped.isEmpty {
            sentence += "."
        } else {
            sentence += ". \(skipped.count) row\(skipped.count == 1 ? "" : "s") skipped."
        }
        return sentence
    }
}

// MARK: - View model

/// Everything behind `VocabularyView`, spec §10.4.
///
/// Both stores are injected and both take a directory, so the whole screen is
/// constructible in a test against a temporary directory and never touches
/// Application Support. `now` is injected too: the ranker scores by recency, so a
/// hard-coded clock is the difference between a deterministic test and a flaky one.
///
/// Nothing here polls (§15). The budget is a computed property over the stores' current
/// contents, so it is recomputed when the vocabulary changes and at no other time.
@MainActor
@Observable
final class VocabularyViewModel {

    /// Whether `DictationPipeline` yet sends the vocabulary as Whisper's `prompt`.
    ///
    /// **It does not.** `DictationPipeline.dispatch` passes `vocabularyPrompt: ""`
    /// (`DictationPipeline.swift:264`, "wired with the mode pass (Task 16)"), so today
    /// this screen edits a list nothing transmits. While this is `false` the Terms tab
    /// says so on screen, because a budget indicator for a prompt that is never sent is
    /// exactly the comforting fiction this project keeps refusing to ship.
    /// **Flip it in the same commit that wires it** — see `docs/wiring/task24-wiring.md`.
    static let pipelineSendsVocabulary = true

    /// Whether anything calls `ReplacementEngine.apply`.
    ///
    /// **Nothing does.** The engine has no call site outside its own file and its own
    /// tests. Same contract as above: the Replacements tab says so until this is `true`.
    static let pipelineAppliesReplacements = true

    enum Tab: String, CaseIterable, Identifiable, Sendable {
        case terms, replacements

        var id: String { rawValue }

        var title: String {
            switch self {
            case .terms: return "Terms"
            case .replacements: return "Replacements"
            }
        }
    }

    // MARK: Injected

    let vocabulary: VocabularyStore
    let replacements: ReplacementStore

    private let now: () -> Date
    /// Tokens held back for the continuity tail (§5.1). Zero is the honest default for
    /// this screen: it describes a *first* segment, which reserves nothing.
    private let reservedTokens: Int
    private let readFile: (URL) throws -> String
    private let writeFile: (String, URL) throws -> Void

    // MARK: Observable state

    var tab: Tab = .terms

    /// The combined search-and-create field. One field, per §10.4 — which is why
    /// `createTerm()` has to be duplicate-proof rather than trusting the caller.
    var query = ""

    /// Sample text for the replacements preview. Not persisted: it is a scratchpad.
    var previewInput = ""

    private(set) var lastImport: VocabularyImportResult?
    private(set) var lastExport: String?
    /// A refused edit or a failed export, in the user's words.
    private(set) var lastError: String?

    init(vocabulary: VocabularyStore,
         replacements: ReplacementStore,
         now: @escaping () -> Date = Date.init,
         reservedTokens: Int = 0,
         readFile: @escaping (URL) throws -> String = {
             try String(contentsOf: $0, encoding: .utf8)
         },
         writeFile: @escaping (String, URL) throws -> Void = {
             try Data($0.utf8).write(to: $1, options: .atomic)
         }) {
        self.vocabulary = vocabulary
        self.replacements = replacements
        self.now = now
        self.reservedTokens = reservedTokens
        self.readFile = readFile
        self.writeFile = writeFile
    }

    // MARK: - Normalization

    /// The comparison key for "is this the same term?".
    ///
    /// Trimmed, interior whitespace runs collapsed, lowercased. Deliberately **not**
    /// diacritic-folded: this list is mostly proper nouns, and "Zoë" and "Zoe" are two
    /// different people's names, not a typo.
    static func normalizedKey(_ text: String) -> String {
        normalizedDisplay(text).lowercased()
    }

    /// The stored form: trimmed, interior whitespace runs collapsed to single spaces,
    /// case preserved. Newlines collapse too — a term containing one would break the
    /// comma-separated prompt it ends up inside.
    static func normalizedDisplay(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - The budget indicator, §7.3

    /// One ranker call. Everything the indicator says is derived from this.
    private var selection: VocabularySelection {
        VocabularyRanker.select(from: vocabulary.terms,
                                targetBundleID: nil,
                                now: now(),
                                reservedTokens: reservedTokens)
    }

    var budget: VocabularyBudget {
        let selection = selection
        let sentIDs = Set(selection.terms.map(\.id))
        let pinned = vocabulary.terms.filter(\.isPinned)
        return VocabularyBudget(
            // `selection.terms.count`, never `vocabulary.terms.count`: the whole point is
            // the difference between the two.
            fitCount: selection.terms.count,
            totalCount: selection.totalTermCount,
            estimatedTokens: selection.estimatedTokens,
            budgetTokens: VocabularyRanker.whisperPromptTokenBudget,
            pinnedCount: pinned.count,
            // Counted from the selection rather than assumed to be zero. The ranker sorts
            // pins first and then stops at the first term that does not fit
            // (`VocabularyRanker.swift:100-105`), so pins are truncated like anything else
            // once they overflow the cap on their own.
            pinnedNotSentCount: pinned.count { !sentIDs.contains($0.id) },
            sentIDs: sentIDs)
    }

    func isSent(_ term: VocabularyTerm) -> Bool {
        budget.sentIDs.contains(term.id)
    }

    /// The prompt string the pipeline would send. Shown verbatim so the user can see the
    /// truncation rather than take it on trust.
    var promptPreview: String {
        selection.promptString
    }

    // MARK: - Terms: reading

    private func matches(_ term: VocabularyTerm) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if term.text.localizedCaseInsensitiveContains(needle) { return true }
        return term.soundsLike?.localizedCaseInsensitiveContains(needle) ?? false
    }

    /// Terms being sent, in send order — so the list's own order shows the ranking.
    var sentTerms: [VocabularyTerm] {
        selection.terms.filter(matches)
    }

    /// Everything else, alphabetically. The ranker only publishes the prefix that fits,
    /// so the remainder has no meaningful order to show.
    var unsentTerms: [VocabularyTerm] {
        let sent = Set(selection.terms.map(\.id))
        return vocabulary.terms
            .filter { !sent.contains($0.id) }
            .filter(matches)
            .sorted { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
    }

    var hasAnyTerms: Bool { !vocabulary.terms.isEmpty }

    var hasVisibleTerms: Bool { !sentTerms.isEmpty || !unsentTerms.isEmpty }

    func term(id: UUID) -> VocabularyTerm? {
        vocabulary.terms.first { $0.id == id }
    }

    private func term(matching text: String) -> VocabularyTerm? {
        let key = Self.normalizedKey(text)
        guard !key.isEmpty else { return nil }
        return vocabulary.terms.first { Self.normalizedKey($0.text) == key }
    }

    /// The text the create button would add, or `nil` when there is nothing to add —
    /// because the field is empty, or because the term already exists and the row the
    /// user wants is already on screen beneath the field.
    var pendingTermText: String? {
        let text = Self.normalizedDisplay(query)
        guard !text.isEmpty, term(matching: text) == nil else { return nil }
        return text
    }

    // MARK: - Terms: writing

    /// Commits the search field as a term, and returns the term the user ended up on.
    ///
    /// One field does two jobs, so this has to be duplicate-proof rather than trusting
    /// its caller: typing a term that already exists lands on **that** term. Minting a
    /// second row with a fresh id and a zeroed `useCount` would split the term's ranking
    /// history in two, and the ranker would then score both halves below the whole.
    @discardableResult
    func createTerm() -> UUID? {
        let text = Self.normalizedDisplay(query)
        guard !text.isEmpty else { return nil }

        if let existing = term(matching: text) {
            query = ""
            lastError = nil
            return existing.id
        }

        let new = VocabularyTerm(id: UUID(), text: text, soundsLike: nil, isPinned: false,
                                 useCount: 0, lastUsed: nil, appBundleIDs: [])
        vocabulary.upsert(new)
        query = ""
        lastError = nil
        return new.id
    }

    /// Edits a term's text and hint. Returns `false` when the edit was refused, with the
    /// reason in `lastError`.
    @discardableResult
    func updateTerm(id: UUID, text: String, soundsLike: String?) -> Bool {
        guard let existing = vocabulary.terms.first(where: { $0.id == id }) else { return false }

        let newText = Self.normalizedDisplay(text)
        guard !newText.isEmpty else {
            lastError = "A term needs some text, so the previous text was kept."
            return false
        }

        if let clash = term(matching: newText), clash.id != id {
            // Refused rather than merged. Merging would have to throw away one term's
            // `useCount` and `lastUsed`, and the user cannot see that happen.
            lastError = "“\(clash.text)” is already in your vocabulary. Two entries for one term "
                + "would split its ranking history, so the rename was refused — delete one of "
                + "them instead."
            return false
        }

        var updated = existing
        updated.text = newText
        let hint = Self.normalizedDisplay(soundsLike ?? "")
        updated.soundsLike = hint.isEmpty ? nil : hint
        // `useCount`, `lastUsed`, `appBundleIDs` and `isPinned` are copied through
        // untouched. They are ranking history the pipeline maintains, and fixing a typo
        // must not cost a term its place in the prompt.
        vocabulary.upsert(updated)
        lastError = nil
        return true
    }

    func togglePin(id: UUID) {
        guard var term = vocabulary.terms.first(where: { $0.id == id }) else { return }
        term.isPinned.toggle()
        // Everything else is copied through untouched: a pin is a ranking override, not
        // an edit, and must not cost the term its history.
        vocabulary.upsert(term)
    }

    func deleteTerm(id: UUID) {
        vocabulary.delete(id: id)
    }

    /// Adds any starter term the list does not already have, and returns how many.
    ///
    /// Deliberately **not** called "Restore Defaults", and deliberately additive: the
    /// store skips seeding once a vocabulary file exists precisely so a list the user
    /// emptied is never handed back, and a button that quietly defeated that would be
    /// worse than no button. This one cannot delete anything — but it *can* bring back a
    /// term the user deleted on purpose, which is why the button on screen says so.
    @discardableResult
    func addStarterTerms() -> Int {
        var added = 0
        for text in VocabularyStore.starterTerms where term(matching: text) == nil {
            vocabulary.upsert(VocabularyTerm(id: UUID(), text: text, soundsLike: nil,
                                             isPinned: false, useCount: 0, lastUsed: nil,
                                             appBundleIDs: []))
            added += 1
        }
        return added
    }

    // MARK: - CSV

    func importTerms(from url: URL) {
        do {
            lastImport = merge(VocabularyCSV.parse(try readFile(url)))
        } catch {
            lastImport = VocabularyImportResult(
                fileError: "\(url.lastPathComponent) could not be read "
                    + "(\(error.localizedDescription)). Nothing was changed.")
        }
        lastExport = nil
    }

    /// Applies a parsed file to the vocabulary.
    ///
    /// **An import is always a merge.** `VocabularyStore.replaceAll` is deliberately
    /// never called from here, under any circumstances — not even when every row parsed.
    /// A file naming ten terms must not be able to delete the ninety it does not name,
    /// and a file where row 3 was malformed must not delete anything at all. Rows are
    /// applied one at a time through `upsert`, so a partial import is exactly the good
    /// rows and nothing else.
    private func merge(_ parse: VocabularyCSVParse) -> VocabularyImportResult {
        var result = VocabularyImportResult(skipped: parse.errors)

        for row in parse.rows {
            if let existing = term(matching: row.text) {
                var updated = existing
                // Only *stated* columns win. `useCount`, `lastUsed`, `appBundleIDs` and
                // the id are never in a CSV, so a CSV can never reset them — and the
                // stored spelling wins over the file's casing, because the user chose it.
                if let hint = row.soundsLike { updated.soundsLike = hint }
                if let pinned = row.isPinned { updated.isPinned = pinned }
                if updated == existing {
                    result.unchanged += 1
                } else {
                    vocabulary.upsert(updated)
                    result.updated += 1
                }
            } else {
                vocabulary.upsert(
                    VocabularyTerm(id: UUID(), text: row.text, soundsLike: row.soundsLike,
                                   isPinned: row.isPinned ?? false, useCount: 0, lastUsed: nil,
                                   appBundleIDs: []))
                result.added += 1
            }
        }
        return result
    }

    func exportTerms(to url: URL) {
        do {
            try writeFile(VocabularyCSV.export(vocabulary.terms), url)
            let count = vocabulary.terms.count
            lastExport = "Exported \(count) term\(count == 1 ? "" : "s") to \(url.lastPathComponent)."
            lastError = nil
        } catch {
            lastExport = nil
            lastError = "Export failed (\(error.localizedDescription)). Nothing was written."
        }
    }

    func clearImportReport() {
        lastImport = nil
        lastExport = nil
    }

    // MARK: - Replacements

    var visibleReplacements: [Replacement] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return replacements.replacements }
        return replacements.replacements.filter {
            $0.find.localizedCaseInsensitiveContains(needle)
                || $0.replaceWith.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Appends a rule seeded from the search field, and returns its id so the view can
    /// focus it.
    ///
    /// It starts **switched off**, and that is not timidity. An empty `replaceWith` is a
    /// legitimate rule — deleting "um" is exactly what a user wants — so the engine
    /// cannot treat it as unfinished and skip it. A new rule is therefore always half
    /// typed and always destructive, and the only safe default is inert. The row on
    /// screen says so next to the toggle.
    @discardableResult
    func addReplacement() -> UUID {
        let new = Replacement(id: UUID(),
                              find: Self.normalizedDisplay(query),
                              replaceWith: "",
                              wholeWordOnly: true,
                              caseSensitive: false,
                              isEnabled: false)
        replacements.upsert(new)
        query = ""
        return new.id
    }

    func updateReplacement(_ replacement: Replacement) {
        replacements.upsert(replacement)
    }

    func deleteReplacement(id: UUID) {
        replacements.delete(id: id)
    }

    func moveReplacements(fromOffsets source: IndexSet, toOffset destination: Int) {
        replacements.move(fromOffsets: source, toOffset: destination)
    }

    /// The rules run over `previewInput`, in order.
    ///
    /// This is the same pure function the pipeline will call, so what the user sees here
    /// is what a transcript would become — which is the only honest thing to show while
    /// `pipelineAppliesReplacements` is still `false`.
    var previewOutput: String {
        ReplacementEngine.apply(replacements.replacements, to: previewInput)
    }

    // MARK: - Honesty surfaces

    /// Shown under the active tab while the pipeline ignores what it edits.
    var unwiredNotice: String? {
        switch tab {
        case .terms:
            guard !Self.pipelineSendsVocabulary else { return nil }
            return "Saved, but no dictation sends these yet — DictationPipeline passes an empty "
                + "Whisper prompt until Task 16 wires it (docs/wiring/task24-wiring.md). "
                + "The count below is what it will send once it does."
        case .replacements:
            guard !Self.pipelineAppliesReplacements else { return nil }
            return "Saved, but nothing applies these yet — no code path calls "
                + "ReplacementEngine.apply until Task 16 wires it "
                + "(docs/wiring/task24-wiring.md). The preview below is the real engine."
        }
    }

    /// Corrupt-file warnings from either store, so an emptied list is never mistaken for
    /// one the user cleared.
    var recoveryWarnings: [String] {
        [vocabulary.recoveryWarning, replacements.recoveryWarning].compactMap { $0 }
    }

    func dismissRecoveryWarnings() {
        vocabulary.dismissRecoveryWarning()
        replacements.dismissRecoveryWarning()
    }

    /// Write failures. The lists are still in memory, so this says the truth: the edit
    /// took, the file did not.
    var saveErrors: [String] {
        [vocabulary.lastSaveError, replacements.lastSaveError].compactMap { $0 }
    }
}
