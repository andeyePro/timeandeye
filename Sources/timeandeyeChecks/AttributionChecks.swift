import Foundation
import timeandeyeCore

// MARK: - Attributor (plan task 6)

func attributorChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let host = "op.example.com"
    let tasks = [WorkTask(ref: .op(1), subject: "timeandeye build", status: "Now"),
                 WorkTask(ref: .op(2), subject: "Investment review", status: "Next")]

    func opPage(_ id: Int) -> ActivitySignal {
        ActivitySignal(app: "Chrome", windowTitle: "WP \(id)",
                       tabURL: "https://op.example.com/work_packages/\(id)", timestamp: now)
    }
    let ghostty = ActivitySignal(app: "Ghostty", windowTitle: "timeandeye", timestamp: now)

    c.check("OP task page is certain (at the inferred ceiling)") {
        let a = Attributor(instanceHost: host)
        let result = a.attribute(opPage(1), tasks: tasks, now: now)
        try expectEq(result.best?.target, .task(.op(1)))
        // Capped at 0.95: 1.0 is reserved for explicit pins.
        try expectClose(result.certainty, 0.95)
    }

    c.check("a GUID-backend recognizer attributes and dwell-primes .remote refs") {
        struct StubRecognizer: BackendPageRecognizer {
            func taskRef(inURL urlString: String) -> TaskRef? {
                urlString.contains("xero") ? .remote("g-1") : nil
            }
            func taskRef(inTitle title: String) -> TaskRef? { nil }
            func isProjectPage(_ url: URL) -> Bool { false }
        }
        let a = Attributor(instanceHost: host)
        a.customRecognizer = StubRecognizer()
        let xeroPage = ActivitySignal(app: "Chrome", windowTitle: "Job",
                                      tabURL: "https://go.xero.com/projects/x",
                                      timestamp: now)
        let result = a.attribute(xeroPage, tasks: tasks, now: now)
        try expectEq(result.best?.target, .task(.remote("g-1")))
        try expectClose(result.certainty, 0.95)
        // Dwell-priming carries the .remote ref to the working surface.
        a.noteDwell(ghostty)
        let pending = a.attribute(ghostty, tasks: tasks, now: now)
        try expectEq(pending.best?.target, .task(.remote("g-1")))
    }

    c.check("project-page boost is SCOPED to the URL's project (slug match); unknown slugs keep the old boost") {
        let a = Attributor(instanceHost: host)
        let scoped = [WorkTask(ref: .op(1), subject: "Fix the pie", project: "Alpha Beta",
                               projectID: "7", status: "Now"),
                      WorkTask(ref: .op(2), subject: "Website copy", project: "Zeta",
                               projectID: "9", status: "Now")]
        let alphaPage = ActivitySignal(app: "Chrome", windowTitle: "Alpha Beta overview",
                                       tabURL: "https://op.example.com/projects/alpha-beta/work_packages",
                                       timestamp: now)
        let onAlpha = a.attribute(alphaPage, tasks: scoped, now: now)
        try expectEq(onAlpha.best?.target, .task(.op(1)),
                     "the hinted project's task wins, not just any high-prior task")
        // The stable project ID matches too (a hand-edited slug that equals it).
        let idPage = ActivitySignal(app: "Chrome", windowTitle: "Alpha",
                                    tabURL: "https://op.example.com/projects/7/settings",
                                    timestamp: now)
        try expectEq(a.attribute(idPage, tasks: scoped, now: now).best?.target, .task(.op(1)))
        // A slug we know nothing about: fall back to the old everyone-boosted
        // behaviour rather than suppressing the ranking.
        let strange = ActivitySignal(app: "Chrome", windowTitle: "Mystery",
                                     tabURL: "https://op.example.com/projects/not-a-known-project/",
                                     timestamp: now)
        let fallback = a.attribute(strange, tasks: scoped, now: now)
        try expect(fallback.best != nil)
        // Slugifier shape: OP's kebab-case of the title.
        try expectEq(Attributor.slugified("Alpha Beta"), "alpha-beta")
        try expectEq(Attributor.slugified("R&D — phase 2!"), "r-d-phase-2")
    }

    c.check("empty task list never auto-stops: dnt gets no walkover softmax (B6)") {
        let a = Attributor(instanceHost: host)
        var learning = LearningStore()
        learning.learn(ghostty, target: .doNotTrack, weight: 5)
        a.replaceLearning(learning)
        // A transiently empty cache (startup, backend refresh): even a
        // signal LEARNED as non-work must not clear the 0.6 bar with no
        // real candidates to beat.
        let result = a.attribute(ghostty, tasks: [], now: now)
        try expectEq(result.best?.target, .doNotTrack)
        try expect(result.certainty < 0.6,
                   "no candidates ⇒ no confidence (got \(result.certainty))")
    }

    c.check("a pending prime EXPIRES: a glance can't outrank a confirmed prime forever (B8)") {
        let a = Attributor(instanceHost: host)
        a.confirm(ghostty, task: .op(1))                    // confirmed 0.95 for op(1)
        _ = a.attribute(opPage(2), tasks: tasks, now: now)  // glance at task 2's page…
        a.noteDwell(ghostty, at: now)                       // …then dwell back on the surface
        let fresh = a.attribute(ghostty, tasks: tasks, now: now.addingTimeInterval(60))
        try expectEq(fresh.best?.target, .task(.op(2)), "fresh hypothesis leads at 0.7")
        let later = a.attribute(ghostty, tasks: tasks, now: now.addingTimeInterval(1_000))
        try expectEq(later.best?.target, .task(.op(1)),
                     "past the TTL the CONFIRMED prime rules again")
        try expectClose(later.certainty, 0.95)
    }

    c.check("a correction SUBTRACTS from the displaced learned belief (B9)") {
        let a = Attributor(instanceHost: host)
        var learning = LearningStore()
        for _ in 0..<5 { learning.learn(ghostty, target: .task(.op(2)), weight: 2) }
        a.replaceLearning(learning)
        let before = a.attribute(ghostty, tasks: tasks, now: now)
        try expectEq(before.best?.target, .task(.op(2)), "the learned belief leads")
        // The user corrects to op(1): the op(2) association must lose count
        // weight (not just be outscored on this exact surface) so SIBLING
        // surfaces sharing features stop inheriting the mistake. One
        // correction doesn't have to FLIP five confirmations — it must move
        // the needle both ways.
        let beforeScores = a.learning.scores(for: ghostty,
                                             among: [.task(.op(1)), .task(.op(2))])
        a.confirm(ghostty, task: .op(1), tasks: tasks, now: now)
        let after = a.learning.scores(for: ghostty,
                                      among: [.task(.op(1)), .task(.op(2))])
        try expect((after[.task(.op(2))] ?? 0) < (beforeScores[.task(.op(2))] ?? 1),
                   "the displaced belief lost weight")
        try expect((after[.task(.op(1))] ?? 0) > (beforeScores[.task(.op(1))] ?? 0),
                   "the corrected-to task gained weight")
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

    c.check("confirming a fresh surface to a new local task primes it (auto-prime on create)") {
        // The Core half of AppController.addLocalTask(primeToCurrentSurface:):
        // a never-seen surface confirmed to a brand-new .local task must attribute
        // to it at the soft-prime ceiling on the very next attribute() — i.e. the
        // new task's time lands immediately, not on the previously-focused task.
        let a = Attributor(instanceHost: host)
        let id = UUID()
        let pre = a.attribute(ghostty, tasks: tasks, now: now)
        try expect(pre.best?.target != .task(.local(id)),
                   "surface is unbound before the create-time confirm")
        a.confirm(ghostty, task: .local(id))
        let primed = a.attribute(ghostty, tasks: tasks, now: now)
        try expectEq(primed.best?.target, .task(.local(id)))
        try expectClose(primed.certainty, 0.95)
        // Re-confirming the same surface to a different new local re-primes it,
        // so a later genuine create rebinds rather than sticking on the first.
        let id2 = UUID()
        a.confirm(ghostty, task: .local(id2))
        try expectEq(a.attribute(ghostty, tasks: tasks, now: now).best?.target,
                     .task(.local(id2)))
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
        a.upsert(componentPin(.url, ["github.com", "andeyePro"], to: .op(2)))
        let r = a.attribute(ghTab("andeyePro/timeandeye/issues/42"), tasks: tasks, now: now)
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
        a.upsert(componentPin(.url, ["github.com", "andeyePro"], to: .op(2)))  // a section
        let r = a.attribute(ghTab("andeyePro/timeandeye"), tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(2)), "section pin beats the site pin")
    }

    c.check("a boolean-expression pin matches across fields") {
        let a = Attributor(instanceHost: host)
        // title contains "timeandeye" AND NOT url contains "github"
        let expr = Predicate.and([
            .leaf(field: .title, op: .contains, value: "timeandeye"),
            .not(.leaf(field: .url, op: .contains, value: "github")),
        ])
        a.upsert(Pin(rule: .expression(expr), task: .op(2)))
        let hit = ActivitySignal(app: "Ghostty", windowTitle: "timeandeye — zsh", timestamp: now)
        try expectEq(a.attribute(hit, tasks: tasks, now: now).best?.target, .task(.op(2)))
        // same title but a github url → excluded by the NOT
        let miss = a.attribute(ghTab("andeyePro/timeandeye"), tasks: tasks, now: now)
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
        let sig = ActivitySignal(app: "Ghostty", windowTitle: "timeandeye", timestamp: now)
        let comp = Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty", "timeandeye"])),
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
        a.upsert(Pin(rule: .components(PinScope(kind: .url, prefix: ["github.com", "andeyePro"])),
                     task: .op(2)))                                   // specificity 2
        a.upsert(Pin(rule: .components(PinScope(kind: .url, prefix: ["github.com"])),
                     task: .op(1), priority: 5))                      // looser, but prioritised
        let r = a.attribute(ghTab("andeyePro/timeandeye"), tasks: tasks, now: now)
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
        a.upsert(componentPin(.url, ["github.com", "andeyePro"], to: .op(2)))
        let snap = try JSONEncoder().encode(a.pins)
        let b = Attributor(instanceHost: host)
        b.pins = try JSONDecoder().decode([Pin].self, from: snap)
        let r = b.attribute(ghTab("andeyePro/timeandeye"), tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(2)))
        try expectClose(r.certainty, 1.0)
    }

    func mail(_ correspondents: [String], subject: String) -> ActivitySignal {
        ActivitySignal(app: "Google Chrome", windowTitle: subject,
                       tabURL: "https://mail.google.com/mail/u/0/#inbox/x",
                       timestamp: now, correspondents: correspondents, emailSubject: subject)
    }

    c.check("email rule: learned from a correction, then auto-attributes by domain") {
        let a = Attributor(instanceHost: host)
        // External correspondents only (the capture removes self upstream).
        let s = mail(["r.naismith@harborlane.example", "t.calder@harborlane.example"],
                     subject: "RE: Insurance Renewals")
        try expect(a.emailRuleMatch(s) == nil, "nothing learned yet")
        // A plain confirm() no longer writes a rule (2026-07-03 §5.4
        // retirement) — this is the explicit grain commit that replaces it
        // (the card/footer's Remember, at the conservative auto-detect grain).
        a.learnEmailRule(s, to: .op(1))
        // Org domain → another person at the same company auto-attributes.
        let s2 = mail(["a.broker@harborlane.example"], subject: "New quote")
        try expectEq(a.emailRuleMatch(s2)?.target, .op(1))
        let r = a.attribute(s2, tasks: tasks, now: now)
        try expectEq(r.best?.target, .task(.op(1)))
        try expectClose(r.certainty, Attributor.inferredCeiling)
    }

    c.check("email rule: shared webmail learns the person, not the whole domain") {
        let a = Attributor(instanceHost: host)
        a.learnEmailRule(mail(["alice@gmail.com"], subject: "hi"), to: .op(2))
        try expect(a.emailRuleMatch(mail(["bob@gmail.com"], subject: "x")) == nil,
                   "a different gmail person must NOT inherit it")
        try expectEq(a.emailRuleMatch(mail(["alice@gmail.com"], subject: "y"))?.target, .op(2))
    }

    c.check("non-email signals carry no context and never match an email rule") {
        let a = Attributor(instanceHost: host)
        a.confirm(mail(["x@org.com"], subject: "s"), task: .op(1))
        try expect(EmailContext.from(ActivitySignal(app: "Ghostty", timestamp: now)) == nil)
        try expect(a.emailRuleMatch(ActivitySignal(app: "Ghostty", timestamp: now)) == nil)
    }

    c.check("ActivitySignal decodes pre-email-fields JSON without the new keys") {
        let json = #"{"app":"Ghostty","timestamp":12345}"#
        let s = try JSONDecoder().decode(ActivitySignal.self, from: Data(json.utf8))
        try expectEq(s.app, "Ghostty")
        try expect(s.correspondents == nil)
        try expect(s.emailSubject == nil)
    }

    // WHY these checks exist: Martin's 2026-07-23 ambiguous-web-page policy
    // ("Yes stay on current task (but monitor window/tab change)") needs
    // `Attribution`/`AttributionExplanation` to expose a fresh-every-call
    // "this page told us nothing" fact — no pin/sticky/URL/title/rule/
    // prime fired AND the host is genuinely unknown to both the site-rule
    // ladder and the learner. `SessionTracker` reads it to hold the running
    // task instead of switching (see SessionTrackerChecks); these two
    // checks prove the Attributor-level fact itself, in isolation.
    c.check("ambiguous web page: unknown host with nothing else fired flags true; a learned host, a site rule, or a prime keeps it false") {
        let a = Attributor(instanceHost: host)
        let unfamiliar = ActivitySignal(app: "Chrome", windowTitle: "A blog post",
                                        tabURL: "https://random-blog.example/post/42", timestamp: now)
        let r = a.attribute(unfamiliar, tasks: tasks, now: now)
        try expect(r.ambiguousSurface, "no rule/host evidence anywhere -> ambiguous")

        // A learned urlHost/urlPath association (a past correction on the
        // SAME host, a DIFFERENT page) exempts it — "a learned host still
        // switches" (non-regression requirement).
        let b = Attributor(instanceHost: host)
        b.confirm(unfamiliar, task: .op(1))
        try expect(b.learning.hasAssociation(urlHost: "random-blog.example"))
        let learnedAgain = ActivitySignal(app: "Chrome", windowTitle: "Another post",
                                          tabURL: "https://random-blog.example/post/99", timestamp: now)
        let rb = b.attribute(learnedAgain, tasks: tasks, now: now)
        try expect(!rb.ambiguousSurface, "a host the learner has heard from is no longer ambiguous")

        // A `site`-level SiteRule for the host exempts it too — it wins at
        // the .siteRule rung, long before the ranked fallback runs at all.
        let s = Attributor(instanceHost: host)
        s.siteRules = [SiteRule(recipeID: nil, field: SiteRule.siteField,
                                value: "random-blog.example", target: .op(2))]
        let rs = s.attribute(unfamiliar, tasks: tasks, now: now)
        try expectEq(rs.provenance?.source, .siteRule)
        try expect(!rs.ambiguousSurface, "a taught site rule at the host level is not ambiguous")

        // A prime firing (a remembered surface — inferred-rung evidence)
        // exempts it even though the host carries nothing else.
        let p = Attributor(instanceHost: host)
        p.confirm(unfamiliar, task: .op(1))    // primes the exact SURFACE
        let rp = p.attribute(unfamiliar, tasks: tasks, now: now)
        try expectEq(rp.provenance?.source, .primedSurface)
        try expect(!rp.ambiguousSurface, "a prime firing is rule-grade evidence, never ambiguous")

        // A non-web signal (no tab URL) is never ambiguous by this test.
        let r2 = a.attribute(ghostty, tasks: tasks, now: now)
        try expect(!r2.ambiguousSurface, "no tab URL -> not a web page -> never ambiguous")
    }

    c.check("explain() mirrors ambiguousSurface exactly — never disagrees with attribute()'s hold-or-not fact") {
        let a = Attributor(instanceHost: host)
        let unfamiliar = ActivitySignal(app: "Chrome", windowTitle: "A blog post",
                                        tabURL: "https://random-blog.example/post/42", timestamp: now)
        let attribution = a.attribute(unfamiliar, tasks: tasks, now: now)
        let explanation = a.explain(unfamiliar, tasks: tasks, now: now)
        try expectEq(attribution.ambiguousSurface, explanation.ambiguousSurface,
                    "explain() must never disagree with attribute()'s ambiguous-surface fact")
        try expect(explanation.ambiguousSurface, "the same unfamiliar host — this must actually be the ambiguous case")
        try expectEq(explanation.source, .ranked, "no new source word — the existing .ranked/.none vocabulary carries the fact")

        // A learned host mirrors false on both sides too.
        a.confirm(unfamiliar, task: .op(1))
        let learnedAgain = ActivitySignal(app: "Chrome", windowTitle: "Another post",
                                          tabURL: "https://random-blog.example/post/99", timestamp: now)
        try expectEq(a.attribute(learnedAgain, tasks: tasks, now: now).ambiguousSurface,
                    a.explain(learnedAgain, tasks: tasks, now: now).ambiguousSurface)
        try expect(!a.explain(learnedAgain, tasks: tasks, now: now).ambiguousSurface)
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
