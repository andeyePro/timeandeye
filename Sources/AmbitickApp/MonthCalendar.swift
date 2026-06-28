import SwiftUI

/// A compact month grid for the Time-Pie. Highlights the days within the shown
/// period's `[start, end)` range, lets you page months, and reports a tapped day
/// back so the pie can re-anchor on it. Closeable via the header ✕.
struct MonthCalendar: View {
    @Binding var month: Date
    /// The currently-shown period range; days within it are highlighted.
    let highlighted: (start: Date, end: Date)
    /// Today (start-of-day), ringed for orientation.
    let today: Date
    let onPick: (Date) -> Void
    let onClose: () -> Void
    var width: CGFloat = 232

    private var cal: Calendar { .current }

    var body: some View {
        VStack(spacing: 4) {
            header
            weekdayRow
            grid
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .frame(width: width)
    }

    private var header: some View {
        HStack {
            Button { page(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.caption).bold()
            Spacer()
            Button { page(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(isCurrentMonthOrLater)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide the calendar")
        }
        .font(.caption2)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { s in
                Text(s).font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        return LazyVGrid(columns: cols, spacing: 2) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 22)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let inRange = day >= cal.startOfDay(for: highlighted.start) && day < highlighted.end
        let isToday = cal.isDate(day, inSameDayAs: today)
        let future = day > today
        return Button { onPick(day) } label: {
            Text("\(cal.component(.day, from: day))")
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, minHeight: 22)
                .foregroundStyle(future ? AnyShapeStyle(.tertiary)
                                 : inRange ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .background {
                    if inRange { RoundedRectangle(cornerRadius: 4).fill(Color.accentColor) }
                }
                .overlay {
                    if isToday {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(future)
    }

    // MARK: - Date maths

    /// Days of the shown month, leading-padded with nil to the week's first day.
    private var days: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        let firstWeekday = cal.component(.weekday, from: first)
        let lead = (firstWeekday - cal.firstWeekday + 7) % 7
        let dayCount = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for d in 0..<dayCount {
            cells.append(cal.date(byAdding: .day, value: d, to: first))
        }
        return cells
    }

    private var orderedWeekdaySymbols: [String] {
        let syms = cal.veryShortStandaloneWeekdaySymbols
        let shift = cal.firstWeekday - 1
        return Array(syms[shift...] + syms[..<shift])
    }

    private var isCurrentMonthOrLater: Bool {
        guard let shown = cal.dateInterval(of: .month, for: month)?.start,
              let cur = cal.dateInterval(of: .month, for: today)?.start else { return true }
        return shown >= cur
    }

    private func page(_ delta: Int) {
        if let m = cal.date(byAdding: .month, value: delta, to: month) { month = m }
    }
}
