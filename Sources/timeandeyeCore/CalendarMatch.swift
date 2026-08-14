import Foundation

/// What we know about a calendar event, normalised for matching – the
/// EventKit-free plain struct the mac bridge maps `EKEvent` into (keeps
/// EventKit types out of Core exactly as `ActivitySignal` keeps AppKit out).
/// `attendees` are lowercased email addresses (or display names when no
/// address is available). `tentative` is the local user's own RSVP status;
/// `allDay` events are excluded from the live prior but still qualify for
/// the review-queue hint (calendar signal spec §3).
package struct CalendarEvent: Equatable, Sendable {
    package let id: String
    package let title: String
    package let calendarName: String
    package let attendees: [String]
    package let start: Date
    package let end: Date
    package let tentative: Bool
    package let allDay: Bool
    /// True when the event lives in the user's PRIMARY calendar (the Mac
    /// bridge maps EventKit's default-calendar-for-new-events). Selection
    /// prefers primary over secondary — the week-long all-day span from a
    /// subscribed side calendar must not outrank a real meeting.
    package let primary: Bool

    package init(id: String, title: String, calendarName: String, attendees: [String],
                start: Date, end: Date, tentative: Bool = false, allDay: Bool = false,
                primary: Bool = false) {
        self.id = id
        self.title = title
        self.calendarName = calendarName
        self.attendees = attendees.map { $0.lowercased() }
        self.start = start
        self.end = end
        self.tentative = tentative
        self.allDay = allDay
        self.primary = primary
    }
}

/// Which event to OFFER when several overlap — the pure selection core for
/// both the review drawer's hint chip (span form) and the live prior (point
/// form). Until 2026-08-14 both consumers took whatever order EventKit
/// returned, so a week-long all-day event from a secondary calendar could be
/// offered as the candidate while a genuine 30-minute timed meeting from the
/// primary calendar on the same day was never seen (Martin's report).
///
/// Nothing is EXCLUDED here — an all-day "Annual leave" is still a
/// legitimate hint when it's all there is (spec §7); ranking just stops it
/// beating a real meeting. Callers that must exclude all-day (the live
/// prior) filter before ranking, as they always did.
package enum CalendarSelection {
    /// Rank order for candidates overlapping `span`, best first:
    /// timed beats all-day, single-day all-day beats multi-day; primary
    /// calendar beats secondary; more overlap with the span beats less;
    /// then the shorter (more specific) event; then earlier start (stable).
    package static func ranked(_ events: [CalendarEvent],
                               overlapping span: (start: Date, end: Date)) -> [CalendarEvent] {
        events.filter { $0.start < span.end && $0.end > span.start }
            .sorted { a, b in
                if tier(a) != tier(b) { return tier(a) < tier(b) }
                if a.primary != b.primary { return a.primary }
                let oa = overlap(a, span), ob = overlap(b, span)
                if oa != ob { return oa > ob }
                let da = duration(a), db = duration(b)
                if da != db { return da < db }
                return a.start < b.start
            }
    }

    package static func best(_ events: [CalendarEvent],
                             overlapping span: (start: Date, end: Date)) -> CalendarEvent? {
        ranked(events, overlapping: span).first
    }

    /// Rank order for "what am I doing THIS minute" among events covering a
    /// point: primary first, then the shortest (a 30-min meeting inside a
    /// 3-hour block IS the current thing), then the most recently begun,
    /// then title (deterministic).
    package static func rankedLive(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.sorted { a, b in
            if a.primary != b.primary { return a.primary }
            let da = duration(a), db = duration(b)
            if da != db { return da < db }
            if a.start != b.start { return a.start > b.start }
            return a.title < b.title
        }
    }

    /// Timed 0, all-day within one day 1, all-day spanning days 2. The
    /// 26-hour bound keeps a timezone-skewed "one day" in tier 1.
    private static func tier(_ e: CalendarEvent) -> Int {
        guard e.allDay else { return 0 }
        return duration(e) <= 26 * 3600 ? 1 : 2
    }

    private static func duration(_ e: CalendarEvent) -> TimeInterval {
        e.end.timeIntervalSince(e.start)
    }

    private static func overlap(_ e: CalendarEvent,
                                _ span: (start: Date, end: Date)) -> TimeInterval {
        max(0, min(e.end, span.end).timeIntervalSince(max(e.start, span.start)))
    }
}

/// The user-editable specificity ladder for calendar→task matching. Mirrors
/// `EmailMatchLevel` exactly (calendar signal spec §4) – several rules can
/// match one event (its calendar, an attendee, a word in the title); the
/// MOST SPECIFIC matching rule wins. The order is a setting so the user can
/// retune it; `defaultOrder` is general → specific.
package enum CalendarMatchLevel: String, CaseIterable, Codable, Sendable {
    case calendarName   // "all events in this calendar" – broadest
    case attendee        // a specific person's email/name on the invite
    case titleKeyword    // a word/phrase in the event title – most specific

    /// Low (general) → high (specific). The last element wins ties of presence.
    package static let defaultOrder: [CalendarMatchLevel] =
        [.calendarName, .attendee, .titleKeyword]

    package var label: String {
        switch self {
        case .calendarName: return "Calendar"
        case .attendee: return "Attendee"
        case .titleKeyword: return "Title keyword"
        }
    }
}

/// One calendar→task rule, learned (from a correction) or pinned (explicit).
/// Mirrors `EmailRule` exactly, including provenance metadata and its
/// back-compat decode (calendar signal spec §4).
package struct CalendarRule: Equatable, Codable, Sendable {
    package let level: CalendarMatchLevel
    package let value: String
    package let target: TaskRef
    /// True for explicit user pins (which outrank a learned rule at the same level).
    package let pinned: Bool
    /// Provenance metadata, same shape as `EmailRule`'s: decodes with
    /// defaults so a calendarrules.json written before they existed still
    /// loads: createdAt → .distantPast, origin → .migrated, fireCount → 0,
    /// lastFired → nil.
    package var createdAt: Date
    package var origin: EmailRule.Origin
    /// Bumped by the matcher's caller each time this rule WINS a match.
    package var fireCount: Int
    package var lastFired: Date?

    package init(level: CalendarMatchLevel, value: String, target: TaskRef, pinned: Bool = false,
                createdAt: Date = Date(), origin: EmailRule.Origin = .correction,
                fireCount: Int = 0, lastFired: Date? = nil) {
        self.level = level
        self.value = value
        self.target = target
        self.pinned = pinned
        self.createdAt = createdAt
        self.origin = origin
        self.fireCount = fireCount
        self.lastFired = lastFired
    }

    /// Custom decode ONLY for the metadata defaults; encoding stays synthesized
    /// (always writes the full metadata form).
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decode(CalendarMatchLevel.self, forKey: .level)
        value = try c.decode(String.self, forKey: .value)
        target = try c.decode(TaskRef.self, forKey: .target)
        pinned = try c.decode(Bool.self, forKey: .pinned)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        origin = try c.decodeIfPresent(EmailRule.Origin.self, forKey: .origin) ?? .migrated
        fireCount = try c.decodeIfPresent(Int.self, forKey: .fireCount) ?? 0
        lastFired = try c.decodeIfPresent(Date.self, forKey: .lastFired)
    }

    /// The identity of a rule for replace/forget purposes: what it matches and
    /// where it points, NOT its metadata (a fireCount bump must not make a rule
    /// "different" from the snapshot a card captured).
    package func sameRule(as other: CalendarRule) -> Bool {
        level == other.level && target == other.target && pinned == other.pinned
            && value.caseInsensitiveCompare(other.value) == .orderedSame
    }

    package func matches(_ event: CalendarEvent) -> Bool {
        switch level {
        case .calendarName:
            return !value.isEmpty && value.caseInsensitiveCompare(event.calendarName) == .orderedSame
        case .attendee:
            return !value.isEmpty && event.attendees.contains(value.lowercased())
        case .titleKeyword:
            guard !value.isEmpty else { return false }
            return event.title.range(of: value, options: .caseInsensitive) != nil
        }
    }
}

package extension CalendarEvent {
    /// The identity of one OCCURRENCE for alert deduplication. EventKit gives
    /// every instance of a recurring series the SAME `eventIdentifier`, so
    /// `id` alone would let one standup silence every future standup — the
    /// start time disambiguates occurrences while staying stable across
    /// re-fetches of the same window.
    var occurrenceKey: String { "\(id)|\(start.timeIntervalSince1970)" }
}

/// What the menu-bar mark should be doing about upcoming meetings right now
/// (calendar signal, Martin's 2026-07-09 alert design): a quiet slow pulse
/// in the lead-up window, one violent flash at start, silence otherwise.
package enum CalendarAlertPhase: Equatable, Sendable {
    case none
    /// Inside `[start − lead, start)` of an upcoming event: the quiet pulse.
    case preMeeting(CalendarEvent)
    /// Inside `[start, start + grace)` of an event that hasn't alerted yet:
    /// the one-shot violent flash.
    case starting(CalendarEvent)
}

/// The time-based meeting alerts' pure decision core — platform-free so the
/// checks can drive every edge with seeded `CalendarEvent`s (no EventKit, no
/// clock). The Mac side owns the animations; this owns WHEN.
package enum CalendarAlerts {
    /// The start flash only fires within this window after an event's start.
    /// Launching the app (or waking the Mac) later than this into a meeting
    /// gives NO retroactive flash — a violent alert about something that
    /// began ten minutes ago is noise, not help. Landing inside the window
    /// still flashes: you're only just late, and the flash is still the
    /// nudge it was designed to be.
    package static let startGraceSeconds: TimeInterval = 60

    /// The Settings picker's lead-time choices, in minutes (default 5).
    package static let leadMinuteChoices: [Int] = [1, 2, 5, 10, 15]

    /// Alert-worthy at all: all-day events never alert (an all-day "Annual
    /// leave" banner has no meaningful start to be late for). Declined
    /// events never reach here — the bridge drops them at fetch.
    package static func qualifies(_ event: CalendarEvent) -> Bool { !event.allDay }

    /// The alert phase for `events` at `now`. `leadSeconds` is the
    /// pre-meeting window (pass 0 when the pre-meeting alert is off — no
    /// window, no pulse); `alreadyFired` holds the occurrence keys whose
    /// start flash has fired, so no event alerts twice.
    ///
    /// Resolution order: a due start flash beats any pulse (the violent
    /// flash takes over from the pulse at start; the caller marks it fired
    /// and re-asks, which is what lets a back-to-back NEXT event's pulse
    /// resume straight after). Among pulse candidates the soonest start
    /// wins — back-to-back events each get their own lead-up. A tentative
    /// invite pulses (you may still need to decide to go) but never gets
    /// the violent flash: "maybe" shouldn't shout as loud as "yes".
    package static func phase(events: [CalendarEvent], at now: Date,
                             leadSeconds: TimeInterval,
                             alreadyFired: Set<String>) -> CalendarAlertPhase {
        if let due = events
            .filter({ qualifies($0) && !$0.tentative
                && $0.start <= now && now < $0.start.addingTimeInterval(startGraceSeconds)
                && !alreadyFired.contains($0.occurrenceKey) })
            .min(by: { $0.start < $1.start }) {
            return .starting(due)
        }
        if leadSeconds > 0, let upcoming = events
            .filter({ qualifies($0) && $0.start > now
                && now >= $0.start.addingTimeInterval(-leadSeconds) })
            .min(by: { $0.start < $1.start }) {
            return .preMeeting(upcoming)
        }
        return .none
    }

    /// The next instant the phase can change on its own: an event entering
    /// its lead window, starting, exhausting its start grace, or ending
    /// (ends kept for the live prior's boundary timer, which shares this).
    /// nil = nothing ahead — no timer needed until the window refreshes.
    package static func nextBoundary(events: [CalendarEvent], after now: Date,
                                    leadSeconds: TimeInterval) -> Date? {
        events.flatMap {
            [$0.start.addingTimeInterval(-leadSeconds), $0.start,
             $0.start.addingTimeInterval(startGraceSeconds), $0.end]
        }
        .filter { $0 > now }
        .min()
    }
}

package enum CalendarMatcher {
    /// The winning rule for `event`: the most-specific level (per `order`,
    /// general → specific) that has a matching rule. At one level a pinned
    /// rule beats a learned one; otherwise the newest unpinned wins ties –
    /// exactly `EmailMatcher.match()`'s resolution (calendar signal spec §4).
    package static func bestRule(rules: [CalendarRule], event: CalendarEvent,
                                order: [CalendarMatchLevel] = CalendarMatchLevel.defaultOrder)
        -> CalendarRule? {
        for level in order.reversed() {
            let here = rules.filter { $0.level == level && $0.matches(event) }
            if here.isEmpty { continue }
            return here.first { $0.pinned } ?? here.last   // newest unpinned wins ties
        }
        return nil
    }

    /// The conservative default grain a correction should teach when it lands
    /// while `event` is live: a `titleKeyword` rule from the event's own
    /// title – the narrowest, safest grain (calendar signal spec §4). Never
    /// pinned; the caller supplies provenance/timestamp for the teach path.
    package static func learnableRule(event: CalendarEvent, for task: TaskRef,
                                     origin: EmailRule.Origin = .correction,
                                     now: Date = Date()) -> CalendarRule {
        CalendarRule(level: .titleKeyword, value: event.title, target: task,
                    pinned: false, createdAt: now, origin: origin)
    }
}
