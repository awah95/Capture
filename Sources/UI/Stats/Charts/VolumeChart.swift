import SwiftUI

// MARK: - Series

/// One mark of the volume-over-time chart: a day, a week or a month of words.
///
/// The sibling of `WordsPerDay` (Task 21), which is a fixed seven-day week for Home. This
/// one spans an arbitrary window, which is what the stats page needs and what makes the
/// bucket size a decision rather than a constant.
struct VolumeBucket: Identifiable, Equatable {
    let start: Date
    let wordCount: Int
    let dictationCount: Int
    /// The axis label, short enough to sit under a bar.
    let label: String
    /// The tooltip and values-table label.
    let longLabel: String

    var id: Date { start }
}

/// Builds the volume series for a window, spec §11.3.
enum VolumeSeries {

    enum Bucket: Equatable {
        case day
        case week
        case month

        var component: Calendar.Component {
            switch self {
            case .day: return .day
            case .week: return .weekOfYear
            case .month: return .month
            }
        }
    }

    /// A window of at most this many days is drawn a day at a time.
    ///
    /// Past it, 300 points of chart would hold a bar every 0.8 pt — narrower than the 2 pt
    /// surface gap, so the marks would merge into a block. Rolling up is the honest
    /// alternative to drawing marks nobody can distinguish.
    static let dailyLimitDays = 45
    /// Past this, weekly bars are in the same trouble, so the series rolls up to months.
    static let weeklyLimitDays = 400

    static func bucket(spanningDays days: Int) -> Bucket {
        if days <= dailyLimitDays { return .day }
        if days <= weeklyLimitDays { return .week }
        return .month
    }

    /// Zero-filled buckets covering `interval`, ascending.
    ///
    /// **Zero-filled deliberately.** `StatsSummary.daily` omits days with nothing in them
    /// — a chart decides its own x-domain, and this is that decision. A window drawn with
    /// only its non-empty days silently changes what the reader is comparing: a quiet
    /// fortnight would look like a busy one with fewer bars.
    ///
    /// Day steps go through `Calendar`, never through 86 400 seconds — the day a region
    /// springs forward is 23 hours long, and second arithmetic loses it.
    static func buckets(
        in interval: DateInterval,
        calendar: Calendar,
        from daily: [StatsDay]
    ) -> [VolumeBucket] {
        let start = calendar.startOfDay(for: interval.start)
        guard interval.end > start else { return [] }

        let spanDays = calendar.dateComponents([.day], from: start, to: interval.end).day ?? 0
        let bucket = bucket(spanningDays: max(spanDays, 1))
        let byDay = Dictionary(daily.map { ($0.dayStart, $0) }, uniquingKeysWith: { first, _ in first })

        // Accumulate day by day and key by the bucket the day falls in, so a partial
        // first or last bucket is still whole in the data even though it is short in time.
        var totals: [Date: (words: Int, dictations: Int)] = [:]
        var order: [Date] = []
        var cursor = start
        while cursor < interval.end {
            let key = bucketStart(of: cursor, bucket: bucket, calendar: calendar)
            if totals[key] == nil {
                totals[key] = (0, 0)
                order.append(key)
            }
            if let day = byDay[cursor] {
                totals[key]?.words += day.wordCount
                totals[key]?.dictations += day.dictationCount
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor
            else { break }
            cursor = next
        }

        let labels = Labels(bucket: bucket, calendar: calendar)
        return order.map { key in
            let total = totals[key] ?? (0, 0)
            return VolumeBucket(
                start: key,
                wordCount: total.words,
                dictationCount: total.dictations,
                label: labels.short(key),
                longLabel: labels.long(key))
        }
    }

    private static func bucketStart(
        of day: Date,
        bucket: Bucket,
        calendar: Calendar
    ) -> Date {
        guard bucket != .day else { return day }
        return calendar.dateInterval(of: bucket.component, for: day)?.start ?? day
    }

    /// One formatter per series rather than one per bucket: `DateFormatter` construction
    /// dominates the cost of building a year of marks.
    private struct Labels {
        let bucket: Bucket
        private let shortFormatter: DateFormatter
        private let longFormatter: DateFormatter

        init(bucket: Bucket, calendar: Calendar) {
            self.bucket = bucket
            shortFormatter = Self.formatter(calendar: calendar)
            longFormatter = Self.formatter(calendar: calendar)
            switch bucket {
            case .day:
                shortFormatter.setLocalizedDateFormatFromTemplate("d")
                longFormatter.setLocalizedDateFormatFromTemplate("EEEE d MMM")
            case .week:
                shortFormatter.setLocalizedDateFormatFromTemplate("d MMM")
                longFormatter.setLocalizedDateFormatFromTemplate("d MMM y")
            case .month:
                shortFormatter.setLocalizedDateFormatFromTemplate("MMM")
                longFormatter.setLocalizedDateFormatFromTemplate("MMMM y")
            }
        }

        func short(_ date: Date) -> String { shortFormatter.string(from: date) }

        func long(_ date: Date) -> String {
            let body = longFormatter.string(from: date)
            return bucket == .week ? "Week of \(body)" : body
        }

        private static func formatter(calendar: Calendar) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? .current
            return formatter
        }
    }
}

// MARK: - Chart

/// Words over the selected window, spec §11.3.
///
/// Hand-rolled in a `Canvas` for the same three reasons `WordsPerDayChart` is (see its
/// doc comment and `docs/wiring/task21-wiring.md` §9), and built on the same
/// `BarChartGeometry` so the arithmetic behind both charts is one tested function rather
/// than two similar ones.
///
/// The one thing this chart does that Home's does not is **drop the per-bar axis labels
/// once there are too many to read**, keeping only the ends. That is the direct-label rule
/// doing its job at a longer window: the extreme is labelled on the mark, the ends anchor
/// the x-domain, and the y ticks carry everything else.
struct VolumeChart: View {
    let title: String
    let buckets: [VolumeBucket]
    /// What one bar covers, for the caption — "day", "week", "month".
    var unit: String = "day"

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: Int?
    @State private var showsTable = false

    /// Past this, per-bar labels stop being legible and only the ends are drawn.
    static let maximumTickLabels = 14

    private static let plotHeight: CGFloat = 168
    private static let axisLabelWidth: CGFloat = 34

    var body: some View {
        StatTile(
            title: title,
            caption: showsTable ? nil : caption,
            accessory: AnyView(ChartTableToggle(showsTable: $showsTable))
        ) {
            if buckets.isEmpty {
                Text("Nothing yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if showsTable {
                ChartValueTable(rows: buckets.map {
                    ChartValueTable.Row(label: $0.longLabel, value: "\($0.wordCount)")
                })
            } else {
                chart
            }
        }
    }

    /// The window's total, stated once rather than printed over every bar. Absent — not
    /// "0 words" — when the window is empty: a caption reporting a total of zero is a
    /// number where there is no measurement.
    private var caption: String? {
        let total = buckets.reduce(0) { $0 + $1.wordCount }
        guard total > 0 else { return nil }
        return "\(total) words · one bar is one \(unit)"
    }

    private var values: [Double] { buckets.map { Double($0.wordCount) } }

    private var chart: some View {
        HStack(alignment: .top, spacing: 6) {
            plot
            axis
        }
        .frame(height: Self.plotHeight + 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(buckets.map { "\($0.longLabel): \($0.wordCount) words" }
            .joined(separator: ", "))
    }

    private var plot: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let geometry = BarChartGeometry.make(values: values, size: proxy.size)
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    draw(geometry, in: &context, size: size)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = geometry.bar(at: point)?.index
                    case .ended: hovered = nil
                    }
                }
                .overlay(alignment: .topLeading) { tooltip(geometry, in: proxy.size) }
            }
            .frame(height: Self.plotHeight)

            labels
        }
    }

    @ViewBuilder
    private var labels: some View {
        if buckets.count <= Self.maximumTickLabels {
            HStack(spacing: 0) {
                ForEach(Array(buckets.enumerated()), id: \.element.id) { item in
                    Text(item.element.label)
                        .font(.caption2)
                        .foregroundStyle(hovered == item.offset ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            // Only the ends. The x-domain still reads, and the marks in between are
            // reached by hovering rather than by a wall of rotated text.
            HStack {
                Text(buckets.first?.label ?? "")
                Spacer(minLength: 8)
                Text(buckets.last?.label ?? "")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// Tick labels only. Values live in text tokens, never in the series colour.
    private var axis: some View {
        let geometry = BarChartGeometry.make(
            values: values, size: CGSize(width: 100, height: Self.plotHeight))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(geometry.ticks.reversed().enumerated()), id: \.offset) { item in
                Text(Self.tickLabel(item.element))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxHeight: .infinity, alignment: item.offset == 0 ? .top : .center)
            }
        }
        .frame(width: Self.axisLabelWidth, height: Self.plotHeight, alignment: .leading)
    }

    static func tickLabel(_ value: Double) -> String {
        value >= 1_000
            ? String(format: "%.1fk", value / 1_000)
            : String(Int(value.rounded()))
    }

    private func draw(
        _ geometry: BarChartGeometry,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        // Gridlines first, so the marks sit on top of them rather than under.
        for tick in geometry.ticks {
            let y = geometry.y(for: tick)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line,
                           with: .color(ChartPalette.gridline(colorScheme)),
                           lineWidth: ChartPalette.gridlineWidth)
        }

        for bar in geometry.bars where bar.rect.height > 0 {
            // The rounded end cannot exceed half the bar, or a short bar becomes a
            // lozenge and stops meeting the baseline squarely.
            let radius = min(BarChartGeometry.dataEndRadius, bar.rect.height / 2)
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: radius)
            let rank = bar.isExtreme ? 0 : (hovered == bar.index ? 1 : 2)
            context.fill(
                shape.path(in: bar.rect),
                with: .color(ChartPalette.fill(rank: rank, of: geometry.bars.count,
                                               scheme: colorScheme)))
        }

        // Direct-label the extreme only; the axis carries the rest.
        if let index = geometry.extremeIndex,
           let bar = geometry.bars.first(where: { $0.index == index }) {
            let text = Text(String(Int(bar.value.rounded())))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            context.draw(context.resolve(text),
                         at: CGPoint(x: bar.rect.midX, y: max(bar.rect.minY - 7, 6)),
                         anchor: .center)
        }
    }

    @ViewBuilder
    private func tooltip(_ geometry: BarChartGeometry, in size: CGSize) -> some View {
        if let index = hovered,
           let bucket = buckets.indices.contains(index) ? buckets[index] : nil,
           let bar = geometry.bars.first(where: { $0.index == index }) {
            ChartTooltip(
                title: bucket.longLabel,
                value: "\(bucket.wordCount) words · \(bucket.dictationCount) dictations")
                // Clamped so a tooltip on the last mark does not hang off the pane.
                .alignmentGuide(.leading) { tip in
                    -min(max(bar.rect.midX - tip.width / 2, 0), max(size.width - tip.width, 0))
                }
                .alignmentGuide(.top) { tip in
                    -max(bar.rect.minY - tip.height - 4, 0)
                }
        }
    }
}
