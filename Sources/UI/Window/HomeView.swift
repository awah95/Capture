import AppKit
import SwiftUI

// MARK: - Layout

/// The 60/40 split, spec §10.1 — as arithmetic, so it can be asserted.
///
/// `HSplitView` was the obvious choice and is the wrong one: it makes the proportion a
/// user-draggable preference that AppKit then persists, so the screen the spec describes
/// is only what someone sees the first time. A computed split is the same layout every
/// time, and the numbers are testable.
enum HomeLayout {

    /// Spec §10.1: "Left (≈60%)… Right (≈40%)".
    static let recentFraction: CGFloat = 0.6
    /// Below this the recent rows stop being readable — a preview truncated to three
    /// words is not a preview.
    static let minimumRecentWidth: CGFloat = 320
    /// Below this the hero figure wraps and the bars stop being comparable.
    static let minimumStatsWidth: CGFloat = 260

    /// Splits `width` between the two panes.
    ///
    /// The stats column defends its minimum first: it holds fixed-size figures and charts
    /// that stop meaning anything when squeezed, whereas the recent list degrades
    /// gracefully by truncating. When the window is too narrow for both minimums the
    /// proportion is honoured instead — the panes get smaller together rather than one of
    /// them being handed a negative width.
    static func split(width: CGFloat) -> (recent: CGFloat, stats: CGFloat) {
        guard width > 0 else { return (0, 0) }
        guard width >= minimumRecentWidth + minimumStatsWidth else {
            let recent = width * recentFraction
            return (recent, width - recent)
        }
        let recent = min(max(width * recentFraction, minimumRecentWidth),
                         width - minimumStatsWidth)
        return (recent, width - recent)
    }
}

// MARK: - Home

/// The daily workspace: period metrics, a contribution map, grounded insights and the
/// latest captures. All figures come from `HomeViewModel`'s record-log snapshot.
struct HomeView: View {
    let model: HomeViewModel

    @State private var expanded: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let failure = model.loadFailure {
                    Label("Captur couldn't refresh the activity log. \(failure)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .capturSurface(inset: true, radius: 9)
                }

                if !model.hasLoadedSuccessfully && model.loadFailure == nil {
                    ProgressView("Reading your activity…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if model.hasRecords {
                    metricRow
                    dashboard
                    recentCard
                } else if model.loadFailure == nil {
                    EmptyState.noDictations
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .capturSurface()
                }
            }
            .padding(24)
            .frame(maxWidth: 1260, alignment: .leading)
        }
        .background(CapturPalette.canvas)
        // `.task` and not `.onAppear`: the load is async, and `.task` cancels with the
        // view instead of outliving it. Nothing here polls — spec §15.
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            CapturPageHeader(
                title: "Overview",
                subtitle: "A clear view of your dictation rhythm and recent work.")
            if model.currentStreakDays > 0 {
                Label(streakLabel, systemImage: "flame.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .capturSurface(inset: true, radius: 7)
            }
            if let showFullStats = model.actions.showFullStats {
                Button("Open analytics", systemImage: "chart.xyaxis.line", action: showFullStats)
                    .controlSize(.regular)
            }
        }
    }

    private var streakLabel: String {
        let days = model.currentStreakDays
        return days == 1 ? "1 day streak" : "\(days) day streak"
    }

    private var metricRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { metricCards }
            VStack(spacing: 10) { metricCards }
        }
    }

    @ViewBuilder
    private var metricCards: some View {
        OverviewMetricCard(
            title: "Dictations",
            symbol: "waveform",
            value: model.monthSummary.dictationCount.formatted(),
            detail: model.dictationsComparison.accessibilityDescription)
        OverviewMetricCard(
            title: "Words captured",
            symbol: "text.word.spacing",
            value: model.monthSummary.totalWords.formatted(),
            detail: model.wordsComparison.accessibilityDescription)
        if let figure = model.heroFigure {
            OverviewMetricCard(
                title: "Estimated time saved",
                symbol: "clock.arrow.circlepath",
                value: figure,
                detail: model.timeSavedComparison?.accessibilityDescription
                    ?? "A previous-period comparison isn't available")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Estimated time saved", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text("Measure your baseline")
                    .font(.system(size: 17, weight: .semibold))
                Button("Run typing test", action: model.actions.startTypingTest)
                    .controlSize(.small)
                Text("Required for an honest estimate")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .capturSurface()
        }
    }

    private var dashboard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                activityColumn.frame(minWidth: 560)
                insightCard.frame(width: 280)
            }
            VStack(alignment: .leading, spacing: 14) {
                activityColumn
                insightCard
            }
        }
    }

    private var activityColumn: some View {
        VStack(spacing: 14) {
            ActivityHeatmap(grid: model.activityGrid)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    WordsPerDayChart(days: model.week)
                    AppBreakdownChart(shares: model.wordShares)
                }
                VStack(spacing: 14) {
                    WordsPerDayChart(days: model.week)
                    AppBreakdownChart(shares: model.wordShares)
                }
            }
            if model.monthSummary.partialFailureCount > 0 {
                Label(
                    "\(model.monthSummary.partialFailureCount) dictation"
                        + (model.monthSummary.partialFailureCount == 1 ? "" : "s")
                        + " lost part of the audio.",
                    systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var insightCard: some View {
        CapturCard("Insights", symbol: "sparkles", caption: "This month through today") {
            if model.insights.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your patterns will appear here")
                        .font(.callout.weight(.medium))
                    Text("Complete a few dictations and Captur will surface only patterns supported by your activity.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.insights.enumerated()), id: \.element.id) { index, insight in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(insight.eyebrow, systemImage: insight.symbol)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(CapturPalette.accent)
                            Text(insight.title).font(.callout.weight(.semibold))
                            Text(insight.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 11)
                        if index < model.insights.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private var recentCard: some View {
        CapturCard("Recent captures", symbol: "text.badge.checkmark",
                   caption: model.recent.isEmpty ? nil : "Latest \(model.recent.count) captures · independent of the analytics period") {
            if model.recent.isEmpty {
                EmptyState.noDictations.frame(minHeight: 130)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.recent) { row in
                        RecentRow(
                            row: row,
                            relativeTime: model.relativeTime(of: row.startedAt),
                            isExpanded: expanded == row.id,
                            actions: model.actions,
                            toggle: { expanded = expanded == row.id ? nil : row.id })
                        if row.id != model.recent.last?.id { Divider().opacity(0.55) }
                    }
                }
                .capturSurface(inset: true, radius: 8)
            }
        }
    }
}

private struct OverviewMetricCard: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .monospacedDigit().tracking(-0.8)
            Text(detail)
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .capturSurface()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Recent row

/// One row of the recent list, spec §10.1: mode glyph, first line of the final text,
/// target app, relative time — and, expanded, raw vs final plus timings.
///
/// The expanded actions are whatever the composition root handed over. A button for a nil
/// closure is not rendered, rather than rendered and dead: History (Task 22) owns
/// playback, retry and delete for real.
private struct RecentRow: View {
    let row: RecentDictation
    let relativeTime: String
    let isExpanded: Bool
    let actions: HomeActions
    let toggle: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: row.mode?.symbol ?? "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .help(row.mode?.name ?? row.modeID)

                    Text(row.preview ?? "No transcript")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(row.preview == nil ? .tertiary : .primary)

                    if row.previewSource == .raw {
                        // The final text is missing, so what is on screen is the raw
                        // transcript. Saying which is the difference between honesty and
                        // a row that looks complete.
                        tag("raw")
                    }
                    if let badge = row.badge {
                        tag(badge)
                    }

                    Spacer(minLength: 8)

                    if let app = row.appLabel {
                        Text(app)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(relativeTime)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedDetail
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isExpanded ? AnyShapeStyle(CapturPalette.surface) : AnyShapeStyle(.clear))
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .lineLimit(1)
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.record.rawText != row.record.finalText, !row.record.rawText.isEmpty {
                labelled("Heard", row.record.rawText)
            }
            if !row.record.finalText.isEmpty {
                labelled("Inserted", row.record.finalText)
            }

            Text(Self.timings(row.record))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                Button(didCopy ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        row.record.finalText.isEmpty ? row.record.rawText : row.record.finalText,
                        forType: .string)
                    didCopy = true
                }
                if let play = actions.playAudio, row.record.audioFileName != nil {
                    Button("Play") { play(row.record) }
                }
                if let retry = actions.retry {
                    Button("Retry") { retry(row.id) }
                }
                if let delete = actions.delete {
                    Button("Delete") { delete(row.id) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.leading, 24)
    }

    private func labelled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whole milliseconds, as the record stores them. Speaking time and the wait
    /// afterwards are shown separately because they are the two halves of the time-saved
    /// arithmetic (§11.2), and adding them together is how that number gets halved.
    private static func timings(_ record: DictationRecord) -> String {
        let waited = max(0, record.timings.totalMs - record.timings.captureMs)
        return "\(record.wordCount) words · spoke \(record.timings.captureMs) ms · "
            + "waited \(waited) ms"
    }
}
