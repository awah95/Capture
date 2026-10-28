import SwiftUI

// MARK: - Palette

/// The colour and line rules every chart in this app obeys, spec §11.3.
///
/// Two decisions are worth spelling out because both are easy to get wrong in a way that
/// still "works":
///
/// 1. **Single-hue sequential, no legend.** Every chart on Home is one series — words —
///    so a categorical palette would be encoding rank in hue, which means nothing, and a
///    legend would be a key to a mapping the reader can already see. Rank is encoded in
///    one thing only: how much of the accent colour a mark carries.
/// 2. **Dark mode has its own ramp, not an inverted light one.** Flipping the light steps
///    would put the FAINTEST step at the top of the dark ramp and, worse, leave the
///    bottom of it at 30 % accent over a near-black surface, where it stops being a mark
///    and becomes a smudge. The dark ramp is therefore shorter and its floor is lifted:
///    same hue, chosen against the surface it is actually drawn on.
enum ChartPalette {

    /// Opacity of the accent colour, most to least prominent. Five steps because the
    /// longest series here is four apps plus Other.
    static let lightSteps: [Double] = [1.0, 0.78, 0.58, 0.42, 0.30]

    /// Deliberately not `lightSteps.reversed()` and deliberately not the same numbers:
    /// less range, higher floor. `HomeChartsTests` asserts both.
    static let darkSteps: [Double] = [0.92, 0.80, 0.68, 0.56, 0.46]

    static func steps(for scheme: ColorScheme) -> [Double] {
        scheme == .dark ? darkSteps : lightSteps
    }

    /// `rank` 0 is the largest value. Out-of-range ranks clamp rather than trap: a
    /// series longer than the ramp is a design question, not a crash.
    static func opacity(rank: Int, of count: Int, scheme: ColorScheme) -> Double {
        let steps = steps(for: scheme)
        guard count > 1 else { return steps[0] }
        return steps[min(max(rank, 0), steps.count - 1)]
    }

    static func fill(rank: Int, of count: Int, scheme: ColorScheme) -> Color {
        CapturPalette.accent.opacity(opacity(rank: rank, of: count, scheme: scheme))
    }

    /// Hairline, solid, recessive — a reference the eye can use and then stop seeing.
    /// Lifted in dark mode for the same reason the series floor is: the same alpha over
    /// a dark surface reads as nothing.
    static func gridline(_ scheme: ColorScheme) -> Color {
        CapturPalette.border.opacity(scheme == .dark ? 0.82 : 0.72)
    }

    /// Gridlines are drawn at this width in points. Sub-pixel on every Mac display this
    /// app supports, which is what "hairline" means.
    static let gridlineWidth: CGFloat = 0.5
}

// MARK: - Tile

/// One titled block in Home's stats column.
///
/// The title and any caption are `Text` tokens — never the series colour. A label
/// painted in the data's hue reads as another mark, and the reader then has to work out
/// which coloured things are values and which are words.
struct StatTile<Content: View>: View {
    let title: String
    var caption: String?
    /// A control that belongs to this tile's header, e.g. the values-table toggle.
    var accessory: AnyView?
    private let content: Content

    init(
        title: String,
        caption: String? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.caption = caption
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                accessory
            }

            content

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .capturSurface(inset: true, radius: 11)
    }
}

// MARK: - Hero figure

/// The one hero figure per view, spec §11.3: ≥ 48 pt, **body sans**.
///
/// `design: .default` is the point of the `.system` call — the figure is the body face at
/// a large size, not a display or rounded or monospaced one. A different face at 48 pt
/// reads as a logo; the same face reads as a number that matters.
struct HeroFigure: View {
    let value: String
    var detail: String?

    static let pointSize: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: Self.pointSize, weight: .medium, design: .default))
                .monospacedDigit()
                .tracking(-1.4)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tooltip

/// The hover readout, spec §11.3: "hover tooltip on every mark".
///
/// Positioned by the caller against the mark it describes, and clamped inside the chart
/// so a tooltip on the last bar does not hang off the pane.
struct ChartTooltip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(CapturPalette.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(CapturPalette.border, lineWidth: 0.75))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

// MARK: - Values table

/// Spec §11.3: "a table view available for every chart."
///
/// Not a `Table` — these are two-column readouts of at most seven rows, and a real table
/// view would bring sorting and selection nobody asked for. What the rule is protecting
/// is the ability to read the exact numbers without a mouse, and this does that.
struct ChartValueTable: View {
    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label + "\u{001F}" + value }
    }

    let rows: [Row]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.value)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .font(.caption)
                .padding(.vertical, 6)
                if row.id != rows.last?.id {
                    Divider().opacity(0.4)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The small header button that swaps a chart for its values table.
struct ChartTableToggle: View {
    @Binding var showsTable: Bool

    var body: some View {
        Button {
            showsTable.toggle()
        } label: {
            Image(systemName: showsTable ? "chart.bar" : "tablecells")
                .imageScale(.small)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .help(showsTable ? "Show the chart" : "Show the values")
        .accessibilityLabel(showsTable ? "Show the chart" : "Show the values")
    }
}
