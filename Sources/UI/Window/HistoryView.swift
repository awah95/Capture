import SwiftUI

/// The searchable record of everything Captur has handled.
///
/// History remains a single detail-column view. Search, filtering, playback and all
/// record actions are backed by `HistoryViewModel`; this file only defines their
/// presentation and keyboard reachability.
struct HistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel

    /// Keyboard selection is intentionally separate from expansion. Arrow-key
    /// navigation should not open every capture that it crosses.
    @State private var selection: UUID?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(minWidth: 460, minHeight: 380)
        .background(CapturPalette.canvas)
        .task {
            // Sample the destination before loading can yield and before Captur's
            // window becomes the app the user most recently worked in.
            viewModel.captureInsertionTarget()
            await viewModel.load()
        }
        .background(keyboardShortcuts)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                CapturPageHeader(
                    title: "Captures",
                    subtitle: "Find, review, and reuse anything you dictated."
                )

                if viewModel.isLoaded, totalCount > 0 {
                    captureCount
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                searchField
                chips
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 15)
    }

    private var captureCount: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(visibleCount, format: .number)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(isFiltered ? "of \(totalCount) shown" : totalCount == 1 ? "capture" : "captures")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            // Keeping search inside this pane makes its scope unambiguous. It also
            // lets the no-modifier row shortcuts yield while the field has focus.
            TextField("Search transcripts, modes, or apps", text: $viewModel.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }

            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            } else {
                Text("⌘F")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .capturSurface(inset: true, radius: 9)
    }

    /// Counts describe the full history, not the current result. A filter never
    /// disappears simply because another one was selected.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                chip(title: "All captures",
                     count: totalCount,
                     symbol: "rectangle.stack",
                     isOn: !viewModel.hasActiveScope) {
                    viewModel.clearScope()
                }

                ForEach(viewModel.modeChips) { mode in
                    chip(title: mode.title,
                         count: mode.count,
                         symbol: "wand.and.stars",
                         isOn: viewModel.modeFilter == mode.id) {
                        viewModel.modeFilter = viewModel.modeFilter == mode.id ? nil : mode.id
                    }
                }

                if !viewModel.modeChips.isEmpty && !viewModel.appChips.isEmpty {
                    Divider().frame(height: 18)
                }

                ForEach(viewModel.appChips) { app in
                    chip(title: app.title,
                         count: app.count,
                         symbol: "macwindow",
                         isOn: viewModel.appFilter == app.id) {
                        viewModel.appFilter = viewModel.appFilter == app.id ? nil : app.id
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func chip(title: String,
                      count: Int,
                      symbol: String,
                      isOn: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text(title)
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(isOn ? .primary : .tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 27)
            .foregroundStyle(isOn ? .primary : .secondary)
            .background(isOn ? CapturPalette.accent.opacity(0.16) : CapturPalette.inset,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isOn ? CapturPalette.accent.opacity(0.55) : CapturPalette.border,
                                  lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    // MARK: - List states

    @ViewBuilder
    private var content: some View {
        if !viewModel.isLoaded {
            loadingState
        } else if let error = viewModel.loadError {
            EmptyState(message: "History could not be read.\n\(error)",
                       symbol: "exclamationmark.triangle")
        } else if viewModel.hasNoDictations {
            EmptyState.noDictations
        } else if viewModel.hasNoSearchMatches {
            EmptyState.noSearchMatches
        } else {
            captureList
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading captures…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var captureList: some View {
        List(selection: $selection) {
            ForEach(viewModel.groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        rowView(row)
                            .tag(row.id)
                            .listRowInsets(EdgeInsets(top: 5, leading: 24, bottom: 5, trailing: 24))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    dayHeader(group)
                        .listRowInsets(EdgeInsets(top: 12, leading: 26, bottom: 3, trailing: 26))
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(CapturPalette.canvas)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24),
                   value: viewModel.expandedRecordID)
    }

    private func dayHeader(_ group: HistoryDayGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(group.rows.count, format: .number)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(CapturPalette.border)
                .frame(height: 0.75)
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Row

    @ViewBuilder
    private func rowView(_ row: HistoryRow) -> some View {
        let isExpanded = viewModel.expandedRecordID == row.id
        let isSelected = selection == row.id

        VStack(alignment: .leading, spacing: 0) {
            Button {
                selection = row.id
                viewModel.toggleExpansion(row.id)
            } label: {
                summary(row, isExpanded: isExpanded)
            }
            // Borderless is significant inside a macOS List: it keeps this
            // disclosure control distinct from buttons revealed beneath it.
            .buttonStyle(.borderless)
            .accessibilityHint(isExpanded ? "Collapse capture details" : "Show capture details")

            if isExpanded {
                Divider()
                    .padding(.horizontal, 15)
                expansion(row)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Keep the row as a navigable group while borderless list buttons expose
        // the disclosure and expanded actions as distinct accessibility controls.
        .accessibilityElement(children: .contain)
        .background(isSelected ? CapturPalette.accent.opacity(0.07) : CapturPalette.surface,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isSelected ? CapturPalette.accent.opacity(0.72) : CapturPalette.border,
                              lineWidth: isSelected ? 1.25 : 0.75)
                .allowsHitTesting(false)
        }
    }

    private func summary(_ row: HistoryRow, isExpanded: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            captureGlyph(row)

            VStack(alignment: .leading, spacing: 7) {
                Text(row.previewText)
                    .font(.system(size: 14, weight: .medium))
                    .lineSpacing(2)
                    .lineLimit(isExpanded ? 4 : 2)
                    .foregroundStyle(row.record.finalText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ViewThatFits(in: .horizontal) {
                    metadata(row)
                    compactMetadata(row)
                }
            }

            VStack(alignment: .trailing, spacing: 7) {
                Text("\(row.record.wordCount) words")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(height: 16)
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    private func captureGlyph(_ row: HistoryRow) -> some View {
        Image(systemName: row.isFailed ? "exclamationmark" : row.isCancelled ? "xmark" : "waveform")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(row.isFailed ? Color.red : row.isCancelled ? Color.secondary : CapturPalette.accent)
            .frame(width: 28, height: 28)
            .background(CapturPalette.inset,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(CapturPalette.border, lineWidth: 0.75)
            }
            .accessibilityHidden(true)
    }

    private func metadata(_ row: HistoryRow) -> some View {
        HStack(spacing: 7) {
            status(row)
            metadataSeparator
            Label(viewModel.timeOfDay(row.record.startedAt), systemImage: "clock")
            metadataSeparator
            Label(row.modeName, systemImage: "wand.and.stars")
            metadataSeparator
            Label(row.appName, systemImage: "macwindow")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .labelStyle(.titleAndIcon)
    }

    private func compactMetadata(_ row: HistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                status(row)
                metadataSeparator
                Label(viewModel.timeOfDay(row.record.startedAt), systemImage: "clock")
                metadataSeparator
                Label(row.modeName, systemImage: "wand.and.stars")
            }
            Label(row.appName, systemImage: "macwindow")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .labelStyle(.titleAndIcon)
    }

    private var metadataSeparator: some View {
        Circle()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 2.5, height: 2.5)
            .accessibilityHidden(true)
    }

    private func status(_ row: HistoryRow) -> some View {
        let label = row.statusLabel ?? "Inserted"
        let color: Color = row.isFailed || row.hasPartialTranscript ? .red : row.isCancelled ? .secondary : .green

        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
        }
        .foregroundStyle(row.isFailed || row.hasPartialTranscript ? color : .secondary)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Expanded record

    @ViewBuilder
    private func expansion(_ row: HistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let reason = row.failureReason {
                Label {
                    Text(reason).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if row.record.rawText != row.record.finalText, !row.record.rawText.isEmpty {
                textBlock("Original transcript", symbol: "waveform", text: row.record.rawText)
            }
            if !row.record.finalText.isEmpty {
                textBlock("Final text", symbol: "text.quote", text: row.record.finalText)
            }

            if viewModel.canPlayExpandedRow {
                audioBlock(row)
            }

            if let context = row.record.contextSummary {
                contextBlock(context)
            }

            recordDetails(row.record)
            actions(row)
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }

    private func textBlock(_ label: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .capturSurface(inset: true, radius: 9)
    }

    private func contextBlock(_ summary: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(CapturPalette.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Context used")
                    .font(.caption)
                    .fontWeight(.medium)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Only this summary was kept. Retrying uses the transcript without the original context.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .capturSurface(inset: true, radius: 9)
    }

    /// The scrubber is omitted when retention has removed the source recording.
    private func audioBlock(_ row: HistoryRow) -> some View {
        let playback = viewModel.playback?.recordID == row.id ? viewModel.playback : nil
        let duration = playback?.duration ?? 0

        return HStack(spacing: 11) {
            Button {
                viewModel.togglePlayback(row)
            } label: {
                Image(systemName: playback?.isPlaying == true ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(CapturPalette.accent.opacity(0.16), in: Circle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(CapturPalette.accent)
            .help(playback?.isPlaying == true ? "Pause" : "Play the recording")

            Slider(value: Binding(
                get: { min(playback?.position ?? 0, max(duration, 0.001)) },
                set: { viewModel.seek(to: $0) }
            ), in: 0...max(duration, 0.001))
            .disabled(duration <= 0)

            Text(Self.clock(playback?.position ?? 0) + " / " + Self.clock(clipLength(row, duration)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(10)
        .capturSurface(inset: true, radius: 9)
        .accessibilityElement(children: .contain)
    }

    /// Until AVFoundation reports the duration, the known speaking time keeps the
    /// clip label useful and stable.
    private func clipLength(_ row: HistoryRow, _ duration: TimeInterval) -> TimeInterval {
        duration > 0 ? duration : row.record.speakingDuration
    }

    private func recordDetails(_ record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Processing", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(costLabel(record))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 8)],
                      alignment: .leading,
                      spacing: 8) {
                timing("Capture", record.timings.captureMs)
                timing("Transcribe", record.timings.whisperMs)
                timing("Refine", record.timings.llmMs)
                timing("Insert", record.timings.insertMs)
                timing("Total", record.timings.totalMs)
            }
        }
        .padding(11)
        .capturSurface(inset: true, radius: 9)
    }

    private func timing(_ label: String, _ milliseconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(Self.durationLabel(milliseconds))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func costLabel(_ record: DictationRecord) -> String {
        if record.usageEntries == nil {
            guard record.estimatedCostUSD > 0 else { return "Cost unavailable" }
            return "Estimated \(Self.dollar(record.estimatedCostUSD))"
        }

        let known = record.totalTrackedCostUSD
        let unknown = record.unknownTrackedCostCount
        if unknown > 0 {
            return known > 0
                ? "\(Self.dollar(known)) + \(unknown) unknown"
                : unknown == 1 ? "1 unknown charge" : "\(unknown) unknown charges"
        }
        return Self.dollar(known)
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(_ row: HistoryRow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                actionButtons(row)
                Spacer(minLength: 8)
                deleteControls(row)
            }

            VStack(alignment: .leading, spacing: 9) {
                compactActionButtons(row)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    deleteControls(row)
                }
            }
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionButtons(_ row: HistoryRow) -> some View {
        if row.canReinsert {
            Button {
                Task { await viewModel.reinsert(row) }
            } label: {
                Label(reinsertTitle, systemImage: "arrow.turn.down.left")
            }
            .buttonStyle(.borderless)
            .tint(CapturPalette.accent)
            .help("Insert this text into the app that was in front before Captures opened")
        }

        Button {
            viewModel.copy(row)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderless)

        if row.canRetryTranscription {
            Button("Retry transcription") {
                Task { await viewModel.retryTranscription(row) }
            }
            .buttonStyle(.borderless)
            .help("Re-transcribe from the saved recording")
        }

        if row.canRetryMode {
            Button("Retry mode") {
                Task { await viewModel.retryMode(row) }
            }
            .buttonStyle(.borderless)
            .help("Run the mode again on the original transcript")
        }
    }

    @ViewBuilder
    private func compactActionButtons(_ row: HistoryRow) -> some View {
        if row.canReinsert {
            Button {
                Task { await viewModel.reinsert(row) }
            } label: {
                Label(reinsertTitle, systemImage: "arrow.turn.down.left")
            }
            .buttonStyle(.borderless)
            .tint(CapturPalette.accent)
            .help("Insert this text into the app that was in front before Captures opened")
        }

        HStack(spacing: 8) {
            Button {
                viewModel.copy(row)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)

            if row.canRetryTranscription {
                Button("Retry transcription") {
                    Task { await viewModel.retryTranscription(row) }
                }
                .buttonStyle(.borderless)
            }
        }

        if row.canRetryMode {
            Button("Retry mode") {
                Task { await viewModel.retryMode(row) }
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func deleteControls(_ row: HistoryRow) -> some View {
        if viewModel.pendingDeleteID == row.id {
            Text("Delete this capture?")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel") { viewModel.cancelDelete() }
                .buttonStyle(.borderless)
            Button("Delete") { Task { await viewModel.confirmDelete() } }
                .buttonStyle(.borderless)
                .tint(.red)
        } else {
            Button(role: .destructive) {
                viewModel.requestDelete(row.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this capture")
            .accessibilityLabel("Delete this capture")
        }
    }

    private var reinsertTitle: String {
        guard let name = viewModel.insertionTarget?.name else { return "Insert" }
        return "Insert into \(name)"
    }

    // MARK: - Keyboard

    /// Hidden buttons carry pane-level shortcuts. Return, Space and Command-Delete
    /// all yield to the search field so text editing never triggers a record action.
    private var keyboardShortcuts: some View {
        let row = selectedRow

        return ZStack {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)

            Button("") { if let row { Task { await viewModel.reinsert(row) } } }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(searchFocused || row?.canReinsert != true)

            Button("") { if let row { viewModel.togglePlayback(row) } }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(searchFocused || row == nil)

            Button("") { if let row { viewModel.requestDelete(row.id) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(searchFocused || row == nil)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var selectedRow: HistoryRow? {
        guard let selection else { return nil }
        return viewModel.groups.lazy.flatMap(\.rows).first { $0.id == selection }
    }

    private var visibleCount: Int {
        viewModel.groups.reduce(0) { $0 + $1.rows.count }
    }

    private var totalCount: Int {
        viewModel.modeChips.reduce(0) { $0 + $1.count }
    }

    private var isFiltered: Bool {
        viewModel.hasActiveScope || !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private static func durationLabel(_ milliseconds: Int) -> String {
        if milliseconds >= 1_000 {
            return String(format: "%.2f s", Double(milliseconds) / 1_000)
        }
        return "\(milliseconds) ms"
    }

    private static func dollar(_ amount: Double) -> String {
        if amount == 0 { return "$0" }
        if amount < 0.01 { return String(format: "$%.4f", amount) }
        return String(format: "$%.2f", amount)
    }
}
