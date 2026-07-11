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
}
