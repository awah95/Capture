import AppKit
import SwiftUI

/// Vocabulary, spec §10.4 — two tabs, one combined search-and-create field, CSV
/// import/export, a pin per term, and the §7.3 token-budget indicator.
///
/// The screen owns no rules. Everything a control reads or writes goes through
/// `VocabularyViewModel`, which is why the things that matter — the indicator agreeing
/// with the ranker, an import never deleting a term it does not mention, an edit never
/// resetting `useCount` — are tested without a window.
///
/// **There is no window controller here on purpose.** Task 21 is building the main
/// window's `NavigationSplitView` and will host this view in its detail pane; adding a
/// second standalone window now would only be something to delete. See
/// `docs/wiring/task24-wiring.md`.
struct VocabularyView: View {
    @Bindable var model: VocabularyViewModel

    /// Whether the per-row list of skipped import rows is showing. Purely presentational,
    /// so it lives here rather than in the view model.
    @State private var importReportExpanded = false

    var body: some View {
        ZStack {
            CapturPalette.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                CapturPageHeader(
                    title: "Vocabulary",
                    subtitle: "Teach Captur the names, jargon, and corrections that matter to you."
                )

                header

                Group {
                    switch model.tab {
                    case .terms:
                        HStack(alignment: .top, spacing: 12) {
                            termsPanel
                                .frame(minWidth: 360, maxWidth: .infinity,
                                       maxHeight: .infinity, alignment: .top)

                            CapturCard("Whisper prompt", symbol: "gauge.with.dots.needle.33percent") {
                                budgetBar
                            }
                            .frame(minWidth: 250, idealWidth: 300, maxWidth: 320,
                                   maxHeight: .infinity, alignment: .top)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    case .replacements:
                        CapturCard("Replacement rules", symbol: "arrow.left.arrow.right",
                                   caption: "Rules run from top to bottom. Drag to change their order.") {
                            replacementsList
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(24)
        }
        .frame(minWidth: 680, idealWidth: 880, minHeight: 500, idealHeight: 680)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Vocabulary section", selection: $model.tab) {
                    ForEach(VocabularyViewModel.Tab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                searchAndCreate
            }

            if let notice = model.unwiredNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.recoveryWarnings, id: \.self) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Dismiss") { model.dismissRecoveryWarnings() }
                        .controlSize(.small)
                }
            }

            ForEach(model.saveErrors, id: \.self) { error in
                // The list is still in memory, so this says what is actually true: the
                // edit took, the file did not.
                Label("Your edits are in place but could not be written to disk (\(error)). "
                      + "The next change tries again.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let report = model.lastImport {
                importReport(report)
            } else if let exported = model.lastExport {
                Label(exported, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .capturSurface(inset: true, radius: 10)
    }

    /// Unlike an intrinsic-height card, the editable term list should consume the
    /// workspace left after the header. Keeping the full-height surface local avoids
    /// forcing metric and utility cards elsewhere in the app to stretch.
    private var termsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "textformat.abc")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Terms")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }

            termsList
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("Pinned terms are considered first; the prompt budget still applies.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .capturSurface()
    }

    /// One field, two jobs (§10.4). It filters as you type and offers to add what you
    /// typed — but only when it is not already in the list, so it cannot invite the
    /// duplicate that `createTerm` then has to refuse.
    private var searchAndCreate: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)

            TextField(model.tab == .terms ? "Search, or type a new term" : "Search replacements",
                      text: $model.query)
                .textFieldStyle(.plain)
                .onSubmit { commitFromField() }

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear search")
            }

            switch model.tab {
            case .terms:
                if let pending = model.pendingTermText {
                    Button("Add “\(pending)”") { model.createTerm() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            case .replacements:
                Button("New rule") { model.addReplacement() }
                    .controlSize(.small)
            }

            if model.tab == .terms {
                Menu {
                    Button("Import CSV…") { chooseImportFile() }
                    Button("Export CSV…") { chooseExportFile() }
                    Divider()
                    Button("Add the starter terms…") { model.addStarterTerms() }
                        .help("Adds any starter term you don't have. It never deletes anything — "
                              + "but it does bring back starter terms you deleted on purpose.")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More vocabulary actions")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .capturSurface(radius: 8)
    }

    private func commitFromField() {
        switch model.tab {
        case .terms:
            if model.pendingTermText != nil { model.createTerm() }
        case .replacements:
            if !model.query.isEmpty { model.addReplacement() }
        }
    }

    /// A per-row account of the last import, not one opaque "it failed". A file with one
    /// bad line is the common case and the user needs the line number to fix it.
    @ViewBuilder
    private func importReport(_ report: VocabularyImportResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(report.summary,
                      systemImage: report.fileError == nil ? "square.and.arrow.down" : "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(report.skipped.isEmpty && report.fileError == nil
                                     ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !report.skipped.isEmpty {
                    Button(importReportExpanded ? "Hide rows" : "Show rows") {
                        importReportExpanded.toggle()
                    }
                    .controlSize(.small)
                }
                Button("Dismiss") { model.clearImportReport() }
                    .controlSize(.small)
            }

            if importReportExpanded {
                ForEach(report.skipped) { error in
                    Text("Line \(error.line): \(error.reason)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var termsList: some View {
        if !model.hasAnyTerms {
            // Copy lives inline rather than in `EmptyState.Copy`: that file belongs to
            // another task on this branch. Move it there next time it is touched.
            EmptyState(message: "No terms yet. Add the names and jargon Whisper keeps "
                       + "getting wrong.",
                       symbol: "textformat.abc",
                       actionTitle: "Add the starter terms",
                       action: { model.addStarterTerms() })
        } else if !model.hasVisibleTerms {
            EmptyState.noSearchMatches
        } else {
            List {
                if !model.sentTerms.isEmpty {
                    Section {
                        ForEach(model.sentTerms) { term in
                            termRow(term)
                        }
                    } header: {
                        Text("Sent to Whisper, highest-ranked first")
                    }
                }

                if !model.unsentTerms.isEmpty {
                    Section {
                        ForEach(model.unsentTerms) { term in
                            termRow(term)
                        }
                    } header: {
                        Text("Over budget — not sent right now")
                    } footer: {
                        Text("These are still stored, and still go to the spelling list the "
                             + "language model sees, which has no cap. They just do not fit in "
                             + "Whisper's \(VocabularyRanker.whisperPromptTokenBudget)-token prompt.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .alternatingRowBackgrounds()
        }
    }

    private func termRow(_ term: VocabularyTerm) -> some View {
        TermRow(term: term,
                onCommit: { text, hint in
                    model.updateTerm(id: term.id, text: text, soundsLike: hint)
                },
                onTogglePin: { model.togglePin(id: term.id) },
                onDelete: { model.deleteTerm(id: term.id) })
            .id(term.id)
    }

    @ViewBuilder
    private var replacementsList: some View {
        VStack(spacing: 0) {
            if model.replacements.replacements.isEmpty {
                EmptyState(message: "No replacements. Add one for the word Whisper always "
                           + "mishears the same way.",
                           symbol: "arrow.left.arrow.right",
                           actionTitle: "New rule",
                           action: { model.addReplacement() })
            } else if model.visibleReplacements.isEmpty {
                EmptyState.noSearchMatches
            } else {
                List {
                    Section {
                        ForEach(model.visibleReplacements) { rule in
                            ReplacementRow(
                                rule: rule,
                                onCommit: { model.updateReplacement($0) },
                                onDelete: { model.deleteReplacement(id: rule.id) })
                                .id(rule.id)
                        }
                        .onMove { model.moveReplacements(fromOffsets: $0, toOffset: $1) }
                    } header: {
                        Text("Applied in order — rule 2 sees rule 1's output")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .alternatingRowBackgrounds()
            }

            Divider()
            previewPane
        }
    }

    /// The real engine, on the user's own sample text. While nothing in the pipeline
    /// calls `ReplacementEngine.apply`, this is the only honest way to show that a rule
    /// does what the user thinks — the same pure function, the same rule order.
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try it")
                .font(.caption).bold()
                .foregroundStyle(.secondary)

            TextField("Paste or type a sentence", text: $model.previewInput, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)

            if !model.previewInput.isEmpty {
                Text(model.previewOutput)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .capturSurface(inset: true, radius: 7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 12)
    }

    // MARK: - The budget indicator, §7.3

    private var budgetBar: some View {
        let budget = model.budget
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(budget.headline)
                    .font(.callout)
                    .foregroundStyle(budget.isOverflowing ? .primary : .secondary)
                Spacer(minLength: 12)
                Text(budget.tokenDetail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(min(budget.estimatedTokens, budget.budgetTokens)),
                         total: Double(budget.budgetTokens))
                .progressViewStyle(.linear)
                .tint(budget.pinnedNotSentCount > 0 ? .orange : .accentColor)
                .accessibilityLabel("Whisper prompt budget")
                .accessibilityValue(budget.tokenDetail)

            if let note = budget.pinnedNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(budget.pinnedNotSentCount > 0 ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Shown rather than summarised: the number above is only trustworthy if the
            // string it describes can be read.
            DisclosureGroup("What Whisper receives") {
                Text(model.promptPreview.isEmpty ? "— nothing —" : model.promptPreview)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.caption)

            Text("Counted for the first segment of a dictation. Later segments in the same "
                 + "dictation share this budget with the continuity tail, so they carry fewer "
                 + "terms.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - File panels

    /// AppKit panels rather than `.fileImporter` / `.fileExporter`, so the view model
    /// stays free of `FileDocument` and the file seam it *does* own remains two plain
    /// closures the tests can replace.
    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Columns: term, sounds like, pinned. A row that cannot be read is "
            + "skipped and reported — nothing is deleted."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importReportExpanded = false
        model.importTerms(from: url)
    }

    private func chooseExportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "captur-vocabulary.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportTerms(to: url)
    }
}

// MARK: - Term row

/// One term: pin, text, hint, delete.
///
/// The two fields are local drafts committed on Return or on losing focus, then re-seeded
/// from the store. That re-seed is the point: it shows the user what was actually stored
/// (whitespace collapsed), and it puts the old text back when the view model refuses an
/// edit — a field left holding a value the store rejected is a lie the user will act on.
private struct TermRow: View {
    let term: VocabularyTerm
    let onCommit: (String, String) -> Bool
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var text = ""
    @State private var hint = ""
    @FocusState private var focused: Field?

    private enum Field { case text, hint }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onTogglePin) {
                Image(systemName: term.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(term.isPinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: 18)
            .help(term.isPinned
                  ? "Pinned: ranked ahead of every unpinned term. Pins are still subject to the "
                    + "224-token cap — the indicator says so when they stop fitting."
                  : "Pin to rank this ahead of every unpinned term.")
            .accessibilityLabel(term.isPinned ? "Unpin \(term.text)" : "Pin \(term.text)")

            TextField("Term", text: $text)
                .focused($focused, equals: .text)
                .onSubmit(commit)

            TextField("sounds like…", text: $hint)
                .focused($focused, equals: .hint)
                .onSubmit(commit)
                .frame(width: 160)
                .foregroundStyle(.secondary)

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(term.text)")
        }
        .onAppear(perform: seed)
        .onChange(of: term) { _, _ in seed() }
        .onChange(of: focused) { previous, current in
            if previous != nil, current == nil { commit() }
        }
    }

    private func seed() {
        text = term.text
        hint = term.soundsLike ?? ""
    }

    private func commit() {
        guard text != term.text || hint != (term.soundsLike ?? "") else { return }
        if !onCommit(text, hint) { seed() }
    }
}

// MARK: - Replacement row

private struct ReplacementRow: View {
    let rule: Replacement
    let onCommit: (Replacement) -> Void
    let onDelete: () -> Void

    @State private var find = ""
    @State private var replaceWith = ""
    @FocusState private var focused: Field?

    private enum Field { case find, replaceWith }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { commit(isEnabled: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(rule.isEnabled
                      ? "On. This rule rewrites transcripts."
                      : "Off. New rules start off, because an empty replacement would delete the "
                        + "word rather than correct it.")
                .accessibilityLabel(rule.isEnabled ? "Disable this rule" : "Enable this rule")

            TextField("Heard as", text: $find)
                .focused($focused, equals: .find)
                .onSubmit(commitText)

            Image(systemName: "arrow.right").foregroundStyle(.tertiary)

            TextField("Written as", text: $replaceWith)
                .focused($focused, equals: .replaceWith)
                .onSubmit(commitText)

            Menu {
                Toggle("Whole words only", isOn: Binding(
                    get: { rule.wholeWordOnly },
                    set: { commit(wholeWordOnly: $0) }))
                Toggle("Match case", isOn: Binding(
                    get: { rule.caseSensitive },
                    set: { commit(caseSensitive: $0) }))
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Matching options")

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete this rule")
        }
        .onAppear(perform: seed)
        .onChange(of: rule) { _, _ in seed() }
        .onChange(of: focused) { previous, current in
            if previous != nil, current == nil { commitText() }
        }
    }

    private func seed() {
        find = rule.find
        replaceWith = rule.replaceWith
    }

    private func commitText() {
        guard find != rule.find || replaceWith != rule.replaceWith else { return }
        var edited = rule
        edited.find = find
        edited.replaceWith = replaceWith
        onCommit(edited)
    }

    private func commit(isEnabled: Bool? = nil,
                        wholeWordOnly: Bool? = nil,
                        caseSensitive: Bool? = nil) {
        var edited = rule
        // The text drafts ride along, so flipping a toggle mid-edit does not discard what
        // is already typed in the fields.
        edited.find = find
        edited.replaceWith = replaceWith
        if let isEnabled { edited.isEnabled = isEnabled }
        if let wholeWordOnly { edited.wholeWordOnly = wholeWordOnly }
        if let caseSensitive { edited.caseSensitive = caseSensitive }
        onCommit(edited)
    }
}
