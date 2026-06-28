import SwiftUI

/// A compact month grid for the Time-Pie. Days are selectable: click one day,
/// drag across a span, or shift-click to extend the current selection. The swept
/// contiguous range is reported back via `onSelect`; the shown range
/// (`selStart...selEnd`, both start-of-day inclusive) is highlighted. Closeable
/// via the header ✕.
struct MonthCalendar: View {
    @Binding var month: Date
    /// Currently-selected days (start-of-day, inclusive both ends), highlighted.
    let selStart: Date
    let selEnd: Date
    /// Today (start-of-day): ringed for orientation, and the latest selectable day.
    let today: Date
    let onSelect: (ClosedRange<Date>) -> Void
    let onClose: () -> Void
    var width: CGFloat = 232

    /// The day a drag/shift gesture is anchored on (nil between gestures).
    @State private var dragOrigin: Date?
    /// Each day-cell's frame in the grid's coordinate space, for hit-testing the
    /// drag location back to a day.
    @State private var cellFrames: [Date: CGRect] = [:]

    private static let space = "calGrid"
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
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(CellFrameKey.self) { cellFrames = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { handleDrag(at: $0.location) }
                .onEnded { _ in dragOrigin = nil }
        )
    }

    private func dayCell(_ day: Date) -> some View {
        let inSel = day >= selStart && day <= selEnd
        let isToday = cal.isDate(day, inSameDayAs: today)
        let future = day > today
        return Text("\(cal.component(.day, from: day))")
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, minHeight: 22)
            .foregroundStyle(future ? AnyShapeStyle(.tertiary)
                             : inSel ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .background {
                if inSel { RoundedRectangle(cornerRadius: 4).fill(Color.accentColor) }
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .background(GeometryReader { g in
                Color.clear.preference(key: CellFrameKey.self,
                                       value: [day: g.frame(in: .named(Self.space))])
            })
    }

    // MARK: - Gesture → day selection

    /// Map the drag/click location to a day and report the swept range. A bare
    /// click (no movement) selects one day; dragging grows the range; holding ⇧
    /// extends from the existing selection's start instead of the touched day.
    private func handleDrag(at location: CGPoint) {
        guard let touched = dayAt(location) else { return }
        let day = min(touched, today)               // never select into the future
        if dragOrigin == nil {
            dragOrigin = NSEvent.modifierFlags.contains(.shift) ? selStart : day
        }
        let origin = dragOrigin ?? day
        onSelect(min(origin, day)...max(origin, day))
    }

    private func dayAt(_ p: CGPoint) -> Date? {
        cellFrames.first { $0.value.contains(p) }?.key
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

/// Collects each day-cell's frame so a drag location can be mapped back to a day.
private struct CellFrameKey: PreferenceKey {
    static let defaultValue: [Date: CGRect] = [:]
    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
