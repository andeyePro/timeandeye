import Foundation

/// The Time-Spent period selector. Its range is ANCHORABLE: with `anchor == now`
/// it behaves "relative to today"; the pie's calendar moves the anchor to view
/// any prior period. Pure (date maths only) so it's unit-checkable.
public enum TimePeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This week"
    case last7 = "Last 7 days"
    case thisMonth = "This month"
    public var id: String { rawValue }

    /// The [start, end) range shown for this period, anchored on `anchor`.
    /// `now` supplies today's weekday (so "Last 7 days" always ends on the same
    /// weekday as today, wherever the anchor is).
    public func range(anchor: Date, now: Date,
                      calendar: Calendar = .current) -> (start: Date, end: Date) {
        let cal = calendar
        let day = cal.startOfDay(for: anchor)
        switch self {
        case .today:
            return (day, day.addingTimeInterval(86_400))
        case .yesterday:
            return (day.addingTimeInterval(-86_400), day)
        case .thisWeek:
            let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? day
            return (start, start.addingTimeInterval(7 * 86_400))
        case .last7:
            // 7 days ending on the day-of-week of `now`, on/before the anchor.
            let todayWeekday = cal.component(.weekday, from: now)
            var endDay = day
            var guardCount = 0
            while cal.component(.weekday, from: endDay) != todayWeekday, guardCount < 7 {
                endDay = cal.date(byAdding: .day, value: -1, to: endDay) ?? endDay
                guardCount += 1
            }
            let endExclusive = endDay.addingTimeInterval(86_400)
            return (endExclusive.addingTimeInterval(-7 * 86_400), endExclusive)
        case .thisMonth:
            let start = cal.dateInterval(of: .month, for: anchor)?.start ?? day
            let end = cal.date(byAdding: .month, value: 1, to: start)
                ?? start.addingTimeInterval(31 * 86_400)
            return (start, end)
        }
    }
}
