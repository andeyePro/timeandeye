import Foundation
import timeandeyeCore

/// Fix 1 of the 2026-08-13 over-learning diagnosis: bulk correction
/// gestures teach only what the user demonstrably meant. The decision
/// logic lives in Core (`TeachScope`) precisely so this platform-neutral
/// suite can pin it — the AppController glue that applies it is Mac-only.
func teachScopeChecks(_ c: Checks) {
    c.check("single-target gestures always teach at full strength") {
        // One session in the timeline selection: the user pointed at it.
        try expect(TeachScope.bulkReassignTeaches(sessionDuration: 30, selectionCount: 1),
                   "a 30s single-session reassign is a direct word and teaches")
        // One surface in the review assign: full +2 whatever the duration.
        try expectEq(TeachScope.reviewTeachWeight(coveredDuration: 15, surfaceCount: 1),
                     TeachScope.confirmWeight)
    }

    c.check("flits inside bulk gestures teach nothing") {
        // Mechanism 2 of the diagnosis: a sub-floor session inside a
        // multi-session block reassign primed its flit surface at full
        // strength and later hijacked the flit window's true owner.
        try expect(!TeachScope.bulkReassignTeaches(sessionDuration: 45, selectionCount: 3),
                   "a 45s session in a 3-session reassign is a flit — no teach")
        try expect(TeachScope.bulkReassignTeaches(sessionDuration: 600, selectionCount: 3),
                   "a 10-minute session in the same gesture still teaches")
        // Mechanism 3: a sub-floor surface in a multi-surface review sweep
        // is skipped outright — no count teach, no prime.
        try expectEq(TeachScope.reviewTeachWeight(coveredDuration: 45, surfaceCount: 5), nil)
    }

    c.check("bulk review teach weight scales with covered duration") {
        // At the floor: proportionally reduced, never zero.
        let atFloor = TeachScope.reviewTeachWeight(coveredDuration: TeachScope.bulkFloor,
                                                   surfaceCount: 4)
        try expectClose(atFloor ?? -1,
                        TeachScope.confirmWeight * TeachScope.bulkFloor / TeachScope.fullWeightDuration,
                        "floor duration teaches at the scaled weight")
        // From fullWeightDuration up: capped at the full confirmation +2.
        try expectEq(TeachScope.reviewTeachWeight(coveredDuration: 900, surfaceCount: 4),
                     TeachScope.confirmWeight)
    }

    c.check("teachingSignalsWithDurations sums a surface's covered time across rows") {
        let t0 = Date(timeIntervalSince1970: 0)
        let a1 = ReviewSegment(app: "Chrome", windowTitle: "docs", start: t0,
                               end: t0.addingTimeInterval(90))
        let a2 = ReviewSegment(app: "Chrome", windowTitle: "docs",
                               correspondents: ["pat@northgate.example"],
                               start: t0.addingTimeInterval(600),
                               end: t0.addingTimeInterval(700))
        let b = ReviewSegment(app: "Xcode", windowTitle: "build",
                              start: t0, end: t0.addingTimeInterval(40))
        let rows = [a1, a2, b]
        let out = rows.teachingSignalsWithDurations(for: Set(rows.map(\.id)))
        try expectEq(out.count, 2, "two distinct surfaces")
        let chrome = out.first { $0.signal.app == "Chrome" }
        try expectClose(chrome?.covered ?? -1, 190, "same-surface rows sum their durations")
        try expectEq(chrome?.signal.correspondents ?? [], ["pat@northgate.example"],
                     "email evidence still merges across the surface's rows")
        let xcode = out.first { $0.signal.app == "Xcode" }
        try expectClose(xcode?.covered ?? -1, 40, "single-row surface keeps its own duration")
        // The signal-only wrapper stays in lockstep.
        try expectEq(rows.teachingSignals(for: Set(rows.map(\.id))).count, 2)
    }
}
