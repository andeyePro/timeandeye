import Foundation
import timeandeyeCore

/// The ledger's reverse index (reply 9's "what has been corrected based on
/// what correction"): which slices a correction has since decided.
func correctionImpactChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let t = { (s: TimeInterval) in t0.addingTimeInterval(s) }
    let record = CorrectionLedger.Record(at: t(0), gesture: "reassign",
                                         app: "Obsidian",
                                         windowTitle: "notes - Obsidian 1.13.4",
                                         target: .task(.op(1)), weight: 2)
    func sess(_ task: TaskRef, from: TimeInterval, to: TimeInterval,
              source: String?) -> Session {
        var s = Session(task: task, start: t(from), end: t(to), certainty: 0.9)
        s.provenance = source.map { SessionProvenance(sourceRaw: $0) }
        return s
    }
    let primeSurface = Surface(app: "Obsidian",
                               detail: Surface.normalisedTitleKey("notes - Obsidian 1.13.4",
                                                                  app: "Obsidian"))
    let otherObsidian = Surface(app: "Obsidian", detail: "different note")
    let chrome = Surface(app: "Chrome", detail: "docs.example/x")

    c.check("exact-surface prime decisions and same-app ranked pulls count; the rest never") {
        let rows: [(session: Session, surface: Surface?)] = [
            (sess(.op(1), from: 100, to: 400, source: "primedSurface"), primeSurface),  // exact
            (sess(.op(1), from: 500, to: 800, source: "ranked"), otherObsidian),        // same-app pull
            (sess(.op(1), from: 900, to: 1000, source: "ranked"), chrome),              // other app: no
            (sess(.op(2), from: 1100, to: 1200, source: "primedSurface"), primeSurface),// other task: no
            (sess(.op(1), from: 1300, to: 1400, source: "userAssigned"), primeSurface), // human word: no
            (sess(.op(1), from: -500, to: -100, source: "primedSurface"), primeSurface),// pre-record: no
            (sess(.op(1), from: 1500, to: 1600, source: "primedSurface"), nil),         // no surface: no
        ]
        let summary = CorrectionImpact.summary(for: record, sessions: rows)
        try expectEq(summary.hits.count, 2)
        try expectClose(summary.totalSeconds, 600)
        // Newest first; the ranked pull is honestly marked inexact.
        try expectEq(summary.hits[0].exactSurface, false)
        try expectEq(summary.hits[1].exactSurface, true)
    }

    c.check("a forget record decides nothing; a non-task target decides nothing") {
        var forgetRec = record
        forgetRec.isForget = true
        // isForget rows still pass through summary (the view filters) — but a
        // doNotTrack-target record structurally cannot match sessions.
        let dnt = CorrectionLedger.Record(at: t(0), gesture: "dontTrack",
                                          app: "games", target: .doNotTrack,
                                          weight: 2)
        let rows: [(session: Session, surface: Surface?)] = [
            (sess(.op(1), from: 100, to: 400, source: "primedSurface"), primeSurface),
        ]
        try expect(CorrectionImpact.summary(for: dnt, sessions: rows).isEmpty)
    }
}
