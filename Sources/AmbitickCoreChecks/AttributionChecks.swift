import Foundation
import AmbitickCore

// MARK: - Attributor (plan task 6)

func attributorChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let host = "op.example.com"
    let tasks = [WorkTask(ref: .op(1), subject: "Ambitick build", status: "Now"),
                 WorkTask(ref: .op(2), subject: "Investment review", status: "Next")]

    func opPage(_ id: Int) -> ActivitySignal {
        ActivitySignal(app: "Chrome", windowTitle: "WP \(id)",
                       tabURL: "https://op.example.com/work_packages/\(id)", timestamp: now)
    }
    let ghostty = ActivitySignal(app: "Ghostty", windowTitle: "Ambitick", timestamp: now)

    c.check("OP task page is near-certain") {
        let a = Attributor(instanceHost: host)
        let result = a.attribute(opPage(1), tasks: tasks, now: now)
        try expectEq(result.best?.target, .task(.op(1)))
        try expectClose(result.certainty, 0.99)
    }

    c.check("priming flow: open -> dwell -> confirm") {
        let a = Attributor(instanceHost: host)
        _ = a.attribute(opPage(1), tasks: tasks, now: now)
        a.noteDwell(ghostty)
        let pending = a.attribute(ghostty, tasks: tasks, now: now)
        try expectEq(pending.best?.target, .task(.op(1)))
        try expectClose(pending.certainty, 0.7)
        a.confirm(ghostty, task: .op(1))
        let primed = a.attribute(ghostty, tasks: tasks, now: now)
        try expectEq(primed.best?.target, .task(.op(1)))
        try expectClose(primed.certainty, 0.95)
    }

    c.check("prime is consumed by first dwell only") {
        let a = Attributor(instanceHost: host)
        _ = a.attribute(opPage(1), tasks: tasks, now: now)
        a.noteDwell(ghostty)            // consumes the prime
        let other = ActivitySignal(app: "Obsidian", windowTitle: "notes", timestamp: now)
        a.noteDwell(other)              // must NOT become pending for task 1
        let result = a.attribute(other, tasks: tasks, now: now)
        try expect(abs(result.certainty - 0.7) > 0.001, "second dwell must not pend")
    }

    c.check("surface following a different OP task rebinds") {
        let a = Attributor(instanceHost: host)
        _ = a.attribute(opPage(1), tasks: tasks, now: now)
        a.noteDwell(ghostty)
        a.confirm(ghostty, task: .op(1))
        _ = a.attribute(opPage(2), tasks: tasks, now: now)
        a.noteDwell(ghostty)
        let result = a.attribute(ghostty, tasks: tasks, now: now)
        try expectEq(result.best?.target, .task(.op(2)), "pending rebind must outrank old prime")
        try expectClose(result.certainty, 0.7)
    }

    c.check("unknown signal is uncertain") {
        let a = Attributor(instanceHost: host)
        let result = a.attribute(ghostty, tasks: tasks, now: now)
        try expect(result.certainty < 0.6)
    }

    c.check("OP page without task id falls back to top-ranked task") {
        let a = Attributor(instanceHost: host)
        let sig = ActivitySignal(app: "Chrome", windowTitle: "Overview",
                                 tabURL: "https://op.example.com/projects/amb/overview",
                                 timestamp: now)
        let result = a.attribute(sig, tasks: tasks, now: now)
        try expectEq(result.best?.target, .task(.op(1)), "'Now' status ranks top")
        try expect(result.certainty >= 0.6)
    }
}

// MARK: - MinuteResolver (plan task 7)

func minuteResolverChecks(_ c: Checks) {
    let base = Date(timeIntervalSince1970: 1_750_000_020)  // NOT minute-aligned (xx:xx:20)
    let a = Target.task(.op(1))
    let b = Target.task(.op(2))
    let sig = ActivitySignal(app: "x", timestamp: Date(timeIntervalSince1970: 0))

    func span(_ t: Target, from: TimeInterval, to: TimeInterval) -> FocusSpan {
        FocusSpan(target: t, certainty: 1, signal: sig,
                  start: base.addingTimeInterval(from), end: base.addingTimeInterval(to))
    }

    c.check("dominant target wins the minute") {
        let minutes = MinuteResolver.dominantPerMinute([
            span(a, from: 0, to: 30), span(b, from: 30, to: 40),
        ])
        try expectEq(minutes.count, 1)
        try expectEq(minutes[0].target, a)
        try expectClose(minutes[0].minuteStart.timeIntervalSince1970
            .truncatingRemainder(dividingBy: 60), 0, accuracy: 0.0001,
            "minuteStart must be a wall-clock minute boundary")
    }

    c.check("spans split across minute boundaries") {
        // base is at :20, so the boundary is at +40.
        // A 0-50 (40 s in minute 1, 10 s in minute 2), B 50-100 (50 s in minute 2)
        let minutes = MinuteResolver.dominantPerMinute([
            span(a, from: 0, to: 50), span(b, from: 50, to: 100),
        ])
        try expectEq(minutes.map(\.target), [a, b])
    }

    c.check("empty input") {
        try expect(MinuteResolver.dominantPerMinute([]).isEmpty)
    }
}
