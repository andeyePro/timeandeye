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
