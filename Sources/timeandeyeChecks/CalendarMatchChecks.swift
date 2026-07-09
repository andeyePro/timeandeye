import Foundation
import timeandeyeCore

// MARK: - CalendarMatcher (calendar signal spec §4, §9)

func calendarMatchChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func event(_ title: String, calendarName: String = "Work",
              attendees: [String] = [], tentative: Bool = false, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: UUID().uuidString, title: title, calendarName: calendarName,
                      attendees: attendees, start: t0, end: t0.addingTimeInterval(1_800),
                      tentative: tentative, allDay: allDay)
    }

    c.check("calendar match ladder: most-specific level wins, user order re-tunes") {
        let ev = event("Weekly Standup", calendarName: "Work",
                       attendees: ["r.naismith@harborlane.example"])
        let calRule = CalendarRule(level: .calendarName, value: "Work", target: .op(1))
        let titleRule = CalendarRule(level: .titleKeyword, value: "Standup", target: .op(2))
        let attendeeRule = CalendarRule(level: .attendee, value: "r.naismith@harborlane.example", target: .op(9))
        // Title (most specific) beats attendee beats calendar, by default.
        try expectEq(CalendarMatcher.bestRule(rules: [calRule, attendeeRule, titleRule], event: ev)?.target, .op(2))
        try expectEq(CalendarMatcher.bestRule(rules: [calRule, attendeeRule], event: ev)?.target, .op(9))
        try expectEq(CalendarMatcher.bestRule(rules: [calRule], event: ev)?.target, .op(1))
        try expectNil(CalendarMatcher.bestRule(rules: [], event: ev))
        // A pin beats a learned rule at the SAME level.
        let learnedTitle = CalendarRule(level: .titleKeyword, value: "Standup", target: .op(2))
        let pinnedTitle = CalendarRule(level: .titleKeyword, value: "Standup", target: .op(5), pinned: true)
        try expectEq(CalendarMatcher.bestRule(rules: [learnedTitle, pinnedTitle], event: ev)?.target, .op(5))
        // Re-tuning the order (attendee above title) flips precedence.
        let custom: [CalendarMatchLevel] = [.calendarName, .titleKeyword, .attendee]
        try expectEq(CalendarMatcher.bestRule(rules: [titleRule, attendeeRule], event: ev, order: custom)?.target, .op(9))
    }

    c.check("titleKeyword matches by case-insensitive substring") {
        let ev = event("Weekly Standup")
        try expectEq(CalendarMatcher.bestRule(
            rules: [CalendarRule(level: .titleKeyword, value: "standup", target: .op(1))], event: ev)?.target, .op(1))
        try expectNil(CalendarMatcher.bestRule(
            rules: [CalendarRule(level: .titleKeyword, value: "Retro", target: .op(1))], event: ev))
        // Empty value never matches (mirrors an unset-value rule matching nothing).
        try expectNil(CalendarMatcher.bestRule(
            rules: [CalendarRule(level: .titleKeyword, value: "", target: .op(1))], event: ev))
    }

    c.check("attendee matches against the lowercased attendee list") {
        let ev = event("Board sync", attendees: ["R.Naismith@HarborLane.example"])
        // CalendarEvent lowercases attendees on init.
        try expectEq(ev.attendees, ["r.naismith@harborlane.example"])
        try expectEq(CalendarMatcher.bestRule(
            rules: [CalendarRule(level: .attendee, value: "r.naismith@harborlane.example", target: .op(3))],
            event: ev)?.target, .op(3))
        // The rule's own value is also lowercased at match time.
        try expectEq(CalendarMatcher.bestRule(
            rules: [CalendarRule(level: .attendee, value: "R.NAISMITH@HARBORLANE.EXAMPLE", target: .op(3))],
            event: ev)?.target, .op(3))
        try expectNil(CalendarMatcher.bestRule(
            rules: [CalendarRule(level: .attendee, value: "someone.else@harborlane.example", target: .op(3))],
            event: ev))
    }

    c.check("calendarName matches case-insensitively against the whole calendar") {
        let ev = event("Retro", calendarName: "Client X")
        try expectEq(CalendarMatcher.bestRule(
            rules: [CalendarRule(level: .calendarName, value: "client x", target: .op(4))], event: ev)?.target, .op(4))
        try expectNil(CalendarMatcher.bestRule(
            rules: [CalendarRule(level: .calendarName, value: "Client Y", target: .op(4))], event: ev))
    }

    c.check("learnableRule teaches the conservative titleKeyword default") {
        // The narrowest, safest grain a correction should teach – never pinned.
        let ev = event("Weekly Standup", calendarName: "Work")
        let rule = CalendarMatcher.learnableRule(event: ev, for: .op(6), now: t0)
        try expectEq(rule.level, .titleKeyword)
        try expectEq(rule.value, "Weekly Standup")
        try expectEq(rule.target, .op(6))
        try expect(!rule.pinned, "a correction-taught rule is never pinned")
        try expectEq(rule.origin, .correction)
        try expectEq(rule.createdAt, t0)
        try expectEq(rule.fireCount, 0)
        try expectNil(rule.lastFired)
    }

    c.check("CalendarRule back-compat decode: a JSON without provenance fields still loads") {
        // Same wire shape a pre-metadata emailrules.json used (ContextRulesChecks'
        // emailRuleMetadataChecks precedent), ported to the calendar vocabulary.
        let legacy = #"{"level":"titleKeyword","value":"Standup","target":{"op":{"_0":1}},"pinned":false}"#
        let rule = try JSONDecoder().decode(CalendarRule.self, from: Data(legacy.utf8))
        try expectEq(rule.level, .titleKeyword)
        try expectEq(rule.value, "Standup")
        try expectEq(rule.target, .op(1))
        try expectEq(rule.createdAt, .distantPast, "missing createdAt defaults to distantPast")
        try expectEq(rule.origin, .migrated, "missing origin defaults to .migrated")
        try expectEq(rule.fireCount, 0, "missing fireCount defaults to 0")
        try expectNil(rule.lastFired, "missing lastFired defaults to nil")
        // And the migrated rule still MATCHES – it must not go inert.
        try expect(rule.matches(event("Weekly Standup")))
    }
}

// MARK: - TaskRanker calendar term (calendar signal spec §5, §9)

func calendarRankerTermChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let ranker = TaskRanker()
    func task(_ id: Int, _ subject: String, _ status: String = "Open") -> WorkTask {
        WorkTask(ref: .op(id), subject: subject, status: status)
    }

    c.check("nil calendarMatch is a total no-op – identical scores to today (regression guard)") {
        let a = task(1, "a"); let b = task(2, "b")
        let before = (ranker.score(a, at: now), ranker.score(b, at: now))
        let after = (ranker.score(a, at: now, calendarMatch: nil), ranker.score(b, at: now, calendarMatch: nil))
        try expectEq(before.0, after.0)
        try expectEq(before.1, after.1)
    }

    c.check("a live match raises the matched task's score by exactly 0.3, others unaffected") {
        let a = task(1, "a"); let b = task(2, "b")
        let baseline = ranker.score(a, at: now)
        let matched = ranker.score(a, at: now, calendarMatch: (task: .op(1), tentative: false))
        let untouched = ranker.score(b, at: now, calendarMatch: (task: .op(1), tentative: false))
        try expectEq(matched, baseline + 0.3)
        try expectEq(untouched, ranker.score(b, at: now))
    }

    c.check("a tentative match raises the score at half weight (+0.15)") {
        let a = task(1, "a")
        let baseline = ranker.score(a, at: now)
        let matched = ranker.score(a, at: now, calendarMatch: (task: .op(1), tentative: true))
        try expectEq(matched, baseline + 0.15)
    }

    c.check("the calendar term flows into recentThenRanked, moving the matched task up") {
        let a = task(1, "matched", "Open")
        let b = task(2, "other", "Open")
        let picks = ranker.recentThenRanked([b, a], at: now, calendarMatch: (task: .op(1), tentative: false))
        try expectEq(picks.first?.subject, "matched")
    }
}

// MARK: - Calendar never outranks explicit / high-certainty signals
// (calendar signal spec §2/§9; Martin 2026-07-09: "actually working in a
// pinned app, or high certainty app trumps even confirmed calendar")

func calendarPrecedenceChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let tasks = [WorkTask(ref: .op(1), subject: "meeting task", status: "Now"),
                 WorkTask(ref: .op(2), subject: "pinned work", status: "Open")]
    let ghostty = ActivitySignal(app: "Ghostty", windowTitle: "timeandeye", timestamp: now)

    c.check("a 1.0 pin outranks a CONFIRMED calendar match") {
        // A pin is law. The calendar term must stay a ranked-fallback nudge —
        // whatever the calendar says is on right now, an explicit pin on the
        // live app wins at full certainty.
        let a = Attributor(instanceHost: "op.example.com")
        a.upsert(Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty"])), task: .op(2)))
        a.currentCalendarMatch = (task: .op(1), tentative: false)
        let result = a.attribute(ghostty, tasks: tasks, now: now)
        try expectEq(result.best?.target, .task(.op(2)))
        try expectClose(result.certainty, 1.0)
    }

    c.check("a high-certainty app match (primed surface, 0.95) outranks a confirmed calendar match") {
        // "High certainty app" = a surface the user's own corrections primed.
        // It early-exits the ladder at 0.95 before the ranked path — where
        // the calendar term lives — is ever consulted.
        let a = Attributor(instanceHost: "op.example.com")
        a.primedSurfaces[Surface(signal: ghostty)] = .op(2)
        a.currentCalendarMatch = (task: .op(1), tentative: false)
        let result = a.attribute(ghostty, tasks: tasks, now: now)
        try expectEq(result.best?.target, .task(.op(2)))
        try expectClose(result.certainty, 0.95)
    }

    c.check("a calendar-boosted ranked winner stays under the 0.95 inferred ceiling") {
        // The structural half of "never overrides": even when the calendar
        // match IS the ranked winner, scoredComponents' min(0.9, …) cap keeps
        // it below every 0.95 inferred source and a pin's 1.0 — the boost can
        // break ties, never beat a real signal.
        let a = Attributor(instanceHost: "op.example.com")
        a.currentCalendarMatch = (task: .op(1), tentative: false)
        let result = a.attribute(ghostty, tasks: tasks, now: now)
        try expectEq(result.best?.target, .task(.op(1)))
        try expect(result.certainty <= 0.9,
                   "ranked path must cap at 0.9, got \(result.certainty)")
    }
}

// MARK: - CalendarAlerts (Martin's 2026-07-09 alert design: quiet pulse in
// the lead-up, one violent flash at start, no retroactive alerts)

func calendarAlertChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let lead: TimeInterval = 300   // the 5-minute default
    func event(_ title: String, startsIn: TimeInterval, duration: TimeInterval = 1_800,
               tentative: Bool = false, allDay: Bool = false,
               id: String = UUID().uuidString) -> CalendarEvent {
        CalendarEvent(id: id, title: title, calendarName: "Work", attendees: [],
                      start: t0.addingTimeInterval(startsIn),
                      end: t0.addingTimeInterval(startsIn + duration),
                      tentative: tentative, allDay: allDay)
    }
    func phase(_ events: [CalendarEvent], at: TimeInterval,
               lead: TimeInterval = 300, fired: Set<String> = []) -> CalendarAlertPhase {
        CalendarAlerts.phase(events: events, at: t0.addingTimeInterval(at),
                             leadSeconds: lead, alreadyFired: fired)
    }

    c.check("the pulse window is exactly [start − lead, start): before → none, inside → preMeeting, at start → the flash takes over") {
        let ev = event("Standup", startsIn: 600)
        try expectEq(phase([ev], at: 0), .none, "10 min out is outside a 5-min lead")
        try expectEq(phase([ev], at: 300), .preMeeting(ev), "the window opens at start − lead")
        try expectEq(phase([ev], at: 599), .preMeeting(ev))
        // AT start the pulse yields — the violent flash owns the moment.
        try expectEq(phase([ev], at: 600), .starting(ev))
    }

    c.check("the start flash fires once, within the grace window only — never retroactively") {
        let ev = event("Standup", startsIn: 0)
        try expectEq(phase([ev], at: 0), .starting(ev))
        // Launching (or waking) 59 s late still flashes: barely late is
        // exactly when the nudge helps.
        try expectEq(phase([ev], at: 59), .starting(ev))
        // Past the grace with no flash recorded: the moment is gone — a
        // violent alert about a meeting well underway is noise (this is the
        // app-launched-mid-event case).
        try expectEq(phase([ev], at: 60), .none)
        // Already fired: never again for the same occurrence.
        try expectEq(phase([ev], at: 30, fired: [ev.occurrenceKey]), .none)
    }

    c.check("a tentative invite pulses but never gets the violent flash") {
        // 'Maybe' shouldn't shout as loud as 'yes' (spec §0 Q2's principle,
        // extended to the alerts): the quiet pulse still tells you it's
        // coming; the unmissable flash is reserved for meetings you said
        // yes to.
        let ev = event("Maybe sync", startsIn: 120, tentative: true)
        try expectEq(phase([ev], at: 0), .preMeeting(ev))
        try expectEq(phase([ev], at: 120), .none)
    }

    c.check("all-day events never alert") {
        // An all-day 'Annual leave' banner has no start worth being late
        // for — same reasoning that keeps all-day events out of the live
        // prior (§3).
        let ev = event("Annual leave", startsIn: 60, duration: 86_400, allDay: true)
        try expectEq(phase([ev], at: 0), .none)
        try expectEq(phase([ev], at: 60), .none)
    }

    c.check("back-to-back events each alert: the next event's pulse runs while the first is live") {
        let a = event("First", startsIn: 0)                  // ends at 1800
        let b = event("Second", startsIn: 1_800)             // starts as A ends
        let fired: Set<String> = [a.occurrenceKey]           // A's flash already fired
        try expectEq(phase([a, b], at: 1_600, fired: fired), .preMeeting(b),
                     "B's lead-up pulses even though A is still on")
        try expectEq(phase([a, b], at: 1_800, fired: fired), .starting(b),
                     "B gets its own start flash")
    }

    c.check("the soonest start wins the pulse; a due flash beats any pulse") {
        let sooner = event("Sooner", startsIn: 200)
        let later = event("Later", startsIn: 250)
        try expectEq(phase([later, sooner], at: 0), .preMeeting(sooner))
        // A start flash due NOW outranks another event's lead-up.
        let startingNow = event("Now", startsIn: 0)
        try expectEq(phase([later, startingNow], at: 0), .starting(startingNow))
    }

    c.check("recurring occurrences alert independently (occurrenceKey, not bare id)") {
        // EventKit gives every instance of a recurring series the SAME
        // eventIdentifier — deduplicating on id alone would let one standup
        // silence every future standup.
        let today = event("Standup", startsIn: 0, id: "recurring")
        let tomorrow = event("Standup", startsIn: 86_400, id: "recurring")
        try expect(today.occurrenceKey != tomorrow.occurrenceKey)
        try expectEq(phase([today, tomorrow], at: 86_400, fired: [today.occurrenceKey]),
                     .starting(tomorrow))
    }

    c.check("lead 0 (pre-meeting alert off) means no pulse window at all") {
        let ev = event("Standup", startsIn: 120)
        try expectEq(phase([ev], at: 0, lead: 0), .none)
        // The start flash is independent of the pulse's lead.
        try expectEq(phase([ev], at: 120, lead: 0), .starting(ev))
    }

    c.check("nextBoundary walks lead-open, start, grace-expiry, end in order") {
        let ev = event("Standup", startsIn: 600)   // lead 300 → boundaries 300/600/660/2400
        try expectEq(CalendarAlerts.nextBoundary(events: [ev], after: t0, leadSeconds: lead),
                     t0.addingTimeInterval(300))
        try expectEq(CalendarAlerts.nextBoundary(events: [ev], after: t0.addingTimeInterval(300),
                                                 leadSeconds: lead),
                     t0.addingTimeInterval(600))
        try expectEq(CalendarAlerts.nextBoundary(events: [ev], after: t0.addingTimeInterval(600),
                                                 leadSeconds: lead),
                     t0.addingTimeInterval(660))
        try expectEq(CalendarAlerts.nextBoundary(events: [ev], after: t0.addingTimeInterval(660),
                                                 leadSeconds: lead),
                     t0.addingTimeInterval(2_400))
        try expectNil(CalendarAlerts.nextBoundary(events: [ev], after: t0.addingTimeInterval(2_400),
                                                  leadSeconds: lead),
                      "nothing ahead — no timer needed until the window refreshes")
    }
}
