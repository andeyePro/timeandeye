import Foundation
import timeandeyeCore

/// Away rescue planning (13 Aug reply 2 = "more auto"): the engine replays
/// observedWhileAway evidence into a rebuilt-timeline proposal. Pure Core —
/// these pin the merge/floor/clip/filter rules the Settings preview and the
/// apply step both stand on.
func awayRescueChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let t = { (s: TimeInterval) in t0.addingTimeInterval(s) }
    func span(_ app: String, _ title: String, from: TimeInterval, to: TimeInterval,
              away: Bool = true) -> FocusSpan {
        FocusSpan(target: .doNotTrack, certainty: 0,
                  signal: ActivitySignal(app: app, windowTitle: title, timestamp: t(from)),
                  start: t(from), end: t(to),
                  provenance: SessionProvenance(sourceRaw: "observedWhileAway"),
                  observedWhileAway: away)
    }
    // A fake engine: obsidian windows belong to op(1) at 0.9, chrome to
    // op(2) at 0.4 (low — still proposed, arrives red), slack is
    // unattributable (nil), games attribute to doNotTrack (never proposed).
    let engine: (ActivitySignal, Date) -> (target: Target, certainty: Double, provenance: SessionProvenance?)? = { sig, _ in
        switch sig.app {
        case "obsidian": return (.task(.op(1)), 0.9, SessionProvenance(sourceRaw: "ranked"))
        case "chrome": return (.task(.op(2)), 0.4, SessionProvenance(sourceRaw: "ranked"))
        case "games": return (.doNotTrack, 0.9, nil)
        default: return nil
        }
    }

    c.check("contiguous same-target evidence merges; gaps beyond the merge gap split") {
        let plan = AwayRescue.plan(
            evidence: [span("obsidian", "a", from: 0, to: 300),
                       span("obsidian", "b", from: 360, to: 600),     // 60s gap → merges
                       span("obsidian", "c", from: 900, to: 1200)],   // 300s gap → new run
            from: t(0), to: t(1200), attribute: engine)
        try expectEq(plan.proposals.count, 2)
        try expectEq(plan.proposals[0].start, t(0))
        try expectEq(plan.proposals[0].end, t(600))
        try expectEq(plan.proposals[0].target, Target.task(.op(1)))
        try expectEq(plan.proposals[1].start, t(900))
        // Kept = the 300s between the runs. The 60s gap INSIDE run 1 was
        // bridged by the merge (screen-reading, thinking), so the proposal
        // covers it — only gaps too big to bridge stay with the pinned task.
        try expectClose(plan.keptSeconds, 300, "unbridged gaps stay with the pinned task")
    }

    c.check("low certainty proposes (arrives red); unattributable and doNotTrack never do") {
        let plan = AwayRescue.plan(
            evidence: [span("chrome", "docs", from: 0, to: 300),
                       span("slack", "chat", from: 300, to: 600),
                       span("games", "solitaire", from: 600, to: 900)],
            from: t(0), to: t(900), attribute: engine)
        try expectEq(plan.proposals.count, 1)
        try expectEq(plan.proposals[0].target, Target.task(.op(2)))
        try expectClose(plan.proposals[0].certainty, 0.4, "the engine's own low read carries")
        try expectClose(plan.keptSeconds, 600, "slack + games stay pinned")
    }

    c.check("only observedWhileAway rows count, clipped to the window, floored") {
        let plan = AwayRescue.plan(
            evidence: [span("obsidian", "real", from: -300, to: 300),   // clips to [0,300]
                       span("obsidian", "not-away", from: 300, to: 900, away: false),
                       span("obsidian", "blip", from: 1000, to: 1030)], // 30s < floor
            from: t(0), to: t(1200), attribute: engine)
        try expectEq(plan.proposals.count, 1)
        try expectEq(plan.proposals[0].start, t(0), "clipped to the rescue window")
        try expectEq(plan.proposals[0].end, t(300))
        try expectClose(plan.keptSeconds, 900, "non-away and sub-floor evidence stays pinned")
    }

    c.check("orphan mode (requireAwayMarked false) accepts ordinary recorded windows") {
        // The end-time-orphan auto-apply replays NORMAL spans — the vacated
        // stretch was tracked time, not the away shadow track.
        let normal = FocusSpan(target: .task(.op(9)), certainty: 0.8,
                               signal: ActivitySignal(app: "obsidian", windowTitle: "notes",
                                                      timestamp: t(0)),
                               start: t(0), end: t(300), provenance: nil)
        let away = AwayRescue.plan(evidence: [normal], from: t(0), to: t(300),
                                   attribute: engine)
        try expect(away.isEmpty, "away mode still ignores non-away rows")
        let orphan = AwayRescue.plan(evidence: [normal], from: t(0), to: t(300),
                                     requireAwayMarked: false, attribute: engine)
        try expectEq(orphan.proposals.count, 1)
        try expectEq(orphan.proposals[0].target, Target.task(.op(1)))
    }

    c.check("a merged run keeps its strongest reading") {
        let confident: (ActivitySignal, Date) -> (target: Target, certainty: Double, provenance: SessionProvenance?)? = { sig, _ in
            (.task(.op(1)), sig.windowTitle == "strong" ? 0.95 : 0.5,
             SessionProvenance(sourceRaw: sig.windowTitle == "strong" ? "primedSurface" : "ranked"))
        }
        let plan = AwayRescue.plan(
            evidence: [span("obsidian", "weak", from: 0, to: 300),
                       span("obsidian", "strong", from: 300, to: 600),
                       span("obsidian", "weak", from: 600, to: 900)],
            from: t(0), to: t(900), attribute: confident)
        try expectEq(plan.proposals.count, 1)
        try expectClose(plan.proposals[0].certainty, 0.95)
        try expectEq(plan.proposals[0].provenance?.sourceRaw, "primedSurface")
    }

    c.check("away-end offer fires only on material evidence (5-minute floor)") {
        // The more-auto half: a coffee walk-away with barely anything
        // recorded never nags; a forgotten-toggle day always offers.
        try expect(!AwayRescue.shouldOffer(evidenceSeconds: 0))
        try expect(!AwayRescue.shouldOffer(evidenceSeconds: AwayRescue.offerEvidenceFloor - 1))
        try expect(AwayRescue.shouldOffer(evidenceSeconds: AwayRescue.offerEvidenceFloor))
    }
}
