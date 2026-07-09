import Foundation

/// What we know about a calendar event, normalised for matching – the
/// EventKit-free plain struct the mac bridge maps `EKEvent` into (keeps
/// EventKit types out of Core exactly as `ActivitySignal` keeps AppKit out).
/// `attendees` are lowercased email addresses (or display names when no
/// address is available). `tentative` is the local user's own RSVP status;
/// `allDay` events are excluded from the live prior but still qualify for
/// the review-queue hint (calendar signal spec §3).
public struct CalendarEvent: Equatable, Sendable {
    public let id: String
    public let title: String
    public let calendarName: String
    public let attendees: [String]
    public let start: Date
    public let end: Date
    public let tentative: Bool
    public let allDay: Bool

    public init(id: String, title: String, calendarName: String, attendees: [String],
                start: Date, end: Date, tentative: Bool = false, allDay: Bool = false) {
        self.id = id
        self.title = title
        self.calendarName = calendarName
        self.attendees = attendees.map { $0.lowercased() }
        self.start = start
        self.end = end
        self.tentative = tentative
        self.allDay = allDay
    }
}

/// The user-editable specificity ladder for calendar→task matching. Mirrors
/// `EmailMatchLevel` exactly (calendar signal spec §4) – several rules can
/// match one event (its calendar, an attendee, a word in the title); the
/// MOST SPECIFIC matching rule wins. The order is a setting so the user can
/// retune it; `defaultOrder` is general → specific.
public enum CalendarMatchLevel: String, CaseIterable, Codable, Sendable {
    case calendarName   // "all events in this calendar" – broadest
    case attendee        // a specific person's email/name on the invite
    case titleKeyword    // a word/phrase in the event title – most specific

    /// Low (general) → high (specific). The last element wins ties of presence.
    public static let defaultOrder: [CalendarMatchLevel] =
        [.calendarName, .attendee, .titleKeyword]

    public var label: String {
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
public struct CalendarRule: Equatable, Codable, Sendable {
    public let level: CalendarMatchLevel
    public let value: String
    public let target: TaskRef
    /// True for explicit user pins (which outrank a learned rule at the same level).
    public let pinned: Bool
    /// Provenance metadata, same shape as `EmailRule`'s: decodes with
    /// defaults so a calendarrules.json written before they existed still
    /// loads: createdAt → .distantPast, origin → .migrated, fireCount → 0,
    /// lastFired → nil.
    public var createdAt: Date
    public var origin: EmailRule.Origin
    /// Bumped by the matcher's caller each time this rule WINS a match.
    public var fireCount: Int
    public var lastFired: Date?

    public init(level: CalendarMatchLevel, value: String, target: TaskRef, pinned: Bool = false,
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
    public init(from decoder: Decoder) throws {
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
    public func sameRule(as other: CalendarRule) -> Bool {
        level == other.level && target == other.target && pinned == other.pinned
            && value.caseInsensitiveCompare(other.value) == .orderedSame
    }

    public func matches(_ event: CalendarEvent) -> Bool {
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

public extension CalendarEvent {
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
public enum CalendarAlertPhase: Equatable, Sendable {
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
public enum CalendarAlerts {
    /// The start flash only fires within this window after an event's start.
    /// Launching the app (or waking the Mac) later than this into a meeting
    /// gives NO retroactive flash — a violent alert about something that
    /// began ten minutes ago is noise, not help. Landing inside the window
    /// still flashes: you're only just late, and the flash is still the
    /// nudge it was designed to be.
    public static let startGraceSeconds: TimeInterval = 60

    /// The Settings picker's lead-time choices, in minutes (default 5).
    public static let leadMinuteChoices: [Int] = [1, 2, 5, 10, 15]

    /// Alert-worthy at all: all-day events never alert (an all-day "Annual
    /// leave" banner has no meaningful start to be late for). Declined
    /// events never reach here — the bridge drops them at fetch.
    public static func qualifies(_ event: CalendarEvent) -> Bool { !event.allDay }

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
    public static func phase(events: [CalendarEvent], at now: Date,
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
    public static func nextBoundary(events: [CalendarEvent], after now: Date,
                                    leadSeconds: TimeInterval) -> Date? {
        events.flatMap {
            [$0.start.addingTimeInterval(-leadSeconds), $0.start,
             $0.start.addingTimeInterval(startGraceSeconds), $0.end]
        }
        .filter { $0 > now }
        .min()
    }
}

public enum CalendarMatcher {
    /// The winning rule for `event`: the most-specific level (per `order`,
    /// general → specific) that has a matching rule. At one level a pinned
    /// rule beats a learned one; otherwise the newest unpinned wins ties –
    /// exactly `EmailMatcher.match()`'s resolution (calendar signal spec §4).
    public static func bestRule(rules: [CalendarRule], event: CalendarEvent,
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
    public static func learnableRule(event: CalendarEvent, for task: TaskRef,
                                     origin: EmailRule.Origin = .correction,
                                     now: Date = Date()) -> CalendarRule {
        CalendarRule(level: .titleKeyword, value: event.title, target: task,
                    pinned: false, createdAt: now, origin: origin)
    }
}
