import SwiftUI

/// A titled "share of the words" chart, spec §11.3.
///
/// The same chart `AppBreakdownChart` (Task 21) draws for Home, with the title as a
/// parameter — the stats page needs it twice, once for apps and once for modes, and the
/// two groups cannot share a fixed heading. It is built on exactly the same primitives
/// (`StatTile`, `ChartPalette`, `ChartTooltip`, `ChartValueTable`, `BarChartGeometry`'s
/// mark constants) and consumes the same `WordShare` values from `AppBreakdown.shares`, so
/// the two charts cannot drift in anything but their heading.
///
/// **This should replace `AppBreakdownChart` outright.** It is not done here only because
/// that file belongs to a merged task and this branch may not modify it; see
/// `docs/wiring/task26-wiring.md`. The follow-up is a deletion, not a rewrite.
///
/// Horizontal bars rather than a pie: the question is "which one, and roughly how much
/// more than the next", and comparing lengths against a shared baseline answers that where
/// comparing arc angles does not. Single hue, ranked by share, **no legend** — the row's
/// own name is beside it, which is what a legend would have said.
struct ShareChart: View {
    let title: String
    let shares: [WordShare]
    /// Shown in place of the bars when there is nothing to draw. Never "0 %" rows.
    var emptyMessage = "Nothing yet."

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: String?
    @State private var showsTable = false

    private static let rowHeight: CGFloat = 18
    private static let labelWidth: CGFloat = 120

    var body: some View {
        StatTile(
            title: title,
            accessory: AnyView(ChartTableToggle(showsTable: $showsTable))
        ) {
            if shares.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if showsTable {
                ChartValueTable(rows: shares.map {
                    ChartValueTable.Row(
                        label: $0.label,
                        value: "\($0.wordCount) words · \(AppBreakdownChart.percent($0.fraction))")
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
        .accessibilityLabel(title)
        .accessibilityValue(shares
            .map { "\($0.label): \(AppBreakdownChart.percent($0.fraction))" }
            .joined(separator: ", "))
    }

    private func row(_ share: WordShare, rank: Int, isLeader: Bool) -> some View {
        HStack(spacing: 8) {
            Text(share.label)
                // A text token, never the series colour: a name painted in the data's hue
                // reads as another mark.
                .font(.caption)
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
            Text(isLeader ? AppBreakdownChart.percent(share.fraction) : "")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
