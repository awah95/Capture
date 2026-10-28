import SwiftUI

// MARK: - Geometry

/// Where every mark in a vertical bar chart lands, as a pure function of the values and
/// the canvas.
///
/// This type exists so the chart is regression-testable. The visualization rules are
/// arithmetic — a bar twice the value is twice the length, the domain starts at zero,
/// bars cap at 24 pt with a 2 pt surface gap, exactly one mark is direct-labelled — and
/// arithmetic that only lives inside a `Canvas` closure can be checked by eye and by
/// nothing else. `HomeChartsTests` asserts all of it; the drawing below reads the answers.
struct BarChartGeometry {

    /// One mark. `rect` is what is painted; `hitRect` is what the pointer has to reach.
    struct Bar: Identifiable, Equatable {
        let index: Int
        let value: Double
        /// Zero-height when the value is zero: nothing is painted, and nothing is faked
        /// either. A minimum-height stub would draw a day with no words as a day with a
        /// few.
        let rect: CGRect
        /// The full-height column. Hover targets the column, not the bar, so a 2-word
        /// day is as reachable as a 200-word one — that is what "a tooltip on every
        /// mark" costs.
        let hitRect: CGRect
        let isExtreme: Bool

        var id: Int { index }
    }

    /// Spec §11.3.
    static let maximumBarWidth: CGFloat = 24
    static let surfaceGap: CGFloat = 2
    /// The rounded data-end. The baseline end stays square — a bar rounded at both ends
    /// floats, and a floating bar no longer reads as measured from zero.
    static let dataEndRadius: CGFloat = 4

    let bars: [Bar]
    /// Top of the value domain. Always > 0, so nothing here can divide by zero.
    let upperBound: Double
    let baselineY: CGFloat
    /// Zero, midpoint, top. The axis carries the values the direct label does not.
    let ticks: [Double]
    /// The one mark that gets its value printed, or nil when there is no extreme worth
    /// naming — an empty series, or a week with no words in it.
    let extremeIndex: Int?

    static func make(values: [Double], size: CGSize) -> BarChartGeometry {
        let upperBound = niceUpperBound(values.max() ?? 0)
        let baselineY = size.height
        let extreme = extremeIndex(of: values)

        var bars: [Bar] = []
        let count = values.count
        // A canvas SwiftUI has not measured yet is 0 × 0. Laying out into it would give
        // negative widths, which `CGRect` happily standardizes into plausible-looking
        // nonsense.
        if count > 0, size.width > 0, size.height > 0 {
            let slot = size.width / CGFloat(count)
            let barWidth = min(maximumBarWidth, slot - surfaceGap)
            if barWidth > 0 {
                for (index, value) in values.enumerated() {
                    let slotMinX = CGFloat(index) * slot
                    let centreX = slotMinX + slot / 2
                    let top = y(for: value, upperBound: upperBound, height: size.height)
                    bars.append(Bar(
                        index: index,
                        value: value,
                        rect: CGRect(x: centreX - barWidth / 2,
                                     y: top,
                                     width: barWidth,
                                     height: baselineY - top),
                        hitRect: CGRect(x: slotMinX, y: 0, width: slot, height: size.height),
                        isExtreme: index == extreme))
                }
            }
        }

        return BarChartGeometry(
            bars: bars,
            upperBound: upperBound,
            baselineY: baselineY,
            ticks: [0, upperBound / 2, upperBound],
            extremeIndex: extreme)
    }

    /// Value → y. Zero is the baseline, always: this is the single line that makes the
    /// chart proportional rather than merely ordered.
    func y(for value: Double) -> CGFloat {
        Self.y(for: value, upperBound: upperBound, height: baselineY)
    }

    private static func y(for value: Double, upperBound: Double, height: CGFloat) -> CGFloat {
        let fraction = min(max(value / upperBound, 0), 1)
        return height - height * CGFloat(fraction)
    }

    /// The bar under `point`, in the canvas's own coordinates.
    func bar(at point: CGPoint) -> Bar? {
        bars.first { bar in
            point.x >= bar.hitRect.minX && point.x < bar.hitRect.maxX
                && point.y >= bar.hitRect.minY && point.y <= bar.hitRect.maxY
        }
    }

    /// A round number at or above `maximum`, so the top gridline is readable and no mark
    /// is ever clipped by its own axis.
    ///
    /// Returns 1 for an empty or all-zero series: the bars are all zero-height either
    /// way, and a bound of 0 would divide by zero the moment a value arrived.
    static func niceUpperBound(_ maximum: Double) -> Double {
        guard maximum > 0 else { return 1 }

        // A ladder rather than powers of two: 61 words should round to 70, not to 80,
        // and certainly not to 100.
        let ladder: [Double] = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 7, 8, 10]
        let exponent = (log10(maximum)).rounded(.down)
        let magnitude = pow(10, exponent)
        let fraction = maximum / magnitude
        let step = ladder.first { $0 >= fraction - 1e-9 } ?? 10
        let bound = step * magnitude
        // Floating point can leave the bound a hair under the maximum at some scales,
        // which would clip the tallest mark by a fraction of a point.
        return max(bound, maximum)
    }

    /// The largest value's index, or nil when there is nothing to call extreme. A tie
    /// goes to the earlier mark, so the label does not jump between equal bars.
    static func extremeIndex(of values: [Double]) -> Int? {
        var best: (index: Int, value: Double)?
        for (index, value) in values.enumerated() where value > 0 {
            if best == nil || value > best!.value {
                best = (index, value)
            }
        }
        return best?.index
    }
}

// MARK: - The week series

/// One day of the words-per-day chart.
struct WordsPerDay: Identifiable, Equatable {
    let dayStart: Date
    let wordCount: Int
    let dictationCount: Int
    /// The one-letter weekday, in the chart's own calendar and locale.
    let label: String
    /// The full date, for the tooltip and the values table.
    let longLabel: String

    var id: Date { dayStart }
}

/// Builds the current week for Home, spec §10.1.
enum WordsPerDaySeries {

    static let dayCount = 7

    /// Seven days, ascending, starting at the calendar's own week start.
    ///
    /// Days with nothing in them are **zero-filled here** rather than omitted:
    /// `StatsSummary.daily` leaves them out (a chart decides its own x-domain, and this
    /// is that decision), but a week drawn with five bars instead of seven silently
    /// changes what the reader is comparing. A Tuesday with no dictation is a fact about
    /// Tuesday.
    ///
    /// Day steps go through `Calendar`, never through 86 400 seconds — the day a region
    /// springs forward is 23 hours long, and second arithmetic loses it.
    static func currentWeek(
        containing now: Date,
        calendar: Calendar,
        from daily: [StatsDay]
    ) -> [WordsPerDay] {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.startOfDay(for: now)
        let byDay = Dictionary(daily.map { ($0.dayStart, $0) }, uniquingKeysWith: { first, _ in first })

        return (0..<dayCount).compactMap { offset -> WordsPerDay? in
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: start) else {
                return nil
            }
            let day = byDay[dayStart]
            return WordsPerDay(
                dayStart: dayStart,
                wordCount: day?.wordCount ?? 0,
                dictationCount: day?.dictationCount ?? 0,
                label: shortWeekday(of: dayStart, calendar: calendar),
                longLabel: longDate(of: dayStart, calendar: calendar))
        }
    }

    private static func shortWeekday(of date: Date, calendar: Calendar) -> String {
        let symbols = calendar.veryShortWeekdaySymbols
        let weekday = calendar.component(.weekday, from: date)
        guard symbols.indices.contains(weekday - 1) else { return "" }
        return symbols[weekday - 1]
    }

    private static func longDate(of date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMM")
        return formatter.string(from: date)
    }
}

// MARK: - Chart

/// Words per day for the current week, spec §10.1 and §11.3.
///
/// Hand-rolled in a `Canvas` rather than built on Apple's `Charts`. Three of the
/// project's rules are the reason: a data-end rounded at the top and square at the
/// baseline is not expressible with `BarMark`'s single `cornerRadius`; a hover tooltip on
/// **every** mark, including a zero-height one, needs the hit target to be the column
/// rather than the shape; and the geometry has to be a pure function to be unit-tested at
/// all. `WaveformCanvas` already established the house pattern for this.
///
/// Nothing here animates and nothing ticks: the values change when `refresh()` reloads
/// the log, and not otherwise (spec §15 — no polling timers, ~0 % idle CPU).
struct WordsPerDayChart: View {
    let days: [WordsPerDay]

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: Int?
    @State private var showsTable = false

    private static let plotHeight: CGFloat = 96
    private static let axisLabelWidth: CGFloat = 30

    var body: some View {
        StatTile(
            title: "Words per day",
            caption: showsTable ? nil : caption,
            accessory: AnyView(ChartTableToggle(showsTable: $showsTable))
        ) {
            if showsTable {
                ChartValueTable(rows: days.map {
                    ChartValueTable.Row(label: $0.longLabel, value: "\($0.wordCount)")
                })
            } else {
                chart
            }
        }
    }

    /// The week's total, stated once rather than printed over every bar. Absent — not
    /// "0 words" — when there is nothing in the week: a caption that reports a total of
    /// zero is a number where there is no measurement.
    private var caption: String? {
        let total = days.reduce(0) { $0 + $1.wordCount }
        return total > 0 ? "\(total) words this week" : nil
    }

    private var values: [Double] { days.map { Double($0.wordCount) } }

    private var chart: some View {
        HStack(alignment: .top, spacing: 6) {
            plot
            axis
        }
        .frame(height: Self.plotHeight + 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words per day this week")
        .accessibilityValue(days.map { "\($0.longLabel): \($0.wordCount) words" }
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

            // Weekday letters sit under their own bar's slot, so the labels and the marks
            // share one grid.
            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { item in
                    Text(item.element.label)
                        .font(.caption2)
                        .foregroundStyle(hovered == item.offset ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
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

    private static func tickLabel(_ value: Double) -> String {
        value >= 1_000
            ? String(format: "%.1fk", value / 1_000)
            : String(Int(value.rounded()))
    }

    private func draw(_ geometry: BarChartGeometry, in context: inout GraphicsContext, size: CGSize) {
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
            // Rank 0 for the extreme, one step back for the rest, and one step back
            // again for whatever the pointer is not on: a single-hue ramp doing the only
            // job it has here, which is to say "this one".
            let rank = bar.isExtreme ? 0 : (hovered == bar.index ? 1 : 2)
            context.fill(
                shape.path(in: bar.rect),
                with: .color(ChartPalette.fill(rank: rank, of: geometry.bars.count,
                                               scheme: colorScheme)))
        }

        // Direct-label the extreme only; the axis carries the rest.
        if let index = geometry.extremeIndex, let bar = geometry.bars.first(where: { $0.index == index }) {
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
        if let index = hovered, let day = days.indices.contains(index) ? days[index] : nil,
           let bar = geometry.bars.first(where: { $0.index == index }) {
            ChartTooltip(
                title: day.longLabel,
                value: "\(day.wordCount) words · \(day.dictationCount) dictations")
                // Clamped so a tooltip on Sunday's bar does not hang off the pane.
                .alignmentGuide(.leading) { tip in
                    -min(max(bar.rect.midX - tip.width / 2, 0), max(size.width - tip.width, 0))
                }
                .alignmentGuide(.top) { tip in
                    -max(bar.rect.minY - tip.height - 4, 0)
                }
        }
    }
}
