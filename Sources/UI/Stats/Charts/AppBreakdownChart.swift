import SwiftUI

// MARK: - Shares

/// One row of "where the words go": an app (or the Other bucket) and its share of the
/// window's words.
struct WordShare: Identifiable, Equatable {
    /// `targetBundleID`, or nil for the no-frontmost-app bucket. Nil for Other too.
    let key: String?
    /// What the row is called on screen. This is the *UI's* decision — see
    /// `AppBreakdown.label(for:)`.
    let label: String
    let wordCount: Int
    let dictationCount: Int
    /// 0…1 of the window's words. Zero rather than NaN when there are no words, which is
    /// the classic division-by-zero in a share chart.
    let fraction: Double
    let isOther: Bool

    /// Stable across reloads, and cannot collide with a real bundle ID.
    var id: String {
        if isOther { return "\u{001F}other" }
        return key ?? "\u{001F}none"
    }
}

/// Turns the aggregator's per-app groups into the top few plus Other, spec §10.1.
enum AppBreakdown {

    /// Spec §10.1: "top 4 apps + Other".
    static let topCount = 4
    static let otherLabel = "Other"

    /// `StatsGroup.key` and `displayName` are both `String?` because the aggregator
    /// refuses to invent a name for a dictation with nothing in front of it. Naming that
    /// bucket is a presentation decision, so it is made here, once, and asserted in
    /// `HomeChartsTests`.
    static let noAppLabel = "No app in front"

    /// Groups arrive from `StatsAggregator` already sorted words-descending, and that
    /// order is kept: re-sorting here would be a second, subtly different total order for
    /// the same data.
    ///
    /// Zero-word groups are dropped rather than drawn: a dictation whose words the mode
    /// removed entirely is a real record, but it is not a slice of a words chart, and a
    /// row reading "0 %" invites the reader to look for a bar that is not there.
    static func shares(from groups: [StatsGroup], limit: Int = topCount) -> [WordShare] {
        let counted = groups.filter { $0.wordCount > 0 }
        let total = counted.reduce(0) { $0 + $1.wordCount }
        guard total > 0 else { return [] }

        let top = counted.prefix(limit)
        var shares = top.map { group in
            WordShare(
                key: group.key,
                label: label(for: group),
                wordCount: group.wordCount,
                dictationCount: group.dictationCount,
                fraction: Double(group.wordCount) / Double(total),
                isOther: false)
        }

        // Only when there is something in it. Five groups is four plus Other; four groups
        // is four rows and no Other, and an empty Other bucket is the off-by-one that
        // makes a chart claim a fifth app exists.
        let tail = counted.dropFirst(limit)
        if !tail.isEmpty {
            let words = tail.reduce(0) { $0 + $1.wordCount }
            shares.append(WordShare(
                key: nil,
                label: otherLabel,
                wordCount: words,
                dictationCount: tail.reduce(0) { $0 + $1.dictationCount },
                fraction: Double(words) / Double(total),
                isOther: true))
        }

        return shares
    }

    /// The recorded app name if there is one, the bundle ID if there is not, and only
    /// then a name of our own. Falling straight to "Unknown" would throw away the one
    /// identifier that lets someone work out which app it was.
    static func label(for group: StatsGroup) -> String {
        if let name = group.displayName, !name.isEmpty { return name }
        if let key = group.key, !key.isEmpty { return key }
        return noAppLabel
    }
}

// MARK: - Chart

/// Where the words go, spec §10.1 — top 4 apps plus Other.
///
/// Horizontal bars rather than a pie or a donut: the question is "which app, and roughly
/// how much more than the next one", and comparing bar lengths against a shared baseline
/// answers that; comparing arc angles does not. Single hue, ranked by share, **no
/// legend** — the row's own name is beside it, which is what a legend would have said.
///
/// Only the leading row's percentage is printed. The rest are direct comparisons against
/// the same zero, which is the axis doing its job.
struct AppBreakdownChart: View {
    let shares: [WordShare]

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: String?
    @State private var showsTable = false

    private static let rowHeight: CGFloat = 18
    private static let labelWidth: CGFloat = 92

    var body: some View {
        StatTile(
            title: "Where the words go",
            accessory: AnyView(ChartTableToggle(showsTable: $showsTable))
        ) {
            if shares.isEmpty {
                Text("Nothing yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if showsTable {
                ChartValueTable(rows: shares.map {
                    ChartValueTable.Row(label: $0.label, value: "\($0.wordCount) words")
                })
            } else {
                bars
            }
        }
    }

    private var bars: some View {
        VStack(spacing: 5) {
            ForEach(Array(shares.enumerated()), id: \.element.id) { item in
                row(item.element, rank: item.offset, isLeader: item.offset == 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Where the words go")
        .accessibilityValue(shares
            .map { "\($0.label): \(Self.percent($0.fraction))" }
            .joined(separator: ", "))
    }

    private func row(_ share: WordShare, rank: Int, isLeader: Bool) -> some View {
        HStack(spacing: 8) {
            Text(share.label)
                .font(.caption)
                // A text token, never the series colour: an app name painted in the data's
                // hue reads as another mark.
                .foregroundStyle(share.isOther ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.labelWidth, alignment: .leading)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 0)
                ZStack(alignment: .leading) {
                    // The track is the shared baseline made visible — without it a 4 %
                    // bar and a missing bar look the same.
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ChartPalette.gridline(colorScheme))
                        .frame(height: 4)

                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: min(BarChartGeometry.dataEndRadius, Self.rowHeight / 2),
                        topTrailingRadius: min(BarChartGeometry.dataEndRadius, Self.rowHeight / 2))
                        .fill(ChartPalette.fill(rank: rank, of: shares.count, scheme: colorScheme))
                        // Proportional and anchored at zero: the bar is the share of the
                        // full track, so twice the words is twice the length.
                        .frame(width: width * CGFloat(min(max(share.fraction, 0), 1)),
                               height: min(Self.rowHeight, BarChartGeometry.maximumBarWidth))
                }
                .frame(height: Self.rowHeight, alignment: .center)
                .overlay(alignment: .leading) {
                    if hovered == share.id {
                        ChartTooltip(
                            title: share.label,
                            value: "\(share.wordCount) words · \(share.dictationCount) dictations")
                            // Above the row rather than over it: a tooltip covering the
                            // bar hides the thing it is describing.
                            .offset(y: -(Self.rowHeight + 12))
                    }
                }
            }
            .frame(height: Self.rowHeight)
            // Hover on the whole row, so the shortest bar is as reachable as the longest.
            .onContinuousHover { phase in
                switch phase {
                case .active: hovered = share.id
                case .ended: hovered = nil
                }
            }

            // Direct-label the extreme only.
            Text(isLeader ? Self.percent(share.fraction) : "")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    static func percent(_ fraction: Double) -> String {
        // Rounded to a whole point: a share chart claiming 37.4 % is claiming a precision
        // the underlying word counts do not have.
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}
