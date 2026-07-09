import Foundation
import andeyeTTCore

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
