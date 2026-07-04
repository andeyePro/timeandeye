import Foundation
import andeyeTTCore

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
            tabURL: "https://github.com/andeyePro/andeyeTT/issues", timestamp: t0))
        try expectNil(plain.cardDefaultGrainIndex)
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

    c.check("emailMatchValue: empty for the system row (any mail), the segment's own value otherwise") {
        let id = ContextIdentity.from(gmailSignal())
        let system = try unwrap(id.segments.first { $0.kind == .emailSystem })
        try expectEq(system.emailMatchValue, "")
        let domain = try unwrap(id.segments.first { $0.kind == .correspondentDomain })
        try expectEq(domain.emailMatchValue, "harborlane.example")
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
        try expectEq(RulesLedger.grouped(rules, nameOf: nameOf, search: "HAYES").map(\.target), [.op(1)])
        try expectEq(RulesLedger.grouped(rules, nameOf: nameOf, search: "andeye").map(\.target), [.op(2)])
        try expectEq(RulesLedger.grouped(rules, nameOf: nameOf, search: "nonexistent").count, 0)
    }

    c.check("empty input groups to nothing") {
        try expect(RulesLedger.grouped([], nameOf: nameOf).isEmpty)
    }
}
