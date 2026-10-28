import SwiftUI

enum ActivityMetric: String, CaseIterable, Identifiable {
    case dictations = "Dictations"
    case words = "Words"

    var id: Self { self }
}

struct ActivityDay: Identifiable, Equatable {
    let date: Date
    let dictationCount: Int
    let wordCount: Int
    let shortLabel: String
    let longLabel: String
    let monthKey: String
    let monthLabel: String

    var id: Date { date }

    func value(for metric: ActivityMetric) -> Int {
        switch metric {
        case .dictations: dictationCount
        case .words: wordCount
        }
    }
}

struct ActivityCalendarGrid: Equatable {
    struct Coordinate: Equatable {
        let column: Int
        let row: Int
    }

    let columns: [[ActivityDay?]]
    let weekdayLabels: [String]

    static let empty = ActivityCalendarGrid(columns: [], weekdayLabels: [])

    var days: [ActivityDay] { columns.flatMap { $0.compactMap { $0 } } }

    func coordinate(of date: Date) -> Coordinate? {
        for (columnIndex, column) in columns.enumerated() {
            if let rowIndex = column.firstIndex(where: { $0?.date == date }) {
                return Coordinate(column: columnIndex, row: rowIndex)
            }
        }
        return nil
    }

    /// Returns the neighboring real date, or the starting date when the requested grid
    /// coordinate is outside the grid or is visual padding.
    func destination(from date: Date, moving direction: ActivityGridMove) -> Date {
        guard let origin = coordinate(of: date) else { return date }
        let delta: (column: Int, row: Int)
        switch direction {
        case .up: delta = (0, -1)
        case .down: delta = (0, 1)
        case .left: delta = (-1, 0)
        case .right: delta = (1, 0)
        }
        let column = origin.column + delta.column
        let row = origin.row + delta.row
        guard columns.indices.contains(column), columns[column].indices.contains(row),
              let destination = columns[column][row] else { return date }
        return destination.date
    }

    /// Labels the column that actually contains a month boundary, even when the first
    /// day of that month sits midway down the column.
    func monthLabel(forColumn index: Int) -> String {
        guard columns.indices.contains(index) else { return "" }
        var previous = index > 0 ? columns[index - 1].compactMap { $0 }.last : nil
        var label = index == 0 ? columns[index].compactMap { $0 }.first?.monthLabel ?? "" : ""
        for day in columns[index].compactMap({ $0 }) {
            if let previous, previous.monthKey != day.monthKey { label = day.monthLabel }
            previous = day
        }
        return label
    }
}

enum ActivityGridMove {
    case up
    case down
    case left
    case right
}

private struct ActivityMapHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 160

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Produces the 91 real dates used by Overview's contribution map. The display grid may
/// need a fourteenth partial week after weekday-alignment padding.
enum ActivityCalendar {
    static let dayCount = 91

    static func days(
        from daily: [StatsDay],
        endingAt now: Date,
        calendar: Calendar
    ) -> [ActivityDay] {
        let end = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: end) else {
            return []
        }
        let values = Dictionary(daily.map { ($0.dayStart, $0) },
                                uniquingKeysWith: { first, _ in first })
        let shortDate = formatter(template: "MMM d", calendar: calendar)
        let longDate = formatter(template: "EEEE, MMMM d, yyyy", calendar: calendar)
        let monthKey = formatter(template: "yyyyMM", calendar: calendar)
        let month = formatter(template: "MMM", calendar: calendar)

        return (0..<dayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else {
                return nil
            }
            let value = values[date]
            return ActivityDay(
                date: date,
                dictationCount: value?.dictationCount ?? 0,
                wordCount: value?.wordCount ?? 0,
                shortLabel: shortDate.string(from: date),
                longLabel: longDate.string(from: date),
                monthKey: monthKey.string(from: date),
                monthLabel: month.string(from: date))
        }
    }

    /// Stable thresholds keep a day's color meaningful when a later high-volume day is
    /// added. The scale encodes volume only; it makes no claim about quality.
    static func level(value: Int, metric: ActivityMetric) -> Int {
        guard value > 0 else { return 0 }
        switch metric {
        case .dictations:
            if value == 1 { return 1 }
            if value <= 3 { return 2 }
            if value <= 7 { return 3 }
            return 4
        case .words:
            if value < 100 { return 1 }
            if value < 250 { return 2 }
            if value < 500 { return 3 }
            return 4
        }
    }

    /// Aligns the rolling dates to the calendar's first weekday. Padding is visual only:
    /// nil cells have no button, value, tooltip or accessibility element.
    static func grid(days: [ActivityDay], calendar: Calendar) -> ActivityCalendarGrid {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let labels = (0..<7).map { offset -> String in
            let index = (calendar.firstWeekday - 1 + offset) % 7
            return symbols.indices.contains(index) ? symbols[index] : ""
        }
        guard let first = days.first else {
            return ActivityCalendarGrid(columns: [], weekdayLabels: labels)
        }

        let weekday = calendar.component(.weekday, from: first.date)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells = Array<ActivityDay?>(repeating: nil, count: leading)
        cells.append(contentsOf: days.map(Optional.some))
        let trailing = (7 - cells.count % 7) % 7
        cells.append(contentsOf: repeatElement(nil, count: trailing))

        let columns = stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0..<min($0 + 7, cells.count)])
        }
        return ActivityCalendarGrid(columns: columns, weekdayLabels: labels)
    }

    private static func formatter(template: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}

struct ActivityHeatmap: View {
    let grid: ActivityCalendarGrid

    private static let minimumMapWidth: CGFloat = 390
    private static let weekdayWidth: CGFloat = 20
    private static let gridGap: CGFloat = 6
    private static let columnGap: CGFloat = 4
    private static let cellAspect: CGFloat = 0.77
    private static let monthLabelHeight: CGFloat = 11
    private static let monthToGridGap: CGFloat = 7
    private static let verticalPadding: CGFloat = 2

    @State private var metric: ActivityMetric = .dictations
    @State private var selectedDate: Date?
    @State private var responsiveMapHeight: CGFloat = 160
    @FocusState private var focusedDate: Date?

    private var days: [ActivityDay] { grid.days }
    private var selected: ActivityDay? {
        days.first { $0.date == (selectedDate ?? days.last?.date) }
    }

    var body: some View {
        CapturCard("Your rhythm", symbol: "square.grid.3x3.fill") {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    Text(activeDaySummary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Activity metric", selection: $metric) {
                        ForEach(ActivityMetric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 190)
                }

                responsiveMap

                HStack(spacing: 7) {
                    if let selected {
                        Text(selected.longLabel)
                            .font(.caption.weight(.medium))
                        Spacer(minLength: 8)
                        Text("\(selected.dictationCount) \(selected.dictationCount == 1 ? "dictation" : "dictations") · \(selected.wordCount) words")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(minHeight: 18)
                .accessibilityElement(children: .combine)

                HStack(spacing: 5) {
                    Text("Less")
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(level: level))
                            .frame(width: 10, height: 10)
                            .overlay {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .strokeBorder(CapturPalette.border, lineWidth: 0.5)
                            }
                            .accessibilityHidden(true)
                    }
                    Text("More")
                    Spacer()
                    if let first = days.first, let last = days.last {
                        Text("\(first.shortLabel) – \(last.shortLabel)")
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            if selectedDate == nil { selectedDate = days.last?.date }
        }
        .onChange(of: metric) { _, _ in
            if selectedDate == nil { selectedDate = days.last?.date }
        }
        .onChange(of: grid) { _, newGrid in
            if !newGrid.days.contains(where: { $0.date == selectedDate }) {
                selectedDate = newGrid.days.last?.date
            }
        }
    }

    private var activeDaySummary: String {
        let active = days.filter { $0.value(for: metric) > 0 }.count
        return "\(active) active days across the last \(days.count)"
    }

    private var responsiveMap: some View {
        GeometryReader { proxy in
            let contentWidth = max(proxy.size.width, Self.minimumMapWidth)
            let columnCount = max(grid.columns.count, 1)
            let gaps = CGFloat(columnCount - 1) * Self.columnGap
            let gridWidth = contentWidth - Self.weekdayWidth - Self.gridGap
            let cellWidth = max(18, (gridWidth - gaps) / CGFloat(columnCount))
            let cellHeight = cellWidth * Self.cellAspect
            let gridHeight = cellHeight * 7 + Self.columnGap * 6
            let requiredHeight = Self.monthLabelHeight + Self.monthToGridGap
                + gridHeight + Self.verticalPadding * 2

            ScrollView(.horizontal, showsIndicators: contentWidth > proxy.size.width) {
                VStack(alignment: .leading, spacing: Self.monthToGridGap) {
                    monthLabels(cellWidth: cellWidth)
                    HStack(alignment: .top, spacing: Self.gridGap) {
                        weekdayLabels(cellHeight: cellHeight)
                        HStack(spacing: Self.columnGap) {
                            ForEach(Array(grid.columns.enumerated()), id: \.offset) { columnIndex, column in
                                VStack(spacing: Self.columnGap) {
                                    ForEach(Array(column.enumerated()), id: \.offset) { rowIndex, day in
                                        if let day {
                                            cell(day, width: cellWidth, height: cellHeight)
                                        } else {
                                            Color.clear
                                                .frame(width: cellWidth, height: cellHeight)
                                                .accessibilityHidden(true)
                                                .id("padding-\(columnIndex)-\(rowIndex)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.vertical, Self.verticalPadding)
            }
            .preference(key: ActivityMapHeightKey.self, value: requiredHeight)
        }
        .frame(height: responsiveMapHeight)
        .onPreferenceChange(ActivityMapHeightKey.self) { height in
            if abs(responsiveMapHeight - height) > 0.5 { responsiveMapHeight = height }
        }
    }

    private func monthLabels(cellWidth: CGFloat) -> some View {
        HStack(spacing: Self.columnGap) {
            Color.clear
                .frame(width: Self.weekdayWidth + Self.gridGap - Self.columnGap, height: 1)
            ForEach(Array(grid.columns.enumerated()), id: \.offset) { index, _ in
                Text(grid.monthLabel(forColumn: index))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: cellWidth, height: Self.monthLabelHeight, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    private func weekdayLabels(cellHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Self.columnGap) {
            ForEach(Array(grid.weekdayLabels.enumerated()), id: \.offset) { index, label in
                Text(index.isMultiple(of: 2) ? label : "")
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                    .frame(width: Self.weekdayWidth, height: cellHeight, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    private func cell(_ day: ActivityDay, width: CGFloat, height: CGFloat) -> some View {
        let value = day.value(for: metric)
        let level = ActivityCalendar.level(value: value, metric: metric)
        return Button {
            selectedDate = day.date
            focusedDate = day.date
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color(level: level))
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(selectedDate == day.date ? Color.primary.opacity(0.8) : CapturPalette.border,
                                      lineWidth: selectedDate == day.date ? 1.5 : 0.5)
                }
                .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedDate, equals: day.date)
        .focusEffectDisabled()
        .overlay {
            if focusedDate == day.date {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2).padding(-2)
                    .allowsHitTesting(false)
            }
        }
        .help("\(day.longLabel): \(day.dictationCount) dictations, \(day.wordCount) words")
        .accessibilityLabel(day.longLabel)
        .accessibilityValue("\(value) \(metric.rawValue.lowercased())")
        .accessibilityAddTraits(selectedDate == day.date ? .isSelected : [])
        .onKeyPress(.upArrow) { move(from: day, direction: .up); return .handled }
        .onKeyPress(.downArrow) { move(from: day, direction: .down); return .handled }
        .onKeyPress(.leftArrow) { move(from: day, direction: .left); return .handled }
        .onKeyPress(.rightArrow) { move(from: day, direction: .right); return .handled }
    }

    private func move(from day: ActivityDay, direction: MoveCommandDirection) {
        let move: ActivityGridMove
        switch direction {
        case .up: move = .up
        case .down: move = .down
        case .left: move = .left
        case .right: move = .right
        @unknown default: return
        }
        let destination = grid.destination(from: day.date, moving: move)
        selectedDate = destination
        focusedDate = destination
    }

    private func color(level: Int) -> Color {
        guard level > 0 else { return CapturPalette.inset }
        return CapturPalette.accent.opacity([0, 0.28, 0.48, 0.7, 0.94][min(level, 4)])
    }

}
