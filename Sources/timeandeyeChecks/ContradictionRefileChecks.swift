import Foundation
import timeandeyeCore

/// Mis-filed-slice handling (his design): today's rules confidently
/// contradicting a slice must ACT — but only within the approved lanes.
/// These prove the lanes: user-decided slices untouched, engine-decided
/// ≥ bar refile (unpushed) or flag (posted), everything else suggests,
/// dismissals stick per session+target.
func contradictionRefileChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func session(_ id: UUID, task: TaskRef, certainty: Double,
                 pushed: Bool = false,
                 provenance: SessionProvenance?) -> Session {
        Session(id: id, task: task, start: t0, end: t0.addingTimeInterval(600),
                certainty: certainty, pushedToOP: pushed, provenance: provenance)
    }
    let a = UUID(), b = UUID(), d = UUID(), e = UUID(), f = UUID(), g = UUID()
    // Today's rules say op(2) at 0.95 for everyone (bar 0.9, floor 0.6).
    let says: (Session) -> (target: Target, score: Double)? = { _ in (.task(.op(2)), 0.95) }

    c.check("user-decided slices are never touched, whatever the score") {
        let sessions = [
            session(a, task: .op(1), certainty: 0.9, provenance: .userAssigned),
            session(b, task: .op(1), certainty: 0.9,
                    provenance: SessionProvenance(source: .pin)),
        ]
        let plan = ContradictionRefile.plan(sessions: sessions, bar: 0.9,
                                            suggestFloor: 0.6, dismissed: [],
                                            score: says)
        try expect(plan.isEmpty, "the user's word outranks the rules")
    }

    c.check("engine-decided ≥ bar: unpushed refiles, posted flags") {
        let sessions = [
            session(d, task: .op(1), certainty: 0.7,
                    provenance: SessionProvenance(source: .ranked)),
            session(e, task: .op(1), certainty: 0.7, pushed: true,
                    provenance: SessionProvenance(source: .ranked)),
        ]
        let plan = ContradictionRefile.plan(sessions: sessions, bar: 0.9,
                                            suggestFloor: 0.6, dismissed: [],
                                            score: says)
        try expectEq(plan.refiles.map(\.sessionID), [d])
        try expectEq(plan.postedFlags.map(\.sessionID), [e])
        try expectEq(plan.refiles[0].newTask, .op(2))
    }

    c.check("pre-provenance rows only ever SUGGEST — even above the bar") {
        let sessions = [session(f, task: .op(1), certainty: 0.95, provenance: nil)]
        let plan = ContradictionRefile.plan(sessions: sessions, bar: 0.9,
                                            suggestFloor: 0.6, dismissed: [],
                                            score: says)
        try expect(plan.refiles.isEmpty && plan.postedFlags.isEmpty)
        try expectEq(plan.suggestions.map(\.sessionID), [f])
    }

    c.check("below the bar suggests; below the floor is silence") {
        let quiet: (Session) -> (target: Target, score: Double)? = { _ in (.task(.op(2)), 0.7) }
        let noise: (Session) -> (target: Target, score: Double)? = { _ in (.task(.op(2)), 0.3) }
        let sessions = [session(g, task: .op(1), certainty: 0.5,
                                provenance: SessionProvenance(source: .ranked))]
        let mid = ContradictionRefile.plan(sessions: sessions, bar: 0.9,
                                           suggestFloor: 0.6, dismissed: [],
                                           score: quiet)
        try expectEq(mid.suggestions.count, 1)
        let low = ContradictionRefile.plan(sessions: sessions, bar: 0.9,
                                           suggestFloor: 0.6, dismissed: [],
                                           score: noise)
        try expect(low.isEmpty)
    }

    c.check("a POSTED slice always flags — never refiles, never suggests, whatever score or provenance") {
        // FINDING 1 (2026-07-12, money path): posted, invoice-lockable time
        // must never reach an actionable lane on a bulk pass. Before the fix a
        // posted slice with nil provenance (rows journalled before provenance
        // stamping) or a below-bar score fell through to suggestions → the
        // ReviewView "Refile all" gesture → a backend delete of billed time.
        // Every posted slice now routes to postedFlags regardless of score or
        // provenance; the deliberate per-slice move stays on the timeline path.
        func posted(_ id: UUID, prov: SessionProvenance?) -> Session {
            session(id, task: .op(1), certainty: 0.7, pushed: true, provenance: prov)
        }
        let hi: (Session) -> (target: Target, score: Double)? = { _ in (.task(.op(2)), 0.95) }
        let lo: (Session) -> (target: Target, score: Double)? = { _ in (.task(.op(2)), 0.7) }
        func flagsOnly(_ s: Session, _ score: @escaping (Session) -> (target: Target, score: Double)?,
                       _ id: UUID, _ why: String) throws {
            let p = ContradictionRefile.plan(sessions: [s], bar: 0.9, suggestFloor: 0.6,
                                             dismissed: [], score: score)
            try expectEq(p.postedFlags.map(\.sessionID), [id], why)
            try expect(p.suggestions.isEmpty && p.refiles.isEmpty, "\(why): nothing actionable")
        }
        // (a) posted + nil provenance + below-bar: the exact money-path row.
        try flagsOnly(posted(a, prov: nil), lo, a, "posted+nil+below-bar")
        // (b) posted + nil provenance + above-bar: still flags, never suggests.
        try flagsOnly(posted(b, prov: nil), hi, b, "posted+nil+above-bar")
        // (c) posted + engine provenance + below-bar: flags, not a suggestion.
        try flagsOnly(posted(d, prov: SessionProvenance(source: .ranked)), lo, d, "posted+engine+below-bar")
        // (d) posted + engine provenance + above-bar: unchanged, pinned.
        try flagsOnly(posted(e, prov: SessionProvenance(source: .ranked)), hi, e, "posted+engine+above-bar")
    }

    c.check("agreement is silence — the same task never contradicts itself") {
        let agrees: (Session) -> (target: Target, score: Double)? = { s in (.task(s.task), 0.99) }
        let sessions = [session(a, task: .op(1), certainty: 0.5,
                                provenance: SessionProvenance(source: .ranked))]
        let plan = ContradictionRefile.plan(sessions: sessions, bar: 0.9,
                                            suggestFloor: 0.6, dismissed: [],
                                            score: agrees)
        try expect(plan.isEmpty)
    }

    c.check("dismissal sticks per session+target, not per session") {
        let sessions = [session(f, task: .op(1), certainty: 0.95, provenance: nil)]
        let key = ContradictionRefile.Finding(
            sessionID: f, priorTask: .op(1), priorCertainty: 0.95,
            priorProvenance: nil, newTask: .op(2), score: 0.95).dismissalKey
        let dismissed = ContradictionRefile.plan(sessions: sessions, bar: 0.9,
                                                 suggestFloor: 0.6,
                                                 dismissed: [key], score: says)
        try expect(dismissed.isEmpty, "dismissed pair must stay silent")
        // The rules later point somewhere ELSE: the slice may resurface.
        let elsewhere: (Session) -> (target: Target, score: Double)? = { _ in (.task(.op(3)), 0.95) }
        let resurfaced = ContradictionRefile.plan(sessions: sessions, bar: 0.9,
                                                  suggestFloor: 0.6,
                                                  dismissed: [key], score: elsewhere)
        try expectEq(resurfaced.suggestions.count, 1)
    }

    // MARK: - Applying a refile (review-fix, 2026-07-11). The mechanics
    // AppController.applyRefiles runs, replayed against dictionary state (the
    // house pattern — no AppController in checks). The two rules that were
    // wrong there are now pinned in Core via ContradictionRefile.apply: the
    // certainty is the RE-DERIVED score (never max(old, new)), and a POSTED
    // slice sheds its backend entry so the time re-posts under the new task.

    c.check("refile certainty is the re-derived score, never the old task's inflated confidence") {
        let s = session(a, task: .op(1), certainty: 0.99,
                        provenance: SessionProvenance(source: .ranked))
        let finding = ContradictionRefile.Finding(
            sessionID: a, priorTask: .op(1), priorCertainty: 0.99,
            priorProvenance: s.provenance, newTask: .op(2), score: 0.7)
        let applied = ContradictionRefile.apply(finding, to: s)
        try expectEq(applied.certainty, 0.7, "0.99 on the OLD task must not inflate the new target")
        try expectEq(applied.newTask, .op(2))
    }

    c.check("an unpushed refile has no backend linkage to shed") {
        let s = session(a, task: .op(1), certainty: 0.5,
                        provenance: SessionProvenance(source: .ranked))
        let applied = ContradictionRefile.apply(
            ContradictionRefile.Finding(sessionID: a, priorTask: .op(1), priorCertainty: 0.5,
                priorProvenance: s.provenance, newTask: .op(2), score: 0.95), to: s)
        try expect(!applied.severBackendLinkage)
        try expectNil(applied.entryToDelete)
    }

    c.check("a POSTED slice refiled sheds its old entry, re-posts under the new task; undo restores the posted-under-old state") {
        var s = session(a, task: .op(1), certainty: 0.6, pushed: true,
                        provenance: SessionProvenance(source: .ranked))
        s.opTimeEntryID = "7"
        var backend: [RemoteEntryID: TaskRef] = ["7": .op(1)]   // entry 7 books under op(1)
        var ledger: Set<UUID> = [s.id]                          // posting record exists

        let finding = ContradictionRefile.Finding(
            sessionID: a, priorTask: .op(1), priorCertainty: 0.6,
            priorProvenance: s.provenance, newTask: .op(2), score: 0.95)
        // The digest payload snapshots the prior linkage BEFORE the apply.
        let priorPushed = s.pushedToOP   // → PriorSessionState.priorPushedToOP
        let applied = ContradictionRefile.apply(finding, to: s)
        try expect(applied.severBackendLinkage, "a posted slice must shed its entry")
        try expectEq(applied.entryToDelete, "7")

        // Controller mechanics: delete the old entry, unlink, re-point, then
        // the deferred sync re-creates the entry under the new task.
        if let dead = applied.entryToDelete { backend[dead] = nil }
        s.opTimeEntryID = nil; s.pushedToOP = false; ledger.remove(s.id)
        s.task = applied.newTask; s.certainty = applied.certainty; s.provenance = .retro
        backend["fresh"] = s.task; s.opTimeEntryID = "fresh"; s.pushedToOP = true; ledger.insert(s.id)

        try expectNil(backend["7"], "the old op(1) entry is gone")
        try expectEq(try unwrap(backend["fresh"]), .op(2), "the time now books under op(2)")
        try expectEq(s.certainty, 0.95, "certainty is the re-derived score")
        try expect(ledger.contains(s.id), "ledger re-linked under the new task")

        // Undo: a posted slice can't restore its dead id — it re-posts under
        // the restored task (undoRetroDigest, gated on priorPushedToOP).
        if priorPushed {
            backend["fresh"] = nil; s.opTimeEntryID = nil; s.pushedToOP = false; ledger.remove(s.id)
        }
        s.task = finding.priorTask
        if priorPushed {
            backend["fresh2"] = s.task; s.opTimeEntryID = "fresh2"; s.pushedToOP = true; ledger.insert(s.id)
        }
        try expectEq(s.task, .op(1), "back on the original task")
        try expectEq(try unwrap(backend["fresh2"]), .op(1), "re-posted under op(1), not a dead id")
        try expect(backend.values.filter { $0 == .op(2) }.isEmpty, "no orphan op(2) entry survives undo")
    }
}
