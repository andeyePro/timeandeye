import Foundation

/// The Time-Spent period selector. Its range is ANCHORABLE: with `anchor == now`
/// it behaves "relative to today"; the pie's calendar moves the anchor to view
/// any prior period. Pure (date maths only) so it's unit-checkable.
public enum TimePeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case thisWeek = "Week"
    case last7 = "Last 7 days"
    case thisMonth = "Month"
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
            // Calendar arithmetic, NOT +86_400: on a DST-change day the day
            // is 23 or 25 hours long and the raw constant puts an hour of
            // sessions in the wrong period (invisible under the checks' UTC
            // calendar; pinned by the London-TZ check).
            return (day, cal.date(byAdding: .day, value: 1, to: day)
                ?? day.addingTimeInterval(86_400))
        case .thisWeek:
            let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? day
            return (start, cal.date(byAdding: .day, value: 7, to: start)
                ?? start.addingTimeInterval(7 * 86_400))
        case .last7:
            // 7 days ending on the day-of-week of `now`, on/before the anchor.
            let todayWeekday = cal.component(.weekday, from: now)
            var endDay = day
            var guardCount = 0
            while cal.component(.weekday, from: endDay) != todayWeekday, guardCount < 7 {
                endDay = cal.date(byAdding: .day, value: -1, to: endDay) ?? endDay
                guardCount += 1
            }
            let endExclusive = cal.date(byAdding: .day, value: 1, to: endDay)
                ?? endDay.addingTimeInterval(86_400)
            return (cal.date(byAdding: .day, value: -7, to: endExclusive)
                ?? endExclusive.addingTimeInterval(-7 * 86_400), endExclusive)
        case .thisMonth:
            let start = cal.dateInterval(of: .month, for: anchor)?.start ?? day
            let end = cal.date(byAdding: .month, value: 1, to: start)
                ?? start.addingTimeInterval(31 * 86_400)
            return (start, end)
        }
    }

    /// If `[start, endExclusive)` exactly equals one preset's range anchored on
    /// `now`, return that preset — so a hand-made calendar selection that happens
    /// to be e.g. "this week" re-lights the Week button. Otherwise nil (custom).
    public static func matching(start: Date, endExclusive: Date, now: Date,
                                calendar: Calendar = .current) -> TimePeriod? {
        allCases.first { p in
            let r = p.range(anchor: now, now: now, calendar: calendar)
            return r.start == start && r.end == endExclusive
        }
    }
}
