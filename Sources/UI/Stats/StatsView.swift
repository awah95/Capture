import SwiftUI

/// The full stats page, spec §10, §11.2 and §11.3.
///
/// Four groups, in the order the plan names them: **speed and time saved**, **volume over
/// time**, **where the words go**, **quality signals**. One hero figure for the whole view
/// — time saved — with every other number at caption or body size, because a page with
/// four heroes has none.
///
/// Charts are the hand-rolled `Canvas` ones from `Sources/UI/Stats/Charts`, not Apple's
/// `Charts`: a data-end rounded at the top and square at the baseline is not expressible
/// through `BarMark`, a tooltip has to fire on a zero-height mark, and the geometry has to
/// be a pure function to be unit-tested. See `docs/wiring/task21-wiring.md` §9.
///
/// Nothing here polls. `refresh()` runs from `.task` when the pane appears and when the
/// window changes; a dictation finishing while the page is open is the composition root's
/// event to forward (spec §15 — no timers, ~0 % idle CPU).
struct StatsView: View {
    let model: StatsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if model.isLoading && !model.hasRecords && model.loadFailure == nil {
                    loadingState
                } else if let failure = model.loadFailure {
                    // A read failure is reported, never shown as "no dictations yet": the
                    // two are different facts and only one of them is good news.
                    EmptyState(message: "The dictation log could not be read.\n\(failure)",
                               symbol: "exclamationmark.triangle")
                        .frame(minHeight: 280)
                        .capturSurface()
                } else if model.showsTooFewDictations {
                    // Spec §10.6, verbatim.
                    EmptyState.tooFewDictationsForStats
                        .frame(minHeight: 280)
                        .capturSurface()
                } else {
                    speedGroup
                    volumeGroup
                    destinationGroup
                    qualityGroup
                    healthGroup
                }
            }
            .frame(maxWidth: 1_180, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(CapturPalette.canvas)
        // `.task` and not `.onAppear`: the load is async, and `.task` cancels with the view
        // instead of outliving it.
        .task { await model.refresh() }
        .sheet(isPresented: Binding(
            get: { model.typingTest != nil },
            set: { presented in
                guard !presented else { return }
                Task { await model.endTypingTest() }
            })
        ) {
            if let session = model.typingTest {
                TypingTestView(
                    session: session,
                    onFinished: { Task { await model.refresh() } },
                    onClose: { Task { await model.endTypingTest() } })
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            CapturPageHeader(
                title: "Analytics",
                subtitle: "A clear view of your dictation habits, speed, and system health."
            )

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing analytics")
                }

                Picker("Period", selection: Binding(
                    get: { model.window },
                    set: { window in Task { await model.select(window) } })
                ) {
                    ForEach(StatsViewModel.Window.allCases) { window in
                        Text(window.title).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 248)
            }
        }
    }

    private var loadingState: some View {
        CapturCard("Reading your activity", symbol: "chart.xyaxis.line") {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Calculating real totals from your local capture history…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 180, alignment: .center)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 1 — Speed and time saved

    private var speedGroup: some View {
        group("Speed and time saved", symbol: "speedometer") {
            adaptivePair {
                StatTile(title: "Time saved · \(model.window.title.lowercased())",
                         caption: model.baselineCaption) {
                    if let figure = model.heroFigure {
                        HeroFigure(value: figure, detail: model.heroDetail)
                    } else {
                        // Spec §10.6, verbatim, with the button inline. Not "0m", not a dash:
                        // the prompt IS the state.
                        EmptyState.noTypingBaseline(runTest: model.startTypingTest)
                            .frame(minHeight: 116, maxHeight: 150)
                    }
                }
            } trailing: {
                figureGrid(model.speedFigures)
            }
        }
    }

    // MARK: 2 — Volume over time

    private var volumeGroup: some View {
        group("Volume over time", symbol: "chart.bar.xaxis") {
            VolumeChart(
                title: "Words per \(model.bucketUnit)",
                buckets: model.buckets,
                unit: model.bucketUnit)
        }
    }

    // MARK: 3 — Where the words go

    private var destinationGroup: some View {
        group("Where the words go", symbol: "arrow.up.right.square") {
            adaptivePair {
                ShareChart(title: "By app", shares: model.appShares)
            } trailing: {
                ShareChart(title: "By mode", shares: model.modeShares)
            }
        }
    }

    // MARK: 4 — Quality signals

    private var qualityGroup: some View {
        group("Quality signals", symbol: "waveform.path.ecg") {
            StatTile(
                title: "How the pipeline is behaving",
                caption: "Retry rate and spend cover every record. Recording length covers "
                    + "every record with measured audio, including cancelled or failed "
                    + "captures. Mode changes, wait time, and partial failures cover "
                    + "dictations that reached the cursor."
            ) {
                if model.qualitySignals.isEmpty {
                    // Zero out of zero is not 0 %. Nothing in the window means nothing to
                    // report, and saying so is the honest version of a grid of zeroes.
                    Text("Nothing in this window.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    figures(model.qualitySignals)
                }
            }

            if !model.usageBreakdown.isEmpty {
                StatTile(
                    title: "Model usage by provider and model",
                    caption: "Transcription audio is additive: a live pass followed by a final "
                        + "batch recheck counts both. OpenRouter costs are provider-reported; "
                        + "Groq transcription costs are estimates."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.usageBreakdown) { row in
                            usageRow(row)
                        }
                    }
                }
            }
        }
    }

    private func usageRow(_ row: UsageBreakdownRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(providerTitle(row.providerID)) · \(row.modelID)")
                    .font(.caption)
                Text(usageDetail(row))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 2) {
                Text(StatsFormat.money(NSDecimalNumber(decimal: row.costUSD).doubleValue))
                    .font(.caption.monospacedDigit())
                if row.unknownCostCount > 0 {
                    Text("+ \(row.unknownCostCount) unknown")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .capturSurface(radius: 8)
    }

    private func providerTitle(_ id: String) -> String {
        if id == "legacy" { return "Legacy" }
        if let provider = TranscriptionProvider(rawValue: id) {
            return provider.usageDisplayName
        }
        if let choice = ModeCleanupChoice(rawValue: id), let model = LocalCleanupRegistry.builtIn.model(choice) {
            return model.name
        }
        return RefinementProviderID(rawValue: id)?.title ?? id
    }

    private func usageDetail(_ row: UsageBreakdownRow) -> String {
        if row.stage == .transcription {
            var parts = [
                "\(row.requestCount) pass\(row.requestCount == 1 ? "" : "es")",
                StatsFormat.duration(row.audioSeconds) + " audio",
                "\(row.outputWordCount) words",
            ]
            if !row.transcriptionPaths.isEmpty {
                parts.append(row.transcriptionPaths.map(pathTitle).joined(separator: " + "))
            }
            if let p50 = row.latencyP50Ms, let p95 = row.latencyP95Ms {
                parts.append("latency p50 \(p50) ms / p95 \(p95) ms")
            }
            if row.retryCount > 0 { parts.append("\(row.retryCount) retried") }
            if row.failureCount > 0 { parts.append("\(row.failureCount) unsuccessful") }
            return parts.joined(separator: " · ")
        }

        return "\(row.stage.rawValue.capitalized) · \(row.requestCount) request"
            + (row.requestCount == 1 ? "" : "s")
            + " · \(row.promptTokens) in / \(row.completionTokens) out"
            + (row.reasoningTokens > 0 ? " · \(row.reasoningTokens) thinking" : "")
    }

    private func pathTitle(_ path: DictationTranscriptionPath) -> String {
        switch path {
        case .batchSegment: return "batch"
        case .liveStream: return "live"
        case .finalBatchRecheck: return "final recheck"
        case .retryBatch: return "retry batch"
        }
    }

    // MARK: 5 — Performance and health

    /// Resource use, stability and where the latency goes.
    ///
    /// Covers every run and every dictation rather than the selected window, and says so:
    /// §15 wants at least twenty samples behind a p50, and a quiet week windowed down to
    /// three dictations would produce percentiles that look authoritative and are not.
    ///
    /// Nothing here leaves the machine. Spec §16 — "nothing is sent anywhere except
    /// Groq" — so this is the app measuring itself for the person using it, not
    /// telemetry.
    private var healthGroup: some View {
        group("Performance and health", symbol: "gauge") {
            VStack(alignment: .leading, spacing: 12) {
                adaptivePair {
                    StatTile(
                        title: "Resource use",
                        caption: "Sampled at launch and around each dictation — never on a "
                            + "timer, so measuring this costs nothing when idle."
                    ) {
                        if model.resourceFigures.isEmpty {
                            Text("No sessions recorded yet.")
                                .font(.caption).foregroundStyle(.tertiary)
                        } else {
                            figures(model.resourceFigures)
                        }
                    }
                } trailing: {
                    StatTile(
                        title: "Stability",
                        caption: "A run that never reached shutdown is counted as unexpected, "
                            + "whether it crashed or was force-quit."
                    ) {
                        if model.stabilityFigures.isEmpty {
                            Text("No completed runs recorded yet.")
                                .font(.caption).foregroundStyle(.tertiary)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                figures(model.stabilityFigures)
                                if !model.crashRows.isEmpty { crashList }
                            }
                        }
                    }
                }

                StatTile(
                    title: "Latency",
                    caption: model.latencyCaveat
                        ?? "Key release to text on screen, across every recorded dictation."
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.latencyFigures.isEmpty {
                            figures(model.latencyFigures)
                        }
                        if !model.health.stages.isEmpty { stageBreakdown }
                    }
                }
            }
        }
    }

    /// Where the time actually goes, stage by stage.
    ///
    /// Arming is listed with the others but marked as not part of the wait, because it
    /// happens before the user speaks. Folding it into the perceived total would overstate
    /// the delay; leaving it off the page entirely would hide the largest single number
    /// and the one whose audio is lost.
    private var stageBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.health.stages) { stage in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(stage.name).font(.caption)
                            if !stage.isOnPerceivedPath {
                                Text("before you speak")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(stage.detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Text("\(stage.p50Ms) ms")
                        .font(.caption).monospacedDigit()
                    Text("p95 \(stage.p95Ms)")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .capturSurface(radius: 8)
            }
        }
    }

    /// One row per crash macOS wrote a report for.
    ///
    /// Four short redacted fields, never the report itself: a crash log is a memory dump
    /// in prose, and §16 promises the API key is never in one.
    private var crashList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent crashes")
                .font(.caption).fontWeight(.semibold)
            ForEach(Array(model.crashRows.enumerated()), id: \.offset) { _, crash in
                VStack(alignment: .leading, spacing: 1) {
                    Text(crash.exceptionType)
                        .font(.caption).monospaced()
                    if !crash.terminationReason.isEmpty {
                        Text(crash.terminationReason)
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !crash.faultingSymbol.isEmpty {
                        Text("in \(crash.faultingSymbol)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(StatsFormat.date(crash.at, calendar: model.calendar))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Shared furniture

    /// A titled group of tiles. The heading is a text token at caption size — the hero is
    /// the only large figure on the page.
    private func group<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// Uses side-by-side cards when both retain a useful reading width, then falls back
    /// to a single column without relying on a fixed window width.
    private func adaptivePair<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                leading().frame(minWidth: 300)
                trailing().frame(minWidth: 300)
            }
            VStack(alignment: .leading, spacing: 12) {
                leading()
                trailing()
            }
        }
    }

    private func figureGrid(_ figures: [StatsFigure]) -> some View {
        StatTile(title: "At a glance") {
            self.figures(figures)
        }
    }

    /// Values in text tokens, never the series colour, and the label above the number so
    /// the column reads top-down at a glance.
    private func figures(_ figures: [StatsFigure]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .topLeading)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(figures) { figure in
                VStack(alignment: .leading, spacing: 3) {
                    Text(figure.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(figure.value)
                        .font(.system(size: 20, weight: .medium))
                        .monospacedDigit()
                        .tracking(-0.35)
                        .foregroundStyle(.primary)
                    if let detail = figure.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
                .capturSurface(radius: 8)
            }
        }
    }
}

// MARK: - Copy

extension StatsViewModel {

    /// The caption under the hero: which baseline the saving was measured against, and
    /// when it was measured, so a stale one is visible rather than merely old.
    var baselineCaption: String? {
        guard let baselineSummary else { return nil }
        return "Measured against \(baselineSummary.wordsPerMinute) wpm typing, "
            + "from \(StatsFormat.date(baselineSummary.measuredAt, calendar: calendar))."
    }
}
