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

    c.check("OP task page is certain (at the inferred ceiling)") {
        let a = Attributor(instanceHost: host)
        let result = a.attribute(opPage(1), tasks: tasks, now: now)
        try expectEq(result.best?.target, .task(.op(1)))
        // Capped at 0.95: 1.0 is reserved for explicit pins.
        try expectClose(result.certainty, 0.95)
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

    c.check("primed surfaces survive a snapshot round-trip (relaunch persistence)") {
        let a = Attributor(instanceHost: host)
        a.confirm(ghostty, task: .op(1))
        let snapshot = try JSONEncoder().encode(a.primedSurfaces)
        let b = Attributor(instanceHost: host)
        b.primedSurfaces = try JSONDecoder().decode([Surface: TaskRef].self, from: snapshot)
        let result = b.attribute(ghostty, tasks: tasks, now: now)
        try expectEq(result.best?.target, .task(.op(1)))
        try expectClose(result.certainty, 0.95)
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

    // MARK: - Explicit pins — 100%, override everything

    func ghTab(_ path: String) -> ActivitySignal {
        ActivitySignal(app: "Google Chrome", windowTitle: "GitHub",
                       tabURL: "https://github.com/\(path)", timestamp: now)
    }
    func componentPin(_ kind: PinScope.Kind, _ prefix: [String], to ref: TaskRef) -> Pin {
        Pin(rule: .components(PinScope(kind: kind, prefix: prefix)), task: ref)
    }

    c.check("a site-section pin covers every page beneath it at 100%") {
        let a = Attributor(instanceHost: host)
        a.upsert(componentPin(.url, ["github.com", "aqueum"], to: .op(2)))
        let r = a.attribute(ghTab("aqueum/ambitick/issues/42"), tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(2)), "section pin must cover the page")
        try expectClose(r.certainty, 1.0)
        let other = a.attribute(ghTab("someoneelse/repo"), tasks: tasks, now: now)
        try expect(other.best?.target != .task(.op(2)) || other.certainty < 1.0,
                   "pin must not leak to a different section")
    }

    c.check("a pin overrides even a work-package URL") {
        let a = Attributor(instanceHost: host)
        a.upsert(componentPin(.url, ["op.example.com"], to: .op(2)))   // whole OP domain
        let r = a.attribute(opPage(1), tasks: tasks, now: now)         // a real WP page
        try expectEq(r.best?.target, .task(.op(2)), "explicit pin is law, beats the WP URL")
        try expectClose(r.certainty, 1.0)
    }

    c.check("the most specific (longest-prefix) pin wins") {
        let a = Attributor(instanceHost: host)
        a.upsert(componentPin(.url, ["github.com"], to: .op(1)))            // whole site
        a.upsert(componentPin(.url, ["github.com", "aqueum"], to: .op(2)))  // a section
        let r = a.attribute(ghTab("aqueum/ambitick"), tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(2)), "section pin beats the site pin")
    }

    c.check("a boolean-expression pin matches across fields") {
        let a = Attributor(instanceHost: host)
        // title contains "Ambitick" AND NOT url contains "github"
        let expr = Predicate.and([
            .leaf(field: .title, op: .contains, value: "Ambitick"),
            .not(.leaf(field: .url, op: .contains, value: "github")),
        ])
        a.upsert(Pin(rule: .expression(expr), task: .op(2)))
        let hit = ActivitySignal(app: "Ghostty", windowTitle: "Ambitick — zsh", timestamp: now)
        try expectEq(a.attribute(hit, tasks: tasks, now: now).best?.target, .task(.op(2)))
        // same title but a github url → excluded by the NOT
        let miss = a.attribute(ghTab("aqueum/ambitick"), tasks: tasks, now: now)
        try expect(miss.best?.target != .task(.op(2)) || miss.certainty < 1.0)
    }

    c.check("explain mirrors the decision source and exposes the learned/prior breakdown") {
        let a = Attributor(instanceHost: host)
        let e = a.explain(ghostty, tasks: tasks, now: now)
        try expectEq(e.source, .ranked, "no pin/url/prime → ranked")
        try expect(!e.features.isEmpty, "the features the learner keys on are surfaced")
        try expect(e.lines.contains { $0.target == .task(.op(1)) }, "candidates are listed")
        try expect(e.lines.allSatisfy { abs($0.score - ($0.learned + $0.prior)) < 0.5 || $0.score <= 0.9 },
                   "each line carries its learned + prior split")

        // A primed surface (a past correction) shows as primedSurface.
        let primed = Attributor(instanceHost: host)
        primed.confirm(ghostty, task: .op(1))
        let pe = primed.explain(ghostty, tasks: tasks, now: now)
        try expectEq(pe.source, .primedSurface)
        try expectEq(pe.chosen, .task(.op(1)))

        // A pin overrides everything at 1.0.
        let pinned = Attributor(instanceHost: host)
        pinned.upsert(Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty"])), task: .op(2)))
        let pp = pinned.explain(ghostty, tasks: tasks, now: now)
        try expectEq(pp.source, .pin)
        try expectEq(pp.chosen, .task(.op(2)))
        try expectEq(pp.chosenScore, 1.0)
    }

    c.check("a cross-kind pin tie resolves by recency, not incomparable specificity") {
        // A 3-segment component pin and a 1-leaf expression both match. prefix.count
        // (3) and leafCount (1) aren't commensurable, so the winner is the most
        // recently added, not the numerically-"bigger" one.
        let sig = ActivitySignal(app: "Ghostty", windowTitle: "Ambitick", timestamp: now)
        let comp = Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty", "Ambitick"])),
                       task: .op(1))
        let expr = Pin(rule: .expression(.leaf(field: .app, op: .equals, value: "Ghostty")),
                       task: .op(2))
        let a = Attributor(instanceHost: host)
        a.upsert(comp); a.upsert(expr)                 // expression added last → wins
        try expectEq(a.matchingPin(for: sig)?.task, .op(2))
        let b = Attributor(instanceHost: host)
        b.upsert(expr); b.upsert(comp)                 // component added last → flips
        try expectEq(b.matchingPin(for: sig)?.task, .op(1))
    }

    c.check("a manual priority overrides specificity") {
        let a = Attributor(instanceHost: host)
        a.upsert(Pin(rule: .components(PinScope(kind: .url, prefix: ["github.com", "aqueum"])),
                     task: .op(2)))                                   // specificity 2
        a.upsert(Pin(rule: .components(PinScope(kind: .url, prefix: ["github.com"])),
                     task: .op(1), priority: 5))                      // looser, but prioritised
        let r = a.attribute(ghTab("aqueum/ambitick"), tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(1)), "priority beats specificity")
    }

    c.check("a pin's manual priority survives a Codable round-trip") {
        // The popover persists pins as [Pin] and reopens the editor off the
        // decoded value, so priority must survive encode/decode unchanged.
        let pin = Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty"])),
                      task: .op(1), priority: 7)
        let data = try JSONEncoder().encode(pin)
        let decoded = try JSONDecoder().decode(Pin.self, from: data)
        try expectEq(decoded.priority, 7)
        let plain = Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty"])),
                        task: .op(1))
        let decodedPlain = try JSONDecoder().decode(Pin.self,
                                                    from: try JSONEncoder().encode(plain))
        try expect(decodedPlain.priority == nil, "no priority must decode back to nil")
    }

    c.check("an ordinary correction stays SOFT (0.95), not a pin") {
        let a = Attributor(instanceHost: host)
        let myPage = ActivitySignal(app: "Chrome", windowTitle: "My page",
                                    tabURL: "https://op.example.com/my/page", timestamp: now)
        a.assign(myPage, target: .task(.op(2)))
        try expect(a.pins.isEmpty, "assign must never create a pin")
        let r = a.attribute(myPage, tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(2)), "soft prime still beats the ranker")
        try expectClose(r.certainty, 0.95)
    }

    c.check("an app pin covers the whole app at 100%") {
        let a = Attributor(instanceHost: host)
        a.upsert(componentPin(.app, ["Ghostty"], to: .op(1)))
        let r = a.attribute(ActivitySignal(app: "Ghostty", windowTitle: "anything", timestamp: now),
                            tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(1)))
        try expectClose(r.certainty, 1.0)
    }

    c.check("unpin by id removes it; upsert by id updates in place") {
        let a = Attributor(instanceHost: host)
        var pin = componentPin(.app, ["Ghostty"], to: .op(1))
        a.upsert(pin)
        pin.task = .op(2)                       // same id, new task
        a.upsert(pin)
        try expectEq(a.pins.count, 1, "upsert by id must not duplicate")
        let sig = ActivitySignal(app: "Ghostty", windowTitle: "x", timestamp: now)
        try expectEq(a.attribute(sig, tasks: tasks, now: now).best?.target, .task(.op(2)))
        a.unpin(id: pin.id)
        try expect(a.pins.isEmpty)
    }

    c.check("pins survive a snapshot round-trip (relaunch persistence)") {
        let a = Attributor(instanceHost: host)
        a.upsert(componentPin(.url, ["github.com", "aqueum"], to: .op(2)))
        let snap = try JSONEncoder().encode(a.pins)
        let b = Attributor(instanceHost: host)
        b.pins = try JSONDecoder().decode([Pin].self, from: snap)
        let r = b.attribute(ghTab("aqueum/ambitick"), tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(2)))
        try expectClose(r.certainty, 1.0)
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
