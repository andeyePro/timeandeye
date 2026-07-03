import Foundation
import AndeyeTTCore

func sessionStickyChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let host = "op.example.com"
    let tasks = [WorkTask(ref: .op(1), subject: "andeyeTT build", status: "Now"),
                 WorkTask(ref: .op(2), subject: "Investment review", status: "Next")]

    /// The email Martin is composing, at different moments: the draft's window
    /// title mutates as he types, the subject holds still.
    func email(title: String, subject: String = "Insurance Renewals 2026") -> ActivitySignal {
        ActivitySignal(app: "Chrome", windowTitle: title,
                       tabURL: "https://mail.google.com/mail/u/0/#drafts?compose=x",
                       timestamp: now,
                       correspondents: ["r.naismith@harborlane.example"],
                       emailSubject: subject)
    }

    c.check("THE report: categorise an email, leave, return — the choice sticks") {
        let a = Attributor(instanceHost: host)
        // An old learned rule says this correspondent's domain is task 1...
        a.emailRules = [EmailRule(level: .correspondentDomain,
                                  value: "harborlane.example", target: .op(1))]
        // ...but Martin categorises THIS email as task 2.
        a.assign(email(title: "Compose - v1"), target: .task(.op(2)), now: now)
        // He switches to another app and comes back; the draft title moved on.
        let back = a.attribute(email(title: "Compose - v2 much longer now"),
                               tasks: tasks, now: now.addingTimeInterval(1800))
        try expectEq(back.best?.target, .task(.op(2)),
                     "his categorisation outranks the old email rule")
        try expectClose(back.certainty, 0.95)
    }

    c.check("the sticky expires at the day boundary — the LEARNED rule takes over") {
        let a = Attributor(instanceHost: host)
        a.assign(email(title: "Compose"), target: .task(.op(2)), now: now)
        try expectEq(a.explain(email(title: "Compose"), tasks: tasks, now: now).source,
                     .sessionSticky, "today the sticky answers")
        let tomorrow = now.addingTimeInterval(86_400 * 2)   // safely next day in any TZ
        let later = a.explain(email(title: "Compose"), tasks: tasks, now: tomorrow)
        try expectEq(later.source, .emailRule,
                     "tomorrow the durable rule the assignment taught answers instead")
        try expectEq(later.chosen, .task(.op(2)))
        try expectEq(a.sessionStickies.count, 0, "expired stickies are pruned")
    }

    c.check("re-categorising the same email replaces the sticky (last word wins)") {
        let a = Attributor(instanceHost: host)
        a.assign(email(title: "Compose"), target: .task(.op(1)), now: now)
        a.assign(email(title: "Compose"), target: .task(.op(2)), now: now)
        let r = a.attribute(email(title: "Compose"), tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(2)))
        try expectEq(a.sessionStickies.count, 1, "replaced, not stacked")
    }

    c.check("reply prefixes collapse to the same thread: Re: Fwd: X sticks with X") {
        let a = Attributor(instanceHost: host)
        a.assign(email(title: "t", subject: "Insurance Renewals 2026"),
                 target: .task(.op(2)), now: now)
        let reply = a.attribute(email(title: "t2", subject: "Re: Fwd: insurance renewals 2026"),
                                tasks: tasks, now: now)
        try expectEq(reply.best?.target, .task(.op(2)))
    }

    c.check("an explicit pin still outranks a sticky (law beats today's word)") {
        let a = Attributor(instanceHost: host)
        a.upsert(Pin(rule: .components(PinScope(kind: .url, prefix: ["mail.google.com"])), task: .op(1)))
        a.assign(email(title: "Compose"), target: .task(.op(2)), now: now)
        let r = a.attribute(email(title: "Compose"), tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(1)))
        try expectClose(r.certainty, 1.0)
    }

    c.check("a sticky beats a backend task URL for the same context") {
        // Contrived (an email surface rarely carries a WP URL) but pins down
        // the ladder position: the user's same-day word beats URL inference.
        let a = Attributor(instanceHost: host)
        var sig = email(title: "Compose")
        sig.tabURL = "https://op.example.com/work_packages/1"
        a.assign(sig, target: .task(.op(2)), now: now)
        let r = a.attribute(sig, tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(2)))
    }

    c.check("do-not-track sticks for the session too") {
        let a = Attributor(instanceHost: host)
        a.assign(email(title: "Compose"), target: .doNotTrack, now: now)
        let r = a.attribute(email(title: "Compose later"), tasks: tasks, now: now)
        try expectEq(r.best?.target, Target.doNotTrack)
    }

    c.check("a subject-less email keys on its correspondent set") {
        let a = Attributor(instanceHost: host)
        func bare(_ title: String) -> ActivitySignal {
            ActivitySignal(app: "Chrome", windowTitle: title,
                           tabURL: "https://mail.google.com/mail/u/0/",
                           timestamp: now,
                           correspondents: ["someone@example.org"], emailSubject: nil)
        }
        a.assign(bare("Inbox (3)"), target: .task(.op(2)), now: now)
        let r = a.attribute(bare("Inbox (2)"), tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(2)))
    }

    c.check("a non-email context keys on its surface (no cross-bleed)") {
        let a = Attributor(instanceHost: host)
        let ghostty = ActivitySignal(app: "Ghostty", windowTitle: "vibe", timestamp: now)
        a.assign(ghostty, target: .task(.op(2)), now: now)
        let same = a.attribute(ghostty, tasks: tasks, now: now)
        try expectEq(same.best?.target, .task(.op(2)))
        let other = ActivitySignal(app: "Safari", windowTitle: "news", timestamp: now)
        let r = a.attribute(other, tasks: tasks, now: now)
        try expect(r.best?.target != .task(.op(2)) || r.certainty < 0.95,
                   "the sticky does not leak to unrelated surfaces")
    }

    c.check("the why-panel names the sticky as the source") {
        let a = Attributor(instanceHost: host)
        a.assign(email(title: "Compose"), target: .task(.op(2)), now: now)
        let e = a.explain(email(title: "Compose again"), tasks: tasks, now: now)
        try expectEq(e.source, .sessionSticky)
        try expectEq(e.chosen, .task(.op(2)))
    }
}
