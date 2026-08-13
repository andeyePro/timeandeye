import Foundation
import timeandeyeCore

/// The correction ledger (13 Aug reply 9): every learning write is
/// journalled — when, which gesture, what surface, taught what, displacing
/// what — so the card can name the exact correction behind a learned
/// association. These pin the record shape, the retention bounds, the
/// lookup the card uses, and that PREVIEWS never pollute history.
func correctionLedgerChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let host = "op.example.com"

    c.check("teach gestures land in the ledger with their verb, weight and displacement") {
        let sig = ActivitySignal(app: "obsidian", windowTitle: "vaultnote alpha", timestamp: now)
        let a = Attributor(instanceHost: host)
        a.confirm(sig, task: .op(1), now: now)
        try expectEq(a.corrections.records.count, 1)
        let pick = a.corrections.records[0]
        try expectEq(pick.gesture, "pick")
        try expectEq(pick.target, Target.task(.op(1)))
        try expectEq(pick.weight, 2.0)
        try expectEq(pick.displaced, nil)

        // Correcting the now-primed surface records the displacement too
        // (fix 6's discount arm, visible in the audit trail). The confirm
        // also wrote a same-day sticky, which outranks the prime and — as a
        // human word — must NOT discount; clear it so the prime is what the
        // correction displaces (the relaunch-restored state, as in the
        // fix-6 check).
        a.replaceSessionStickies([])
        let ctx = [WorkTask(ref: .op(1), subject: "a", status: "Now"),
                   WorkTask(ref: .op(2), subject: "b", status: "Now")]
        a.assign(sig, target: .task(.op(2)), tasks: ctx, now: now, gesture: "reassign")
        let re = a.corrections.records.last!
        try expectEq(re.gesture, "reassign")
        try expectEq(re.target, Target.task(.op(2)))
        try expectEq(re.displaced, Target.task(.op(1)))
    }

    c.check("forget is journalled as a correction; previews never are") {
        let sig = ActivitySignal(app: "obsidian", windowTitle: "vaultnote alpha", timestamp: now)
        let a = Attributor(instanceHost: host)
        a.confirm(sig, task: .op(1), now: now)
        let countAfterTeach = a.corrections.records.count

        // A pure fallback preview must not append (it isn't a gesture).
        _ = a.forgettableWithout(.primedSurface(Surface(signal: sig)), sig, now: now)
        try expectEq(a.corrections.records.count, countAfterTeach,
                     "forgettableWithout is a read — no ledger write")

        a.forget(.primedSurface(Surface(signal: sig)), signal: sig, now: now)
        let rec = a.corrections.records.last!
        try expect(rec.isForget, "a real forget lands as isForget")
        try expectEq(rec.target, Target.task(.op(1)),
                     "the forgotten prime's target is named")
    }

    c.check("lastTeach: exact surface beats a newer app-level record") {
        var ledger = CorrectionLedger()
        let exact = CorrectionLedger.Record(at: now, gesture: "pick", app: "obsidian",
                                            windowTitle: "note one", target: .task(.op(1)),
                                            weight: 2)
        let newerSibling = CorrectionLedger.Record(at: now.addingTimeInterval(3600),
                                                   gesture: "pick", app: "obsidian",
                                                   windowTitle: "note two", target: .task(.op(1)),
                                                   weight: 2)
        ledger.append(exact)
        ledger.append(newerSibling)
        let probe = ActivitySignal(app: "obsidian", windowTitle: "note one", timestamp: now)
        try expectEq(ledger.lastTeach(toward: .task(.op(1)), for: probe)?.id, exact.id)
        // No exact match → the newest same-app teach explains the pull.
        let other = ActivitySignal(app: "obsidian", windowTitle: "note three", timestamp: now)
        try expectEq(ledger.lastTeach(toward: .task(.op(1)), for: other)?.id, newerSibling.id)
        // Forgets never explain a teach.
        var withForget = ledger
        withForget.append(.init(at: now.addingTimeInterval(7200), gesture: "forget",
                                app: "obsidian", windowTitle: "note one",
                                target: .task(.op(1)), weight: 0, isForget: true))
        try expectEq(withForget.lastTeach(toward: .task(.op(1)), for: probe)?.id, exact.id)
    }

    c.check("retention: cap trims oldest, prune drops beyond max age, decode round-trips") {
        var ledger = CorrectionLedger()
        for i in 0..<(CorrectionLedger.maxRecords + 25) {
            ledger.append(.init(at: now.addingTimeInterval(Double(i)), gesture: "pick",
                                app: "a", target: .task(.op(1)), weight: 2))
        }
        try expectEq(ledger.records.count, CorrectionLedger.maxRecords)
        try expectEq(ledger.records.first?.at, now.addingTimeInterval(25),
                     "oldest 25 trimmed")
        var aged = CorrectionLedger()
        aged.append(.init(at: now.addingTimeInterval(-CorrectionLedger.maxAge - 60),
                          gesture: "pick", app: "a", target: .task(.op(1)), weight: 2))
        aged.append(.init(at: now, gesture: "pick", app: "a", target: .task(.op(2)), weight: 2))
        aged.prune(now: now)
        try expectEq(aged.records.count, 1)
        try expectEq(aged.records[0].target, Target.task(.op(2)))
        let back = try JSONDecoder().decode(CorrectionLedger.self,
                                            from: JSONEncoder().encode(aged))
        try expectEq(back, aged)
    }
}
