import Foundation
import andeyeTTCore

// MARK: - Context rules core model (2026-07-03 Evidence Card spec, MVP items 1-3)

private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

/// The Gmail message everything below keys on. Capture ON form (correspondents
/// present); pass empty to model today's capture-off signals.
private func gmailSignal(correspondents: [String] = ["r.naismith@harborlane.example"],
                         subject: String? = "Re: Insurance Renewals 2026",
                         title: String = "Re: Insurance Renewals 2026 - martin@example.com - Gmail",
                         fragment: String = "inbox/FMfcgz001",
                         at time: Date = t0) -> ActivitySignal {
    ActivitySignal(app: "Google Chrome", windowTitle: title,
                   tabURL: "https://mail.google.com/mail/u/0/#\(fragment)",
                   timestamp: time,
                   correspondents: correspondents.isEmpty ? nil : correspondents,
                   emailSubject: subject)
}

// MARK: - ContextIdentity

func contextIdentityChecks(_ c: Checks) {
    c.check("an email surface chains system → domain → correspondent → subject (default ladder)") {
        let id = ContextIdentity.from(gmailSignal())
        try expectEq(id.segments.map(\.kind),
                     [.emailSystem, .correspondentDomain, .correspondent, .subject])
        try expectEq(id.segments.map(\.value),
                     ["gmail", "harborlane.example", "r.naismith@harborlane.example",
                      "insurance renewals 2026"])
        try expectEq(id.segments[0].display, "Gmail")
        try expect(id.segments[3].value == "insurance renewals 2026",
                   "subject value is the normalised thread key (Re: stripped)")
        try expect(id.segments[3].display.contains("Re: Insurance Renewals 2026"),
                   "subject display keeps the raw form")
        try expect(id.segments.allSatisfy(\.available))
        try expect(!id.segments[1].shared, "an org domain is not shared webmail")
    }

    c.check("reordering the ladder reorders the chain app-wide") {
        let order: [EmailMatchLevel] = [.emailSystem, .subject, .correspondent, .correspondentDomain]
        let id = ContextIdentity.from(gmailSignal(), order: order)
        try expectEq(id.segments.map(\.kind),
                     [.emailSystem, .subject, .correspondent, .correspondentDomain])
        // Attributor.identity(of:) follows ITS user-configured order.
        let a = Attributor(instanceHost: "op.example.com")
        a.emailMatchOrder = order
        try expectEq(a.identity(of: gmailSignal()).segments.map(\.kind),
                     id.segments.map(\.kind))
    }

    c.check("a shared-webmail domain segment carries the caution flag") {
        let id = ContextIdentity.from(gmailSignal(correspondents: ["alice@gmail.com"]))
        let domain = try unwrap(id.segments.first { $0.kind == .correspondentDomain })
        try expectEq(domain.value, "gmail.com")
        try expect(domain.shared, "gmail.com matches everyone — caution tint")
    }

    c.check("capture-off Gmail: rows are ghosts, never hidden (absence IS the signal)") {
        // Today's live case — a mail host but nil correspondents/subject.
        let bare = ActivitySignal(app: "Google Chrome", windowTitle: "Inbox - Gmail",
                                  tabURL: "https://mail.google.com/mail/u/0/#inbox",
                                  timestamp: t0)
        let id = ContextIdentity.from(bare)
        try expectEq(id.segments.count, 4, "all four ladder rows render")
        try expect(id.segments[0].available, "the system IS known (Gmail)")
        for seg in id.segments.dropFirst() {
            try expect(!seg.available, "\(seg.kind) must be a not-captured ghost")
            try expectEq(seg.display, "not captured")
        }
    }

    c.check("a plain URL surface is the PinScope chain: host then path segments") {
        // A RECIPE-LESS host deliberately (github.com now builds the ◆ recipe
        // chain — SiteRecipeChecks own that shape; this check pins the
        // regression the site-recipes spec §10.3 demands: everything else is
        // byte-for-byte the pre-recipe chain).
        let sig = ActivitySignal(app: "Google Chrome", windowTitle: "Forum",
                                 tabURL: "https://forum.example.com/andeyePro/andeyeTT/issues",
                                 timestamp: t0)
        let id = ContextIdentity.from(sig)
        try expectEq(id.segments.map(\.kind), [.urlHost, .urlPath, .urlPath, .urlPath])
        try expectEq(id.segments.map(\.value), ["forum.example.com", "andeyePro", "andeyeTT", "issues"])
        try expectEq(id.segments.map(\.value),
                     PinScope.identity(of: sig)?.segments ?? [],
                     "chain values must equal the pin editor's identity segments")
    }

    c.check("an app window chains app then title segments") {
        let sig = ActivitySignal(app: "Ghostty", windowTitle: "andeyeTT — vim",
                                 timestamp: t0)
        let id = ContextIdentity.from(sig)
        try expectEq(id.segments.map(\.value), ["Ghostty", "andeyeTT", "vim"])
        try expect(id.segments.allSatisfy { $0.kind == .app })
    }

    c.check("recipe fields splice in after the root (the beyond-email extension point)") {
        let sig = ActivitySignal(app: "Google Chrome", windowTitle: "Acme",
                                 tabURL: "https://crm.foocorp.com/clients/9",
                                 timestamp: t0)
        let id = ContextIdentity.from(sig, recipeFields: [(name: "client", value: "Acme Ltd")])
        try expectEq(id.segments[0].kind, .urlHost)
        try expectEq(id.segments[1].kind, .recipeField("client"))
        try expectEq(id.segments[1].value, "Acme Ltd")
    }
}

// MARK: - Pin editor grain ladder (2026-07-03 context-rules spec, pin-editor slice)

func pinGrainChecks(_ c: Checks) {
    c.check("isEmailGrain: true for the four email levels, false for PinScope/recipe kinds") {
        for kind: ContextIdentity.SegmentKind in [.emailSystem, .correspondentDomain, .correspondent, .subject] {
            try expect(kind.isEmailGrain, "\(kind) must be an email grain")
        }
        for kind: ContextIdentity.SegmentKind in [.app, .urlHost, .urlPath, .recipeField("client")] {
            try expect(!kind.isEmailGrain, "\(kind) must not be an email grain")
        }
    }

    c.check("domain/correspondent/subject grains map to a single Expression leaf") {
        let id = ContextIdentity.from(gmailSignal())
        let domain = try unwrap(id.segments.first { $0.kind == .correspondentDomain })
        try expectEq(domain.pinPredicate, .leaf(field: .sender, op: .contains, value: "harborlane.example"))
        let correspondent = try unwrap(id.segments.first { $0.kind == .correspondent })
        try expectEq(correspondent.pinPredicate,
                     .leaf(field: .sender, op: .equals, value: "r.naismith@harborlane.example"))
        let subject = try unwrap(id.segments.first { $0.kind == .subject })
        try expectEq(subject.pinPredicate,
                     .leaf(field: .subject, op: .contains, value: "insurance renewals 2026"))
    }

    c.check("the system grain and every PinScope/recipe kind stay off the Expression path") {
        let id = ContextIdentity.from(gmailSignal())
        let system = try unwrap(id.segments.first { $0.kind == .emailSystem })
        try expectNil(system.pinPredicate, "system/site grains keep the .components(PinScope) path")
        let plain = ContextIdentity.from(ActivitySignal(
            app: "Google Chrome", windowTitle: "GitHub",
            tabURL: "https://github.com/andeyePro/andeyeTT/issues", timestamp: t0))
        for seg in plain.segments {
            try expectNil(seg.pinPredicate, "\(seg.kind) is a PinScope kind, never an Expression leaf")
        }
    }

    c.check("a ghost segment never yields a predicate, even at a normally-mappable level") {
        let bare = ActivitySignal(app: "Google Chrome", windowTitle: "Inbox - Gmail",
                                  tabURL: "https://mail.google.com/mail/u/0/#inbox", timestamp: t0)
        let id = ContextIdentity.from(bare)
        for seg in id.segments.dropFirst() {   // domain/correspondent/subject, all ghosts here
            try expectNil(seg.pinPredicate, "a not-captured \(seg.kind) row can't be pinned")
        }
    }

    c.check("defaultGrainCount picks the most specific AVAILABLE row") {
        let full = ContextIdentity.from(gmailSignal())
        try expectEq(full.defaultGrainCount, 4, "every row captured — subject (narrowest) wins")
        let bare = ActivitySignal(app: "Google Chrome", windowTitle: "Inbox - Gmail",
                                  tabURL: "https://mail.google.com/mail/u/0/#inbox", timestamp: t0)
        try expectEq(ContextIdentity.from(bare).defaultGrainCount, 1, "only the system row is captured")
        try expectEq(ContextIdentity(segments: []).defaultGrainCount, 0, "nothing to default to")
    }

    c.check("steppedGrainCount narrows/widens and skips ghosts, never landing on one") {
        let bareSubject = ActivitySignal(app: "Google Chrome", windowTitle: "Draft - Gmail",
                                         tabURL: "https://mail.google.com/mail/u/0/#drafts",
                                         timestamp: t0, correspondents: nil,
                                         emailSubject: "Q3 budget")
        let id = ContextIdentity.from(bareSubject)   // system(avail) domain/correspondent(ghost) subject(avail)
        try expectEq(id.segments.map(\.available), [true, false, false, true])
        // Narrowing from the system row must jump straight past both ghosts to subject.
        try expectEq(id.steppedGrainCount(from: 1, narrower: true), 4)
        // Already at the narrowest available — narrower again is a no-op.
        try expectEq(id.steppedGrainCount(from: 4, narrower: true), 4)
        // Widening from subject jumps straight back to the system row.
        try expectEq(id.steppedGrainCount(from: 4, narrower: false), 1)
        // Already at the widest available — wider again is a no-op.
        try expectEq(id.steppedGrainCount(from: 1, narrower: false), 1)
    }

    c.check("steppedGrainCount on an all-available chain behaves like the plain prefix strip") {
        let id = ContextIdentity.from(gmailSignal())
        try expectEq(id.steppedGrainCount(from: 1, narrower: true), 2)
        try expectEq(id.steppedGrainCount(from: 2, narrower: true), 3)
        try expectEq(id.steppedGrainCount(from: 3, narrower: true), 4)
        try expectEq(id.steppedGrainCount(from: 4, narrower: true), 4, "can't narrow past the last segment")
        try expectEq(id.steppedGrainCount(from: 4, narrower: false), 3)
        try expectEq(id.steppedGrainCount(from: 1, narrower: false), 1, "can't widen past the first segment")
    }

    c.check("pinEmailIdentity gates on an email-kind segment, not merely a URL host") {
        // A plain, non-mail URL: no email-kind segment anywhere in the chain.
        let plain = ContextIdentity.from(ActivitySignal(
            app: "Google Chrome", windowTitle: "GitHub",
            tabURL: "https://github.com/andeyePro/andeyeTT/issues", timestamp: t0))
        try expect(!plain.segments.contains { $0.kind.isEmailGrain },
                   "a plain URL chain carries no email grain to gate on")
        // A detected mail host, even capture-off, DOES carry one (the system row).
        let bareGmail = ContextIdentity.from(ActivitySignal(
            app: "Google Chrome", windowTitle: "Inbox - Gmail",
            tabURL: "https://mail.google.com/mail/u/0/#inbox", timestamp: t0))
        try expect(bareGmail.segments.contains { $0.kind.isEmailGrain })
    }
}

// MARK: - EmailRule metadata + migration

func emailRuleMetadataChecks(_ c: Checks) {
    c.check("a pre-metadata emailrules.json (stale 2026-06-30 rules) still decodes") {
        // Byte-for-byte what learnEmailRule persisted before metadata existed.
        let legacy = #"[{"level":"correspondentDomain","value":"harborlane.example","target":{"op":{"_0":7}},"pinned":false}]"#
        let rules = try JSONDecoder().decode([EmailRule].self, from: Data(legacy.utf8))
        let r = try unwrap(rules.first)
        try expectEq(r.level, .correspondentDomain)
        try expectEq(r.target, .op(7))
        try expectEq(r.createdAt, .distantPast, "unknown age migrates to distantPast")
        try expectEq(r.origin, .migrated)
        try expectEq(r.fireCount, 0)
        try expectNil(r.lastFired)
        // And the migrated rule still MATCHES — it must not go inert.
        let ctx = EmailContext(system: .gmail,
                               correspondents: ["t.calder@harborlane.example"], subject: nil)
        try expect(r.matches(ctx))
    }

    c.check("metadata round-trips through JSON (the post-migration steady state)") {
        let rule = EmailRule(level: .correspondent, value: "a@b.co", target: .op(1),
                             createdAt: t0, origin: .card, fireCount: 8,
                             lastFired: t0.addingTimeInterval(60))
        let back = try JSONDecoder().decode(EmailRule.self, from: JSONEncoder().encode(rule))
        try expectEq(back, rule)
    }

    c.check("a WINNING attribute() bumps fireCount/lastFired; explain() never does") {
        let a = Attributor(instanceHost: "op.example.com")
        let tasks = [WorkTask(ref: .op(1), subject: "Insurance", status: "Now")]
        a.emailRules = [EmailRule(level: .correspondentDomain,
                                  value: "harborlane.example", target: .op(1), createdAt: t0)]
        let sig = gmailSignal()
        _ = a.explain(sig, tasks: tasks, now: t0)
        try expectEq(a.emailRules[0].fireCount, 0, "explaining is not firing")
        _ = a.attribute(sig, tasks: tasks, now: t0)
        let later = t0.addingTimeInterval(600)
        _ = a.attribute(sig, tasks: tasks, now: later)
        try expectEq(a.emailRules[0].fireCount, 2)
        try expectEq(a.emailRules[0].lastFired, later)
    }

    c.check("onFirstFire fires exactly once, on the fireCount 0→1 transition (the First-FIRE toast hook)") {
        let a = Attributor(instanceHost: "op.example.com")
        let tasks = [WorkTask(ref: .op(1), subject: "Insurance", status: "Now")]
        a.emailRules = [EmailRule(level: .correspondentDomain,
                                  value: "harborlane.example", target: .op(1), createdAt: t0)]
        var fired: [EmailRule] = []
        a.onFirstFire = { fired.append($0) }
        let sig = gmailSignal()
        _ = a.attribute(sig, tasks: tasks, now: t0)
        try expectEq(fired.count, 1, "the FIRST win notifies")
        try expectEq(fired[0].value, "harborlane.example")
        try expectEq(fired[0].fireCount, 1, "the rule passed to the hook already reflects the fire")
        _ = a.attribute(sig, tasks: tasks, now: t0.addingTimeInterval(600))
        _ = a.attribute(sig, tasks: tasks, now: t0.addingTimeInterval(1200))
        try expectEq(fired.count, 1, "every later win is silent — only the FIRST ever notifies")
    }

    c.check("onFirstFire never fires from explain() — only a real attribute() win") {
        let a = Attributor(instanceHost: "op.example.com")
        let tasks = [WorkTask(ref: .op(1), subject: "Insurance", status: "Now")]
        a.emailRules = [EmailRule(level: .correspondentDomain,
                                  value: "harborlane.example", target: .op(1), createdAt: t0)]
        var fired: [EmailRule] = []
        a.onFirstFire = { fired.append($0) }
        _ = a.explain(gmailSignal(), tasks: tasks, now: t0)
        try expect(fired.isEmpty, "previewing/explaining must never trip the first-fire hook")
    }

    c.check("a forgotten-then-retaught rule fires onFirstFire again (a fresh rule, not the same one)") {
        let a = Attributor(instanceHost: "op.example.com")
        let tasks = [WorkTask(ref: .op(1), subject: "Insurance", status: "Now")]
        let sig = gmailSignal()
        a.learnEmailRule(sig, to: .op(1), level: .correspondentDomain,
                        value: "harborlane.example", now: t0)
        var fired: [EmailRule] = []
        a.onFirstFire = { fired.append($0) }
        _ = a.attribute(sig, tasks: tasks, now: t0)
        try expectEq(fired.count, 1)
        a.forget(.emailRule(a.emailRules[0]), signal: sig)
        a.learnEmailRule(sig, to: .op(1), level: .correspondentDomain,
                        value: "harborlane.example", now: t0)
        _ = a.attribute(sig, tasks: tasks, now: t0.addingTimeInterval(60))
        try expectEq(fired.count, 2, "the re-taught rule is fresh (fireCount reset) — it fires again")
    }

    c.check("learnEmailRule stamps provenance (createdAt = correction time, origin = correction)") {
        let a = Attributor(instanceHost: "op.example.com")
        // Called directly: `confirm` no longer calls this silently (2026-07-03
        // §5.4) — see the retirement check below.
        a.learnEmailRule(gmailSignal(), to: .op(1), now: t0)
        let rule = try unwrap(a.emailRules.first)
        try expectEq(rule.createdAt, t0)
        try expectEq(rule.origin, .correction)
    }

    c.check("confirm/assign no longer silently learn an email rule (retired 2026-07-03 §5.4)") {
        let a = Attributor(instanceHost: "op.example.com")
        a.confirm(gmailSignal(), task: .op(1), now: t0)
        try expect(a.emailRules.isEmpty,
                   "a plain correction proposes via the card/footer, never writes silently")
        let b = Attributor(instanceHost: "op.example.com")
        b.assign(gmailSignal(), target: .task(.op(2)), now: t0)
        try expect(b.emailRules.isEmpty)
    }

    c.check("learnEmailRule with an explicit level/value bypasses auto-detection (the card/footer's write path)") {
        let a = Attributor(instanceHost: "op.example.com")
        // An explicit ADDRESS grain even though the domain isn't shared — the
        // card lets the user pick a narrower grain than the conservative
        // default the auto-detect path would have chosen.
        a.learnEmailRule(gmailSignal(), to: .op(1),
                         level: .correspondent, value: "r.naismith@harborlane.example",
                         pinned: true, origin: .card, now: t0)
        let rule = try unwrap(a.emailRules.first)
        try expectEq(rule.level, .correspondent)
        try expectEq(rule.pinned, true)
        try expectEq(rule.origin, .card)
        // A different person at the same domain must NOT match (address-grain,
        // not the domain the auto-detect path would have chosen).
        try expectNil(a.emailRuleMatch(gmailSignal(correspondents: ["a.broker@harborlane.example"])))
    }

    c.check("explain() carries the matched rule with its metadata (the card never re-derives)") {
        let a = Attributor(instanceHost: "op.example.com")
        let tasks = [WorkTask(ref: .op(1), subject: "Insurance", status: "Now")]
        a.emailRules = [EmailRule(level: .correspondentDomain,
                                  value: "harborlane.example", target: .op(1),
                                  createdAt: t0, origin: .migrated, fireCount: 8)]
        let e = a.explain(gmailSignal(), tasks: tasks, now: t0)
        try expectEq(e.source, .emailRule)
        let carried = try unwrap(e.matchedEmailRule)
        try expectEq(carried.fireCount, 8)
        try expectEq(carried.origin, .migrated)
        // A pin source carries the pin the same way.
        let p = Attributor(instanceHost: "op.example.com")
        let pin = Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty"])), task: .op(2))
        p.upsert(pin)
        let pe = p.explain(ActivitySignal(app: "Ghostty", timestamp: t0), tasks: tasks, now: t0)
        try expectEq(pe.matchedPin, pin)
    }
}

// MARK: - Surface identity: mail fragments

func surfaceFragmentChecks(_ c: Checks) {
    c.check("Gmail messages are DIFFERENT surfaces (fragment carries the thread)") {
        let inbox = gmailSignal(fragment: "inbox")
        let msgA = gmailSignal(fragment: "inbox/FMfcgzA")
        let msgB = gmailSignal(fragment: "inbox/FMfcgzB")
        try expect(Surface(signal: inbox) != Surface(signal: msgA),
                   "the inbox list and an open message must not collapse")
        try expect(Surface(signal: msgA) != Surface(signal: msgB),
                   "two messages must not collapse to one all-of-Gmail surface")
        try expectEq(Surface(signal: msgA), Surface(signal: msgA), "same thread = same surface")
        try expectEq(Surface(signal: msgA).detail, "mail.google.com/mail/u/0#inbox/FMfcgzA")
    }

    c.check("one Gmail correction no longer re-points ALL of Gmail (the RC2 collapse)") {
        let a = Attributor(instanceHost: "op.example.com")
        let tasks = [WorkTask(ref: .op(1), subject: "GUT", status: "Now"),
                     WorkTask(ref: .op(2), subject: "andeye", status: "Next")]
        // Correct ONE message (capture off — no email context, so the prime
        // and sticky key on the surface alone).
        let msgA = gmailSignal(correspondents: [], subject: nil, fragment: "inbox/FMfcgzA")
        a.assign(msgA, target: .task(.op(1)), now: t0)
        // A DIFFERENT message must not inherit it at prime/sticky strength.
        let msgB = gmailSignal(correspondents: [], subject: nil, fragment: "inbox/FMfcgzB")
        let r = a.attribute(msgB, tasks: tasks, now: t0)
        try expect(r.best?.target != .task(.op(1)) || r.certainty < 0.95,
                   "the correction must stay on its own thread")
    }

    c.check("fragments lift on every known-mail host, only there") {
        let outlook = ActivitySignal(app: "Chrome", windowTitle: "Mail",
                                     tabURL: "https://outlook.office.com/mail/#id/AQkAD",
                                     timestamp: t0)
        try expect(Surface(signal: outlook).detail.contains("#id/AQkAD"))
        let unknownMail = ActivitySignal(app: "Chrome", windowTitle: "Mail",
                                         tabURL: "https://mail.example.com/box#msg42",
                                         timestamp: t0)
        try expectEq(Surface(signal: unknownMail).detail, "mail.example.com/box",
                     "an unrecognised host is NOT a mail host — no fragment lift")
    }

    c.check("a non-mail URL's surface is byte-identical to before (persisted keys keep matching)") {
        let sig = ActivitySignal(app: "Google Chrome", windowTitle: "readme",
                                 tabURL: "https://github.com/andeyePro/andeyeTT#readme",
                                 timestamp: t0)
        // The exact Surface the pre-fix code produced for this signal:
        let legacy = Surface(app: "Google Chrome", detail: "github.com/andeyePro/andeyeTT")
        try expectEq(Surface(signal: sig), legacy)
        // Canonical (.sortedKeys) bytes — plain JSONEncoder key order is
        // nondeterministic run-to-run, which made the raw byte comparison
        // flaky ("expected 66 bytes, got 66 bytes"). What persisted-key
        // matching actually needs is field/value identity: primed.json keys
        // are matched by DECODED Surface equality (asserted above and by the
        // prime firing below), not by byte equality on disk.
        let canonical = JSONEncoder()
        canonical.outputFormatting = [.sortedKeys]
        try expectEq(try canonical.encode(Surface(signal: sig)),
                     try canonical.encode(legacy),
                     "canonical encodings must match field-for-field")
        // And a persisted prime under the legacy key still fires.
        let a = Attributor(instanceHost: "op.example.com")
        a.primedSurfaces[legacy] = .op(3)
        let r = a.attribute(sig, tasks: [WorkTask(ref: .op(3), subject: "x", status: "Now")],
                            now: t0)
        try expectEq(r.best?.target, .task(.op(3)))
        try expectClose(r.certainty, 0.95)
    }

    c.check("a fragment-less Gmail URL keeps its legacy surface key") {
        let sig = ActivitySignal(app: "Chrome", windowTitle: "Gmail",
                                 tabURL: "https://mail.google.com/mail/u/0/", timestamp: t0)
        try expectEq(Surface(signal: sig).detail, "mail.google.com/mail/u/0")
    }
}

// MARK: - Correspondent features in the learner

func correspondentFeatureChecks(_ c: Checks) {
    c.check("an email signal featurises WHO the mail is with; a plain signal doesn't") {
        let feats = LearningStore.features(from: gmailSignal())
        try expect(feats.contains(Feature(.correspondent, "r.naismith@harborlane.example")))
        try expect(feats.contains(Feature(.correspondentDomain, "harborlane.example")))
        let plain = LearningStore.features(from: ActivitySignal(
            app: "Ghostty", windowTitle: "r.naismith@harborlane.example", timestamp: t0))
        try expect(!plain.contains { $0.kind == .correspondent || $0.kind == .correspondentDomain },
                   "no email context (capture off / non-mail) → no correspondent features")
    }

    c.check("confirm/assign teach the correspondent (live the moment capture returns)") {
        let a = Attributor(instanceHost: "op.example.com")
        a.confirm(gmailSignal(), task: .op(1), now: t0)
        try expect(a.learning.learnedValues(for: .task(.op(1)), kinds: [.correspondent])
            .contains("r.naismith@harborlane.example"))
        try expect(a.learning.learnedValues(for: .task(.op(1)), kinds: [.correspondentDomain])
            .contains("harborlane.example"))
        let b = Attributor(instanceHost: "op.example.com")
        b.assign(gmailSignal(), target: .task(.op(2)), now: t0)
        try expect(b.learning.learnedValues(for: .task(.op(2)), kinds: [.correspondent])
            .contains("r.naismith@harborlane.example"))
    }

    c.check("the learned correspondent transfers across surfaces (different app, no URL)") {
        var store = LearningStore()
        store.learn(gmailSignal(), target: .task(.op(1)), weight: 2)
        store.learn(gmailSignal(), target: .task(.op(1)), weight: 2)
        // Same counterparty in a different mail surface: native client, no tab
        // URL, no window title — only the correspondent connects them.
        let probe = ActivitySignal(app: "Mail", windowTitle: nil, tabURL: nil,
                                   timestamp: t0,
                                   correspondents: ["r.naismith@harborlane.example"],
                                   emailSubject: nil)
        let scores = store.scores(for: probe, among: [.task(.op(1)), .task(.op(2))])
        try expect(scores[.task(.op(1))]! > scores[.task(.op(2))]!,
                   "the correspondent feature alone must carry the association")
    }

    c.check("the why-panel's learns-on line now names the address, not just title junk") {
        let a = Attributor(instanceHost: "op.example.com")
        let e = a.explain(gmailSignal(), tasks: [], now: t0)
        try expect(e.features.contains("correspondent=r.naismith@harborlane.example"))
        try expect(e.features.contains("correspondentDomain=harborlane.example"))
    }
}

// MARK: - forgettable / forget / explainWithout

func forgetChecks(_ c: Checks) {
    let host = "op.example.com"
    let tasks = [WorkTask(ref: .op(1), subject: "University Teaching", status: "Next"),
                 WorkTask(ref: .op(2), subject: "andeye", status: "Now")]

    c.check("forgettable mirrors the ladder: pin and OP-URL sources are NOT forgettable") {
        let a = Attributor(instanceHost: host)
        a.upsert(Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty"])), task: .op(1)))
        try expectNil(a.forgettable(for: ActivitySignal(app: "Ghostty", timestamp: t0), now: t0),
                      "a pin is law, lifted via the pin editor")
        let b = Attributor(instanceHost: host)
        let wp = ActivitySignal(app: "Chrome", windowTitle: "WP",
                                tabURL: "https://op.example.com/work_packages/9", timestamp: t0)
        try expectNil(b.forgettable(for: wp, now: t0), "URL recognition isn't learned state")
        try expectNil(b.forgettable(for: ActivitySignal(app: "Ghostty", timestamp: t0), now: t0),
                      "nothing learned at all → nothing to forget")
    }

    c.check("forgettable names each learned store; forget removes exactly it") {
        // Session sticky.
        let a = Attributor(instanceHost: host)
        let sig = gmailSignal()
        a.assign(sig, target: .task(.op(2)), now: t0)
        // The grain footer's explicit commit — `assign` itself no longer
        // writes a rule (2026-07-03 §5.4 retirement) — same domain grain
        // `learnEmailRule`'s auto-detect would have picked, so the
        // ladder-order test intent below is unchanged.
        a.learnEmailRule(sig, to: .op(2), now: t0)
        guard case .sessionSticky(let key)? = a.forgettable(for: sig, now: t0) else {
            throw CheckFailure(description: "expected the sticky to be the forgettable item")
        }
        a.forget(.sessionSticky(key), signal: sig)
        try expect(a.stickyMatch(for: sig, now: t0) == nil, "the sticky is gone")
        // …which uncovers the email rule the explicit commit taught.
        guard case .emailRule(let rule)? = a.forgettable(for: sig, now: t0) else {
            throw CheckFailure(description: "expected the email rule next on the ladder")
        }
        try expectEq(rule.target, .op(2))
        a.forget(.emailRule(rule), signal: sig)
        try expectNil(a.emailRuleMatch(sig), "the rule is gone")
        // …which uncovers the soft prime the same assign set.
        guard case .primedSurface(let surface)? = a.forgettable(for: sig, now: t0) else {
            throw CheckFailure(description: "expected the primed surface next on the ladder")
        }
        try expectEq(surface, Surface(signal: sig))
        a.forget(.primedSurface(surface), signal: sig)
        try expectNil(a.primedSurfaces[surface], "the prime is gone")
        // …which leaves only the learned association.
        guard case .rankedAssociation(let target)? = a.forgettable(for: sig, now: t0) else {
            throw CheckFailure(description: "expected the ranked association last")
        }
        try expectEq(target, .task(.op(2)))
        a.forget(.rankedAssociation(target), signal: sig)
        try expectNil(a.forgettable(for: sig, now: t0), "all four stores emptied for this signal")
    }

    c.check("a pinned email rule is not forgettable (it's a pin, not learned)") {
        let a = Attributor(instanceHost: host)
        a.emailRules = [EmailRule(level: .correspondentDomain,
                                  value: "harborlane.example", target: .op(1), pinned: true)]
        try expectNil(a.forgettable(for: gmailSignal(), now: t0))
    }

    c.check("explainWithout previews the fallback and NEVER mutates") {
        let a = Attributor(instanceHost: host)
        let sig = gmailSignal()
        a.assign(sig, target: .task(.op(2)), now: t0)   // sticky + prime + learning
        a.learnEmailRule(sig, to: .op(2), now: t0)       // the grain footer's explicit rule commit
        try expectEq(a.explain(sig, tasks: tasks, now: t0).source, .sessionSticky)
        // Without the sticky, the email rule answers.
        let u = try unwrap(a.forgettable(for: sig, now: t0))
        guard case .sessionSticky = u else {
            throw CheckFailure(description: "expected the sticky to be forgettable, got \(u)")
        }
        let preview = a.explainWithout(u, sig, tasks: tasks, now: t0)
        try expectEq(preview.source, .emailRule, "the preview shows the next rung down")
        try expectEq(preview.chosen, .task(.op(2)))
        // Nothing moved: the real explanation and every store are untouched.
        try expectEq(a.explain(sig, tasks: tasks, now: t0).source, .sessionSticky)
        try expectEq(a.sessionStickies.count, 1)
        try expectEq(a.emailRules.count, 1)
        try expectEq(a.primedSurfaces.count, 1)
        // A rankedAssociation preview restores the learning store too.
        let before = a.learning
        _ = a.explainWithout(.rankedAssociation(.task(.op(2))), sig, tasks: tasks, now: t0)
        try expectEq(a.learning, before)
    }

    c.check("forgettableWithout previews the FALLBACK's own forget target, and never mutates") {
        // The card's "forget that fallback too" affordance (2026-07-06): what
        // [✕ forget] would remove from the fallback preview, without first
        // forgetting the thing that's currently (correctly) firing.
        let a = Attributor(instanceHost: host)
        let sig = gmailSignal()
        a.assign(sig, target: .task(.op(2)), now: t0)   // sticky + prime + learning
        a.learnEmailRule(sig, to: .op(2), now: t0)      // the grain footer's explicit rule commit
        let u = try unwrap(a.forgettable(for: sig, now: t0))
        guard case .sessionSticky = u else {
            throw CheckFailure(description: "expected the sticky to be forgettable, got \(u)")
        }
        // Without the sticky, the email rule is next on the ladder — THAT is
        // what "forget that fallback too" should target.
        let fallbackForget = try unwrap(a.forgettableWithout(u, sig, now: t0))
        guard case .emailRule(let rule) = fallbackForget else {
            throw CheckFailure(description: "expected the email rule as the fallback's own forget target, got \(fallbackForget)")
        }
        try expectEq(rule.target, .op(2))
        // Nothing moved: the sticky is still the live decision, the rule is
        // still there, and forgettable(for:) still names the sticky first.
        try expectEq(a.explain(sig, tasks: tasks, now: t0).source, .sessionSticky)
        try expectEq(a.emailRules.count, 1)
        guard case .sessionSticky = try unwrap(a.forgettable(for: sig, now: t0)) else {
            throw CheckFailure(description: "forgettable(for:) must still name the sticky — the preview must not have mutated it")
        }
        // Forgetting the previewed fallback target for real removes exactly
        // that rule, leaving the (still-current) sticky untouched.
        a.forget(fallbackForget, signal: sig)
        try expectNil(a.emailRuleMatch(sig), "the fallback rule is gone")
        try expectEq(a.explain(sig, tasks: tasks, now: t0).source, .sessionSticky,
                     "the current attribution is unaffected by forgetting the fallback")
    }

    c.check("forgettableWithout is nil when the fallback has nothing left to forget") {
        let a = Attributor(instanceHost: host)
        a.upsert(Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty"])), task: .op(1)))
        let sig = ActivitySignal(app: "Ghostty", timestamp: t0)
        try expectNil(a.forgettable(for: sig, now: t0), "a pin is law — nothing forgettable at all")
        // learnEmailRule below never fires here (not an email surface), so
        // there's no "current" thing to preview a fallback for either —
        // exercise forgettableWithout directly with an arbitrary Unlearn to
        // confirm it degrades to nil rather than throwing/crashing.
        try expectNil(a.forgettableWithout(.rankedAssociation(.task(.op(1))), sig, now: t0))
    }

    c.check("THE scenario: Gmail → 'University Teaching' stops after forget") {
        let a = Attributor(instanceHost: host)
        let gut = TaskRef.op(1)
        // Capture is off (2026-06-30 revert): live Gmail signals carry NO email
        // context — this is exactly Martin's reported state.
        func gmail(_ title: String) -> ActivitySignal {
            ActivitySignal(app: "Google Chrome", windowTitle: title,
                           tabURL: "https://mail.google.com/mail/u/0/#inbox",
                           timestamp: t0)
        }
        // Weeks of confirmations primed the Gmail surface to GUT and stacked
        // learned weight onto Gmail-generic features (app, gmail tokens, host…).
        for _ in 0..<8 {
            a.confirm(gmail("Inbox (23) - martin@example.com - Gmail"), task: gut, now: t0)
        }
        // Days later (stickies long dead) Gmail STILL belongs to GUT.
        let day3 = t0.addingTimeInterval(86_400 * 3)
        let sig = gmail("High memory usage - Gmail")
        try expectEq(a.attribute(sig, tasks: tasks, now: day3).best?.target, .task(gut))
        // Forget #1: the primed surface is what fired.
        let first = try unwrap(a.forgettable(for: sig, now: day3))
        try expectEq(first, Attributor.Unlearn.primedSurface(Surface(signal: sig)))
        a.forget(first, signal: sig)
        // The learned mountain still drags the ranker back to GUT (RC3)…
        try expectEq(a.attribute(sig, tasks: tasks, now: day3).best?.target, .task(gut))
        // …so the next forgettable is the association. Preview first: the
        // card's "would then fall back to…" line must already show the escape.
        let second = try unwrap(a.forgettable(for: sig, now: day3))
        try expectEq(second, Attributor.Unlearn.rankedAssociation(.task(gut)))
        let preview = a.explainWithout(second, sig, tasks: tasks, now: day3)
        try expect(preview.chosen != .task(gut), "fallback preview escapes GUT")
        try expectEq(a.attribute(sig, tasks: tasks, now: day3).best?.target, .task(gut),
                     "previewing must not change the live decision")
        // Forget #2: suppress the association. Gmail finally attributes elsewhere.
        a.forget(second, signal: sig)
        let after = a.attribute(sig, tasks: tasks, now: day3)
        try expect(after.best?.target != .task(gut), "Gmail is free of GUT")
        // And it STAYS forgotten on the next visit (nothing re-primes itself).
        let again = a.attribute(gmail("Another mail - Gmail"),
                                tasks: tasks, now: day3.addingTimeInterval(3600))
        try expect(again.best?.target != .task(gut))
    }

    c.check("forget is targeted: other tasks' learning and other signals' features survive") {
        let a = Attributor(instanceHost: host)
        let mail = gmailSignal()
        let ghostty = ActivitySignal(app: "Ghostty", windowTitle: "andeyeTT", timestamp: t0)
        a.confirm(mail, task: .op(1), now: t0)
        a.confirm(ghostty, task: .op(1), now: t0)
        a.confirm(mail, task: .op(2), now: t0)
        a.forget(.rankedAssociation(.task(.op(1))), signal: mail)
        try expect(a.learning.learnedValues(for: .task(.op(1)), kinds: [.app])
            .contains("ghostty"), "the OTHER surface's association survives")
        try expect(a.learning.learnedValues(for: .task(.op(2)), kinds: [.correspondent])
            .contains("r.naismith@harborlane.example"),
                   "the OTHER task's counts on the same features survive")
        try expect(!a.learning.learnedValues(for: .task(.op(1)), kinds: [.correspondent])
            .contains("r.naismith@harborlane.example"), "the forgotten association is gone")
    }
}
