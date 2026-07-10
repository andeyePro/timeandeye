import Foundation
import timeandeyeCore

// MARK: - Evidence Card pure pieces (2026-07-03 context-rules spec, UI phase)

private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

private func gmailSignal(correspondents: [String] = ["r.naismith@harborlane.example"],
                         subject: String? = "Re: Insurance Renewals 2026",
                         fragment: String = "inbox/FMfcgz001") -> ActivitySignal {
    ActivitySignal(app: "Google Chrome",
                   windowTitle: "Re: Insurance Renewals 2026 - martin@example.com - Gmail",
                   tabURL: "https://mail.google.com/mail/u/0/#\(fragment)",
                   timestamp: t0, correspondents: correspondents.isEmpty ? nil : correspondents,
                   emailSubject: subject)
}

// MARK: - ContextIdentity.cardDefaultGrainIndex

func cardDefaultGrainChecks(_ c: Checks) {
    c.check("an org domain is the card's conservative default (NOT the most-specific row)") {
        let id = ContextIdentity.from(gmailSignal())
        // subject (index 4) is available and more specific, but the card's
        // default is the org domain (index 2) — mirrors learnEmailRule's
        // conservatism, not the pin editor's most-specific-available rule.
        try expectEq(id.cardDefaultGrainIndex, 2)
        try expectEq(id.segments[1].kind, .correspondentDomain)
    }

    c.check("shared webmail: the default skips the domain row to the address") {
        let id = ContextIdentity.from(gmailSignal(correspondents: ["alice@gmail.com"]))
        try expectEq(id.cardDefaultGrainIndex, 3)
        try expectEq(id.segments[2].kind, .correspondent)
    }

    c.check("no correspondent captured: the default falls to the narrowest AVAILABLE row") {
        let bare = ActivitySignal(app: "Google Chrome", windowTitle: "Draft - Gmail",
                                  tabURL: "https://mail.google.com/mail/u/0/#drafts",
                                  timestamp: t0, correspondents: nil, emailSubject: "Q3 budget")
        let id = ContextIdentity.from(bare)   // system(avail) domain/correspondent(ghost) subject(avail)
        try expectEq(id.cardDefaultGrainIndex, 4)
        try expectEq(id.segments[3].kind, .subject)
    }

    c.check("no correspondent AND no subject: the default falls all the way to the system row") {
        let bare = ActivitySignal(app: "Google Chrome", windowTitle: "Inbox - Gmail",
                                  tabURL: "https://mail.google.com/mail/u/0/#inbox", timestamp: t0)
        let id = ContextIdentity.from(bare)
        try expectEq(id.cardDefaultGrainIndex, 1)
    }

    c.check("no email grain at all: nil (a plain surface has no conservative default)") {
        let plain = ContextIdentity.from(ActivitySignal(
            app: "Google Chrome", windowTitle: "GitHub",
            tabURL: "https://github.com/andeyePro/timeandeye/issues", timestamp: t0))
        try expectNil(plain.cardDefaultGrainIndex)
    }

    // MARK: Review-row reconstruction (the drawer footer's evidence source) —
    // `ReviewSegment.signal` is the seam the post-assign grain footer builds
    // its identity from, so these pin the whole rows-to-grains path without
    // an AppController.

    c.check("a review row WITH evidence reconstructs to the card's correspondent-grain ladder") {
        let row = ReviewSegment(app: "Google Chrome",
                                windowTitle: "Re: Insurance Renewals 2026 - Gmail",
                                tabURL: "https://mail.google.com/mail/u/0/#inbox/FMfcgz001",
                                correspondents: ["r.naismith@harborlane.example"],
                                emailSubject: "Re: Insurance Renewals 2026",
                                start: t0, end: t0.addingTimeInterval(300))
        let id = ContextIdentity.from(row.signal)
        try expectEq(id.cardDefaultGrainIndex, 2,
                     "the org domain — the SAME conservative default the popover card offers")
        try expectEq(id.segments[1].value, "harborlane.example")
        try expectEq(ContextIdentity.correspondentChoices(row.signal),
                     ["r.naismith@harborlane.example"],
                     "the footer's checkbox fan-out reads the row's stored correspondents")
    }

    c.check("a review row WITHOUT evidence falls back to the system row (the pre-evidence offer)") {
        // Rows journalled before evidence capture — or where the capture
        // never delivered — degrade to the broad grain, never to no offer.
        let row = ReviewSegment(app: "Google Chrome", windowTitle: "Inbox - Gmail",
                                tabURL: "https://mail.google.com/mail/u/0/#inbox",
                                start: t0, end: t0.addingTimeInterval(300))
        let id = ContextIdentity.from(row.signal)
        try expectEq(id.cardDefaultGrainIndex, 1)
        try expect(ContextIdentity.correspondentChoices(row.signal).isEmpty)
    }

    c.check("an app-mail row (no tab URL) with evidence still offers the domain/correspondent grains") {
        // Mail.app gives no URL, so system detection ghosts — before rows
        // carried evidence such a row had NO email grain at all and the
        // footer fell back to app/window level.
        let row = ReviewSegment(app: "Mail", windowTitle: "Inbox",
                                correspondents: ["amy@harborlane.example"],
                                start: t0, end: t0.addingTimeInterval(300))
        let id = ContextIdentity.from(row.signal)
        try expectEq(id.cardDefaultGrainIndex, 2)
        try expectEq(id.segments[1].kind, .correspondentDomain)
    }
}

// MARK: - Segment -> EmailRule commit mapping (the card/footer's write path)

func emailGrainCommitMappingChecks(_ c: Checks) {
    c.check("emailMatchLevel: every email-ladder kind maps, PinScope/recipe kinds don't") {
        try expectEq(ContextIdentity.SegmentKind.emailSystem.emailMatchLevel, .emailSystem)
        try expectEq(ContextIdentity.SegmentKind.correspondentDomain.emailMatchLevel, .correspondentDomain)
        try expectEq(ContextIdentity.SegmentKind.correspondent.emailMatchLevel, .correspondent)
        try expectEq(ContextIdentity.SegmentKind.subject.emailMatchLevel, .subject)
        for kind: ContextIdentity.SegmentKind in [.app, .urlHost, .urlPath, .recipeField("client")] {
            try expectNil(kind.emailMatchLevel)
        }
    }

    c.check("emailMatchValue: the segment's own value — the system row scopes to the NAMED system") {
        // The card's label is "everything in Gmail"; an empty value would
        // commit an every-mail-system rule that disagrees with that label.
        let id = ContextIdentity.from(gmailSignal())
        let system = try unwrap(id.segments.first { $0.kind == .emailSystem })
        try expectEq(system.emailMatchValue, "gmail")
        let domain = try unwrap(id.segments.first { $0.kind == .correspondentDomain })
        try expectEq(domain.emailMatchValue, "harborlane.example")
    }
}

// MARK: - Multi-correspondent expansion (2026-07-03 spec §5.5, "later polish")

func multiCorrespondentChecks(_ c: Checks) {
    c.check("correspondentChoices lists every distinct counterparty, first-seen order, case-insensitive dedup") {
        let sig = gmailSignal(correspondents: ["r.naismith@harborlane.example",
                                               "a.broker@harborlane.example",
                                               "R.Naismith@HarborLane.example"])
        try expectEq(ContextIdentity.correspondentChoices(sig),
                     ["r.naismith@harborlane.example", "a.broker@harborlane.example"])
    }

    c.check("correspondentChoices is empty for a signal with no email context") {
        let plain = ActivitySignal(app: "Ghostty", windowTitle: "timeandeye", timestamp: t0)
        try expect(ContextIdentity.correspondentChoices(plain).isEmpty)
    }

    c.check("correspondentChoices is one address for an ordinary single-party message") {
        try expectEq(ContextIdentity.correspondentChoices(gmailSignal()),
                     ["r.naismith@harborlane.example"])
    }

    c.check("correspondentRuleValues keeps only the checked addresses, matched case-insensitively") {
        let sig = gmailSignal(correspondents: ["r.naismith@harborlane.example",
                                               "a.broker@harborlane.example"])
        try expectEq(ContextIdentity.correspondentRuleValues(sig, chosen: ["A.Broker@HarborLane.example"]),
                     ["a.broker@harborlane.example"])
    }

    c.check("correspondentRuleValues ignores a chosen value that isn't actually on the message") {
        let sig = gmailSignal(correspondents: ["r.naismith@harborlane.example",
                                               "a.broker@harborlane.example"])
        try expectEq(ContextIdentity.correspondentRuleValues(
            sig, chosen: ["r.naismith@harborlane.example", "nobody@elsewhere.com"]),
            ["r.naismith@harborlane.example"])
    }

    c.check("correspondentRuleValues preserves correspondentChoices' order, not the chosen set's") {
        let sig = gmailSignal(correspondents: ["z.person@harborlane.example",
                                               "a.person@harborlane.example"])
        try expectEq(ContextIdentity.correspondentRuleValues(
            sig, chosen: ["a.person@harborlane.example", "z.person@harborlane.example"]),
            ["z.person@harborlane.example", "a.person@harborlane.example"],
            "message order (sender first), not checkbox-set iteration order")
    }

    c.check("an empty chosen set commits nothing (the caller must no-op, not write an empty rule)") {
        let sig = gmailSignal(correspondents: ["r.naismith@harborlane.example",
                                               "a.broker@harborlane.example"])
        try expect(ContextIdentity.correspondentRuleValues(sig, chosen: []).isEmpty)
    }
}

// MARK: - RulesLedger sorting/filtering

func rulesLedgerChecks(_ c: Checks) {
    func rule(_ level: EmailMatchLevel, _ value: String, _ target: TaskRef,
             pinned: Bool = false, fireCount: Int = 0, createdAt: Date = t0) -> EmailRule {
        EmailRule(level: level, value: value, target: target, pinned: pinned,
                 createdAt: createdAt, fireCount: fireCount)
    }
    let names: [TaskRef: String] = [.op(1): "Insurance Renewals", .op(2): "andeye"]
    func nameOf(_ ref: TaskRef) -> String { names[ref] ?? "?" }

    c.check("groups by target task, task groups sorted by name (case-insensitive)") {
        let rules = [rule(.correspondentDomain, "harborlane.example", .op(1)),
                    rule(.subject, "TestFlight", .op(2))]
        let groups = RulesLedger.grouped(rules, nameOf: nameOf)
        try expectEq(groups.map(\.target), [.op(2), .op(1)], "andeye sorts before Insurance Renewals")
    }

    c.check("within a group: pinned first, then most-fired, then newest") {
        let a = rule(.correspondentDomain, "a.co", .op(1), fireCount: 2, createdAt: t0)
        let b = rule(.correspondent, "b@a.co", .op(1), pinned: true, fireCount: 0, createdAt: t0)
        let c2 = rule(.subject, "x", .op(1), fireCount: 8, createdAt: t0.addingTimeInterval(60))
        let groups = RulesLedger.grouped([a, b, c2], nameOf: nameOf)
        let group = try unwrap(groups.first { $0.target == .op(1) })
        try expectEq(group.rows, [b, c2, a], "pinned first, then fireCount desc, then newest")
    }

    c.check("search filters by rule value or task name, case-insensitively") {
        let rules = [rule(.correspondentDomain, "harborlane.example", .op(1)),
                    rule(.subject, "TestFlight", .op(2))]
        try expectEq(RulesLedger.grouped(rules, nameOf: nameOf, search: "HARBOR").map(\.target), [.op(1)])
        try expectEq(RulesLedger.grouped(rules, nameOf: nameOf, search: "andeye").map(\.target), [.op(2)])
        try expectEq(RulesLedger.grouped(rules, nameOf: nameOf, search: "nonexistent").count, 0)
    }

    c.check("empty input groups to nothing") {
        try expect(RulesLedger.grouped([], nameOf: nameOf).isEmpty)
    }
}

// MARK: - RulesLedger.exportText ("Copy rules", 2026-07-03 spec §6)

func rulesLedgerExportChecks(_ c: Checks) {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    func rule(_ level: EmailMatchLevel, _ value: String, _ target: TaskRef,
             pinned: Bool = false, fireCount: Int = 0, createdAt: Date = t0,
             lastFired: Date? = nil) -> EmailRule {
        EmailRule(level: level, value: value, target: target, pinned: pinned,
                 createdAt: createdAt, fireCount: fireCount, lastFired: lastFired)
    }
    let names: [TaskRef: String] = [.op(1): "Insurance Renewals", .op(2): "andeye"]
    func nameOf(_ ref: TaskRef) -> String { names[ref] ?? "?" }

    c.check("empty input: a plain 'nothing yet' line, not a blank string") {
        try expectEq(RulesLedger.exportText([], nameOf: nameOf), "No email rules learned or pinned yet.\n")
    }

    c.check("one task, one rule: heading + indented grain/value/provenance/fire-count line") {
        let r = rule(.correspondentDomain, "harborlane.example", .op(1), fireCount: 8)
        let text = RulesLedger.exportText([r], nameOf: nameOf, calendar: utc)
        try expectEq(text, "Insurance Renewals\n  Correspondent domain: harborlane.example · learned · 15 Jun 2025 · fired 8×\n")
    }

    c.check("pinned rule says pinned, not learned") {
        let r = rule(.correspondent, "b@a.co", .op(1), pinned: true)
        let text = RulesLedger.exportText([r], nameOf: nameOf, calendar: utc)
        try expect(text.contains("· pinned ·"), "expected 'pinned', got: \(text)")
    }

    c.check("lastFired appears when present, omitted when nil") {
        let withLast = rule(.subject, "x", .op(1), lastFired: t0.addingTimeInterval(86_400))
        try expect(RulesLedger.exportText([withLast], nameOf: nameOf, calendar: utc)
            .contains("last 16 Jun 2025"))
        let withoutLast = rule(.subject, "x", .op(1))
        try expect(!RulesLedger.exportText([withoutLast], nameOf: nameOf, calendar: utc).contains("last "))
    }

    c.check("distantPast createdAt (pre-metadata migration) omits the date, doesn't crash formatting it") {
        let r = rule(.emailSystem, "", .op(1), createdAt: .distantPast)
        let text = RulesLedger.exportText([r], nameOf: nameOf, calendar: utc)
        try expectEq(text, "Insurance Renewals\n  Email system: any mail · learned · fired 0×\n")
    }

    c.check("multiple tasks: same grouping/ordering as the ledger list, one blank line between groups") {
        let rules = [rule(.subject, "TestFlight", .op(2)),
                    rule(.correspondentDomain, "harborlane.example", .op(1), fireCount: 8)]
        let text = RulesLedger.exportText(rules, nameOf: nameOf, calendar: utc)
        try expectEq(text, """
        andeye
          Subject: TestFlight · learned · 15 Jun 2025 · fired 0×

        Insurance Renewals
          Correspondent domain: harborlane.example · learned · 15 Jun 2025 · fired 8×

        """)
    }
}

// MARK: - Pre-correction snapshot (the card's honesty fix, 2026-07-05 report)

// Martin's verbatim hardware-test verdict: the card said "Apple 71% certain,
// learned", he corrected it, and the card then claimed the corrected task was
// "the only thing I ever thought it could be, I never ever thought it was X".
// These checks pin the fix: the displaced belief is captured when the pick
// lands and stays visible in the explanation until the correction itself dies.

func correctionHistoryChecks(_ c: Checks) {
    let host = "op.example.com"
    let apple = TaskRef.op(1)
    let amazon = TaskRef.op(2)
    let third = TaskRef.op(3)
    let tasks = [WorkTask(ref: apple, subject: "Apple hardware", status: "Now"),
                 WorkTask(ref: amazon, subject: "Amazon returns", status: "Now"),
                 WorkTask(ref: third, subject: "andeye", status: "Now")]
    func ruled() -> Attributor {
        let a = Attributor(instanceHost: host)
        a.emailRules = [EmailRule(level: .correspondentDomain,
                                  value: "harborlane.example", target: apple)]
        return a
    }

    c.check("THE report: a pick snapshots the displaced belief; the explanation carries it") {
        let a = ruled()
        let sig = gmailSignal()
        try expectEq(a.explain(sig, tasks: tasks, now: t0).chosen, .task(apple),
                     "precondition: the engine believes Apple before the pick")
        a.confirm(sig, task: amazon, tasks: tasks, now: t0)
        let e = a.explain(sig, tasks: tasks, now: t0)
        try expectEq(e.source, .sessionSticky)
        try expectEq(e.chosen, .task(amazon))
        let prior = try unwrap(e.priorToCorrection, "the displaced belief must surface")
        try expectEq(prior.chosen, .task(apple))
        try expectEq(prior.source, .emailRule)
        try expectClose(prior.score, 0.95)
    }

    c.check("no history when the engine already agreed with the pick") {
        let a = ruled()
        let sig = gmailSignal()
        a.confirm(sig, task: apple, tasks: tasks, now: t0)
        try expectNil(a.explain(sig, tasks: tasks, now: t0).priorToCorrection,
                      "agreeing isn't a displacement — nothing to keep straight")
    }

    c.check("a ranked (learned-weight) belief snapshots with its real score") {
        let a = Attributor(instanceHost: host)
        var store = LearningStore()
        store.learn(gmailSignal(), target: .task(apple), weight: 2)
        a.replaceLearning(store)
        let sig = gmailSignal()
        let before = a.explain(sig, tasks: tasks, now: t0)
        try expectEq(before.source, .ranked, "precondition: the ranker answers")
        try expectEq(before.chosen, .task(apple))
        a.confirm(sig, task: amazon, tasks: tasks, now: t0)
        let prior = try unwrap(a.explain(sig, tasks: tasks, now: t0).priorToCorrection)
        try expectEq(prior.source, .ranked)
        try expectEq(prior.chosen, .task(apple))
        try expectClose(prior.score, before.chosenScore,
                        "the snapshot keeps the PRE-correction score, not a recomputed one")
    }

    c.check("re-correcting keeps the ORIGINAL belief, not the intermediate pick") {
        let a = ruled()
        let sig = gmailSignal()
        a.confirm(sig, task: amazon, tasks: tasks, now: t0)
        a.confirm(sig, task: third, tasks: tasks, now: t0)
        let e = a.explain(sig, tasks: tasks, now: t0)
        try expectEq(e.chosen, .task(third), "last word wins the decision")
        let prior = try unwrap(e.priorToCorrection)
        try expectEq(prior.chosen, .task(apple),
                     "…but the history stays anchored to what the MACHINE thought")
    }

    c.check("the forget preview lands on the pre-correction winner (the card can say so)") {
        let a = ruled()
        let sig = gmailSignal()
        a.confirm(sig, task: amazon, tasks: tasks, now: t0)
        let u = try unwrap(a.forgettable(for: sig, now: t0))
        guard case .sessionSticky = u else {
            throw CheckFailure(description: "expected the sticky to be forgettable, got \(u)")
        }
        let preview = a.explainWithout(u, sig, tasks: tasks, now: t0)
        let prior = try unwrap(a.explain(sig, tasks: tasks, now: t0).priorToCorrection)
        try expectEq(preview.chosen, prior.chosen,
                     "forgetting the correction falls back to what it thought before")
        try expect(a.explain(sig, tasks: tasks, now: t0).priorToCorrection != nil,
                   "the preview must not have consumed the snapshot")
    }

    c.check("the snapshot dies with its correction: forget and day-rollover both clear it") {
        let a = ruled()
        let sig = gmailSignal()
        a.confirm(sig, task: amazon, tasks: tasks, now: t0)
        let u = try unwrap(a.forgettable(for: sig, now: t0))
        a.forget(u, signal: sig)
        try expect(a.displacedByCorrection.isEmpty, "forget removes the history with the sticky")
        let b = ruled()
        b.confirm(sig, task: amazon, tasks: tasks, now: t0)
        let tomorrow = t0.addingTimeInterval(86_400 * 2)   // safely next day in any TZ
        let later = b.explain(sig, tasks: tasks, now: tomorrow)
        try expectNil(later.priorToCorrection, "an expired correction leaves no orphan history")
        // explain() is a READ (2026-07-10): the store prunes on the next
        // real decision, not on being looked at.
        _ = b.attribute(sig, tasks: tasks, now: tomorrow)
        try expect(b.displacedByCorrection.isEmpty, "…and the store pruned with the sticky")
    }

    c.check("forget then re-correct starts a FRESH history, never the old ghost") {
        // Review-caught contract half: after forgetting a correction, the
        // NEXT correction on the same key must snapshot what the engine
        // believes THEN - not resurrect the pre-forget story.
        let a = ruled()
        let sig = gmailSignal()
        a.confirm(sig, task: amazon, tasks: tasks, now: t0)
        let u = try unwrap(a.forgettable(for: sig, now: t0))
        a.forget(u, signal: sig)
        a.confirm(sig, task: amazon, tasks: tasks, now: t0)
        let again = a.explain(sig, tasks: tasks, now: t0)
        let prior = try unwrap(again.priorToCorrection,
                               "a fresh snapshot is captured after forget")
        try expectEq(prior.chosen, .task(apple),
                     "…of the engine's live belief, not a stale ghost")
    }

    c.check("cross-midnight re-correct does not resurrect yesterday's history") {
        // Review-caught: the prune must run BEFORE the first-displacement
        // guard, or a day-1 snapshot survives when the day-2 correction is
        // the first touch of the day (no explain tick in between).
        let a = ruled()
        let sig = gmailSignal()
        a.confirm(sig, task: amazon, tasks: tasks, now: t0)
        let tomorrow = t0.addingTimeInterval(86_400 * 2)
        // First touch of day 2 is the correction itself - no explain first.
        a.confirm(sig, task: amazon, tasks: tasks, now: tomorrow)
        let today = a.explain(sig, tasks: tasks, now: tomorrow)
        let prior = try unwrap(today.priorToCorrection,
                               "day-2 correction captures a day-2 snapshot")
        try expectEq(prior.chosen, .task(apple),
                     "…of what the engine believed at day-2, freshly pruned")
    }
}

// MARK: - Why-panel truth: recompute vs record (Martin's 2026-07-10 report)

// A slice categorised as one task must never show a BECAUSE naming another
// task as if it were the reason. `explain()` is a re-derivation from the
// CURRENT stores; for a journalled slice the stores may have moved on since
// the decision — the card reconciles via `contradicts(recorded:)` and the
// matched prime key rides on the explanation so over-broad learning is
// visible (and forgettable).
func whyPanelTruthChecks(_ c: Checks) {
    let host = "op.example.com"
    let timeAndI = TaskRef.op(223)
    let chTask = TaskRef.op(300)
    let tasks = [WorkTask(ref: timeAndI, subject: "Time&I", status: "Now"),
                 WorkTask(ref: chTask,
                          subject: "andeye Ltd confirmation statement + director ID verification",
                          status: "Now")]
    /// The Companies House email open in Gmail — the window Martin selected
    /// inside a slice whose journalled outcome was Time&I.
    let chMail = ActivitySignal(
        app: "Google Chrome",
        windowTitle: "Confirmation statement due - martin@example.com - Gmail",
        tabURL: "https://mail.google.com/mail/u/0/#inbox/CHthread1",
        timestamp: t0,
        correspondents: ["noreply@companieshouse.gov.uk"],
        emailSubject: "Confirmation statement due")

    c.check("THE report: a later correction primes the surface — the re-derivation contradicts the record and says so") {
        let a = Attributor(instanceHost: host)
        // The slice was journalled as Time&I. Later that day Martin handled
        // the email and corrected THAT context to the Companies House task:
        a.confirm(chMail, task: chTask, tasks: tasks, now: t0.addingTimeInterval(3600))
        // Next day (sticky dead, the prime persisted), the timeline card
        // re-explains the old window against today's stores:
        let e = a.explain(chMail, tasks: tasks, now: t0.addingTimeInterval(86_400 * 2))
        try expectEq(e.source, .primedSurface,
                     "\"remembered from a past correction\" — a reason that never fired here")
        try expectEq(e.chosen, .task(chTask))
        try expect(e.contradicts(recorded: .task(timeAndI)),
                   "the record says Time&I: the card must anchor BECAUSE on it")
        try expect(!e.contradicts(recorded: .task(chTask)),
                   "no contradiction when the record and the re-derivation agree")
    }

    c.check("same-day flavour: the correction's sticky also contradicts the record") {
        let a = Attributor(instanceHost: host)
        a.confirm(chMail, task: chTask, tasks: tasks, now: t0.addingTimeInterval(3600))
        let e = a.explain(chMail, tasks: tasks, now: t0.addingTimeInterval(7200))
        try expectEq(e.source, .sessionSticky)
        try expect(e.contradicts(recorded: .task(timeAndI)))
    }

    c.check("the matched prime key rides on the explanation (over-broad learning made visible)") {
        let a = Attributor(instanceHost: host)
        a.confirm(chMail, task: chTask, tasks: tasks, now: t0)
        let e = a.explain(chMail, tasks: tasks, now: t0.addingTimeInterval(86_400 * 2))
        try expectEq(e.source, .primedSurface)
        try expectEq(e.matchedSurface, Surface(signal: chMail),
                     "the exact key that fired is what the card shows and [✕ forget] removes")
        // Sources that carry their own provenance don't claim a surface key.
        let ranked = a.explain(ActivitySignal(app: "Ghostty", windowTitle: "zsh", timestamp: t0),
                               tasks: tasks, now: t0)
        try expectNil(ranked.matchedSurface)
    }

    c.check("re-explaining an OLD slice never deletes today's live stickies") {
        // The drawer/timeline/retro pass all re-explain AT THE SLICE'S OWN
        // MOMENT. The pruning sticky match treated that historical `now` as
        // "today" — merely LOOKING at yesterday's slice wiped today's
        // session stickies out of the store.
        let a = Attributor(instanceHost: host)
        a.assign(chMail, target: .task(chTask), tasks: tasks, now: t0)
        let yesterdaySlice = ActivitySignal(app: "Excel", windowTitle: "Budget.xlsx",
                                            timestamp: t0.addingTimeInterval(-86_400))
        _ = a.explain(yesterdaySlice, tasks: tasks, now: t0.addingTimeInterval(-86_400))
        _ = a.forgettable(for: yesterdaySlice, now: t0.addingTimeInterval(-86_400))
        try expectEq(a.sessionStickies.count, 1, "reads never prune")
        let r = a.attribute(chMail, tasks: tasks, now: t0.addingTimeInterval(600))
        try expectEq(r.best?.target, .task(chTask), "today's categorisation still answers")
    }

    c.check("a past-moment explain matches the stickies OF that moment's day, none other") {
        let a = Attributor(instanceHost: host)
        a.assign(chMail, target: .task(chTask), tasks: tasks, now: t0)
        // Scored at a moment two days out, today's sticky must not answer —
        // same visibility the pruning path gave, without the mutation.
        let e = a.explain(chMail, tasks: tasks, now: t0.addingTimeInterval(86_400 * 2))
        try expect(e.source != .sessionSticky, "a sticky only speaks for its own day")
        let sameDay = a.explain(chMail, tasks: tasks, now: t0.addingTimeInterval(600))
        try expectEq(sameDay.source, .sessionSticky)
    }
}
