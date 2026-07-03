import Foundation
import andeyeTTCore

func hlcChecks(_ c: Checks) {
    // Deterministic fake time the checks can advance.
    var nowMillis: Int64 = 1_750_000_000_000
    func makeClock(_ device: String) -> HLCClock {
        HLCClock(deviceID: device) { Date(timeIntervalSince1970: Double(nowMillis) / 1000) }
    }

    c.check("tick is strictly monotonic, even with a frozen wall clock") {
        let clock = makeClock("mac")
        let a = clock.tick()
        let b = clock.tick()          // same physical millisecond
        let c2 = clock.tick()
        try expect(a < b && b < c2, "\(a) < \(b) < \(c2)")
        try expectEq(b.physicalMillis, a.physicalMillis)
        try expectEq(b.counter, a.counter + 1)
        nowMillis += 5
        let d = clock.tick()
        try expect(c2 < d)
        try expectEq(d.counter, 0, "fresh physical time resets the counter")
    }

    c.check("receive folds a remote stamp so the next tick orders after it") {
        let mac = makeClock("mac")
        let phone = makeClock("phone")
        nowMillis += 1
        let remote = phone.tick()
        mac.receive(remote)
        let next = mac.tick()
        try expect(remote < next, "causality: \(remote) < \(next)")
    }

    c.check("a wildly-forward remote clock is capped, not adopted") {
        let mac = makeClock("mac")
        let crazy = HLC(physicalMillis: nowMillis + 100 * 3600 * 1000, counter: 0,
                        deviceID: "phone")
        mac.receive(crazy)
        let next = mac.tick()
        try expect(next.physicalMillis <= nowMillis + HLCClock.maxDriftMillis + 1,
                   "drift capped: \(next.physicalMillis) vs now \(nowMillis)")
    }

    c.check("total order: deviceID breaks exact ties") {
        let a = HLC(physicalMillis: 1, counter: 1, deviceID: "aaa")
        let b = HLC(physicalMillis: 1, counter: 1, deviceID: "bbb")
        try expect(a < b)
        try expect(!(b < a))
    }
}

func sessionSyncChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func hlc(_ n: Int64, _ device: String = "mac") -> HLC {
        HLC(physicalMillis: n, counter: 0, deviceID: device)
    }
    func rev(_ id: UUID = UUID(), task: TaskRef = .op(1), from: TimeInterval, to: TimeInterval,
             hlc h: HLC, origin: SliceOrigin = .auto, deleted: Bool = false) -> SessionRevision {
        SessionRevision(session: Session(id: id, task: task, start: t(from), end: t(to),
                                         certainty: 0.9),
                        hlc: h, origin: origin, deleted: deleted)
    }

    c.check("record LWW: newer HLC wins; newer delete wins; newer edit resurrects") {
        let id = UUID()
        let old = rev(id, from: 0, to: 600, hlc: hlc(1))
        var edited = rev(id, from: 0, to: 900, hlc: hlc(2, "phone"))
        try expectEq(SessionMerge.merge(local: old, remote: edited), edited)
        try expectEq(SessionMerge.merge(local: edited, remote: old), edited, "commutes")
        let tombstone = SessionRevision(session: old.session, hlc: hlc(3), origin: .auto,
                                        deleted: true)
        try expectEq(SessionMerge.merge(local: edited, remote: tombstone), tombstone,
                     "newer delete beats older edit")
        edited.hlc = hlc(4, "phone")
        try expectEq(SessionMerge.merge(local: tombstone, remote: edited), edited,
                     "newer edit resurrects")
    }

    c.check("replica merge is order-independent and totally ordered") {
        let a = [rev(from: 0, to: 600, hlc: hlc(1)),
                 rev(from: 1000, to: 1600, hlc: hlc(2))]
        let b = [rev(from: 500, to: 900, hlc: hlc(3, "phone")),
                 a[0]]   // shared record
        let ab = SessionMerge.merge(a, b)
        let ba = SessionMerge.merge(b, a)
        try expectEq(ab, ba)
        try expectEq(ab.count, 3)
    }

    c.check("overlap: manual beats auto — auto is trimmed to the free time") {
        // Mac auto-tracked 0..3600; the phone manually tracked 1800..2400.
        let auto = rev(from: 0, to: 3600, hlc: hlc(5), origin: .auto)
        let manual = rev(task: .op(2), from: 1800, to: 2400, hlc: hlc(1, "phone"),
                         origin: .manual)
        let view = SessionMerge.resolveOverlaps([auto, manual])
        let live = view.filter { !$0.deleted }
        try expectEq(live.count, 2)
        let m = live.first { $0.origin == .manual }!
        try expectEq(m.session.start, t(1800))
        try expectEq(m.session.end, t(2400))
        let a2 = live.first { $0.origin == .auto }!
        // Middle overlap: auto keeps its larger side (front 1800 > back 1200).
        try expectEq(a2.session.start, t(0))
        try expectEq(a2.session.end, t(1800))
    }

    c.check("overlap: fully-covered lower-authority session surfaces as deleted") {
        let edited = rev(from: 0, to: 3600, hlc: hlc(1), origin: .edited)
        let auto = rev(task: .op(2), from: 600, to: 1200, hlc: hlc(9, "phone"), origin: .auto)
        let view = SessionMerge.resolveOverlaps([auto, edited])
        try expectEq(view.filter { !$0.deleted }.count, 1)
        try expectEq(view.first { !$0.deleted }?.origin, .edited)
        try expectEq(view.first { $0.deleted }?.id, auto.id,
                     "the covered auto slice is dropped in the view")
    }

    c.check("overlap: equal authority — newer HLC wins the contested time") {
        let older = rev(from: 0, to: 1200, hlc: hlc(1), origin: .auto)
        let newer = rev(task: .op(2), from: 600, to: 1800, hlc: hlc(2, "phone"), origin: .auto)
        let view = SessionMerge.resolveOverlaps([older, newer]).filter { !$0.deleted }
        let n = view.first { $0.id == newer.id }!
        try expectEq(n.session.start, t(600), "winner untrimmed")
        try expectEq(n.session.end, t(1800))
        let o = view.first { $0.id == older.id }!
        try expectEq(o.session.end, t(600), "loser trimmed back to the free time")
    }

    c.check("converge: both replicas derive the identical journal (arrival-order independent)") {
        let id = UUID()
        let shared = rev(id, from: 0, to: 600, hlc: hlc(1))
        let editedShared = rev(id, from: 0, to: 900, hlc: hlc(4, "phone"), origin: .edited)
        let a = [shared, rev(from: 2000, to: 2600, hlc: hlc(2)),
                 rev(task: .op(2), from: 500, to: 1000, hlc: hlc(3), origin: .manual)]
        let b = [editedShared, rev(task: .op(3), from: 2500, to: 3000, hlc: hlc(5, "phone"))]
        let ab = SessionMerge.converge(a, b)
        let ba = SessionMerge.converge(b, a)
        try expectEq(ab, ba, "identical derived journals")
        // The edited shared record beat its older self AND trims the manual
        // slice (edited > manual) to 900..1000.
        let manual = ab.first { $0.origin == .manual && !$0.deleted }!
        try expectEq(manual.session.start, t(900))
        try expectEq(manual.session.end, t(1000))
        // Equal-authority autos at 2000..2600 and 2500..3000: newer wins the
        // contested 2500..2600.
        let older = ab.first { $0.session.task == .op(1) && $0.session.start == t(2000) }!
        try expectEq(older.session.end, t(2500))
    }

    c.check("deleted revisions pass through the view untouched") {
        let dead = rev(from: 0, to: 600, hlc: hlc(1), deleted: true)
        let live = rev(task: .op(2), from: 0, to: 600, hlc: hlc(2), origin: .auto)
        let view = SessionMerge.resolveOverlaps([dead, live])
        try expectEq(view.count, 2)
        try expectEq(view.first { $0.id == dead.id }?.deleted, true)
        let l = view.first { $0.id == live.id }!
        try expectEq(l.session.start, t(0), "the tombstone claims no time")
        try expectEq(l.session.end, t(600))
    }
}
