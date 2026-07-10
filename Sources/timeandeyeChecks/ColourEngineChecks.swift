import Foundation
import timeandeyeCore

// MARK: - Colour engine (colour-strategy spec / colour-lab strategy C)
//
// The lab fixture (sites/previews/colour-lab.html) — chosen so a REAL
// near-collision falls out of the legacy hash: "andeye/Onboarding" and
// "Highgate/Backups" land 2° apart under the status-quo djb2 hue.
private let colourFixture: [(project: String, tasks: [String])] = [
    ("andeye", ["Bug fixes", "Design review", "Code review", "Onboarding", "Docs"]),
    ("Harbor Lane", ["Client calls", "Invoicing", "Contract review", "Site visit",
                       "Report writing"]),
    ("Admin", ["Email", "Expenses", "Timesheets", "Filing", "Meetings"]),
    ("Highgate", ["Support", "Deploys", "Testing", "Backups", "Monitoring"]),
]

/// Drive the allocator over the whole fixture in arrival order, returning
/// task-key → hex. Each (project, task) uses synthetic-but-stable keys, the
/// way AppController feeds real ones.
private func allocateFixture(into store: inout ColourAssignments) -> [String: String] {
    var out: [String: String] = [:]
    for (project, tasks) in colourFixture {
        for task in tasks {
            let key = "\(project)/\(task)"
            out[key] = ColourEngine.taskHex(key, projectKey: "op/title:\(project)",
                                            in: &store,
                                            at: Date(timeIntervalSince1970: 1_750_000_000))
        }
    }
    return out
}

/// The lab's 32-bit djb2 (JS `>>>0` semantics) — the STATUS-QUO hue picker
/// the fixture's collision was engineered against.
private func labDjb2Hue(_ s: String) -> Int {
    var h: UInt32 = 5381
    for ch in s.unicodeScalars { h = h &* 33 &+ UInt32(ch.value) }
    return Int(h % 360)
}

/// HSB → sRGB (the legacy palette's S 0.55 / B 0.85 colour), for measuring
/// how close the old hash actually put the collision pair.
private func legacyHsbHex(hue: Int) -> String {
    let h = Double(hue), s = 0.55, v = 0.85
    let c = v * s
    let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    let (rp, gp, bp): (Double, Double, Double)
    switch h {
    case ..<60: (rp, gp, bp) = (c, x, 0)
    case ..<120: (rp, gp, bp) = (x, c, 0)
    case ..<180: (rp, gp, bp) = (0, c, x)
    case ..<240: (rp, gp, bp) = (0, x, c)
    case ..<300: (rp, gp, bp) = (x, 0, c)
    default: (rp, gp, bp) = (c, 0, x)
    }
    return RGB255(r: Int(((rp + m) * 255).rounded()),
                  g: Int(((gp + m) * 255).rounded()),
                  b: Int(((bp + m) * 255).rounded())).hex
}

func colourEngineChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    c.check("determinism: same arrival order → byte-identical colours, twice over") {
        // The engine must be a pure function of the stored records (spec §7)
        // — that is what makes a persisted store reproduce the same palette
        // on every device and after every restart.
        var storeA = ColourAssignments()
        var storeB = ColourAssignments()
        let a = allocateFixture(into: &storeA)
        let b = allocateFixture(into: &storeB)
        try expectEq(a, b, "two identical runs diverged")
        // Re-querying an assigned key must return the record, not re-derive.
        for (project, tasks) in colourFixture {
            for task in tasks {
                let key = "\(project)/\(task)"
                try expectEq(ColourEngine.taskHex(key, projectKey: "op/title:\(project)",
                                                  in: &storeA),
                             a[key]!, "re-query changed \(key)")
            }
        }
    }

    c.check("stability: adding item N+1 changes ZERO existing records (store diff = one new record)") {
        // THE governing principle: people build colour-to-project
        // associations, so a colour, once seen, never changes underneath the
        // user. Crowding is absorbed by the newcomer, never redistributed.
        var store = ColourAssignments()
        _ = allocateFixture(into: &store)
        for newcomer in ["Bloom & Co/Research", "Bloom & Co/Planning",
                         "andeye/Sync"] {
            let beforeTasks = store.tasks
            let beforeProjects = store.projects
            let projectName = String(newcomer.split(separator: "/")[0])
            _ = ColourEngine.taskHex(newcomer, projectKey: "op/title:\(projectName)",
                                     in: &store, at: t0)
            for (key, record) in beforeTasks {
                try expectEq(store.tasks[key], record, "task record moved: \(key)")
            }
            for (key, record) in beforeProjects {
                try expectEq(store.projects[key], record, "anchor moved: \(key)")
            }
            try expectEq(store.tasks.count, beforeTasks.count + 1,
                         "expected exactly one new task record")
        }
    }

    c.check("override beats engine and writes no record") {
        // User overrides live in settings.taskColours exactly as before the
        // engine existed — the engine must return them verbatim and must NOT
        // burn an auto record for the overridden key (clearing the override
        // later should allocate fresh, not resurrect a shadow assignment).
        var store = ColourAssignments()
        let hex = ColourEngine.effectiveHex(taskKey: "op:42", projectKey: "op/id:14",
                                            override: "#123456", in: &store, at: t0)
        try expectEq(hex, "#123456", "override not returned verbatim")
        try expectEq(store.recordCount, 0, "override must not create records")
        // Without the override the same key allocates normally.
        let auto = ColourEngine.effectiveHex(taskKey: "op:42", projectKey: "op/id:14",
                                             override: nil, in: &store, at: t0)
        try expect(auto != "#123456", "auto colour should be an engine pick")
        try expectEq(store.tasks.count, 1)
    }

    c.check("lab collision case: the legacy hash merges two tasks the engine keeps apart") {
        // Premise (from the lab, panel 3): under the status-quo djb2 palette
        // these two unrelated tasks land 2° apart — visually the same colour,
        // in EVERY vision mode. The engine must keep the same pair legible.
        let pair = ("andeye/Onboarding", "Highgate/Backups")
        let hueA = labDjb2Hue(pair.0)
        let hueB = labDjb2Hue(pair.1)
        var d = abs(hueA - hueB)
        d = min(d, 360 - d)
        try expect(d <= 4, "fixture premise broken: hues \(hueA)/\(hueB) no longer collide")
        let legacy = ColourEngine.worstCaseDistance(hexA: legacyHsbHex(hue: hueA),
                                                    hexB: legacyHsbHex(hue: hueB))
        try expect(legacy < ColourEngine.legibilityFloor,
                   "legacy pair should be illegibly close, got \(legacy)")
        var store = ColourAssignments()
        let colours = allocateFixture(into: &store)
        let engine = ColourEngine.worstCaseDistance(hexA: colours[pair.0]!,
                                                    hexB: colours[pair.1]!)
        try expect(engine >= ColourEngine.legibilityFloor,
                   "engine colours for the collision pair too close: \(engine)")
        try expect(engine > legacy * 10,
                   "engine should separate the pair decisively, got \(engine) vs \(legacy)")
    }

    c.check("whole fixture stays pairwise legible under the worst-case (CVD-aware) metric") {
        // Distance is the MINIMUM over identity + protan/deutan/tritan
        // simulation — a hue pair is only as distinct as its worst-case
        // viewer, and that metric is always on (no colour-blind mode toggle:
        // a mode that changes allocations would fight stability).
        var store = ColourAssignments()
        let colours = allocateFixture(into: &store)
        let hexes = colours.values.sorted()
        for i in 0..<hexes.count {
            for j in (i + 1)..<hexes.count where hexes[i] != hexes[j] {
                let d = ColourEngine.worstCaseDistance(hexA: hexes[i], hexB: hexes[j])
                try expect(d >= ColourEngine.legibilityFloor,
                           "\(hexes[i]) vs \(hexes[j]) collapse to \(d)")
            }
        }
        try expectEq(Set(hexes).count, hexes.count, "no two tasks share a hex")
    }

    c.check("every auto colour passes the 4.5:1 chosen-label contrast rule (spec §9)") {
        // The UI picks black or white labels by perceived luminance; the
        // engine must never emit a colour on which that choice reads badly —
        // task colours AND project anchor swatches alike.
        var store = ColourAssignments()
        _ = allocateFixture(into: &store)
        for (key, record) in store.tasks {
            let rgb = try unwrap(RGB255(hex: record.hex), "undecodable hex for \(key)")
            try expect(ColourEngine.labelContrastRatio(on: rgb) >= 4.5,
                       "\(key) \(record.hex) fails label contrast")
        }
        for (key, record) in store.projects {
            let rgb = try unwrap(RGB255(hex: record.hex), "undecodable hex for \(key)")
            try expect(ColourEngine.labelContrastRatio(on: rgb) >= 4.5,
                       "anchor \(key) \(record.hex) fails label contrast")
        }
    }

    c.check("anchor wheel: deterministic start, legible spacing, band 2 on exhaustion — old anchors never move") {
        // Spec §7: with 0 records the first hue is FIXED; each newcomer takes
        // the most distinct-from-neighbours free hue; when the best free
        // band-1 hue drops under the floor the second lightness band opens —
        // capacity doubles and no existing anchor is ever touched.
        var store = ColourAssignments()
        var anchors: [ColourAssignments.ProjectRecord] = []
        for i in 0..<12 {
            let before = store.projects
            let record = ColourEngine.projectRecord("op/id:\(i)", in: &store, at: t0)
            for (key, old) in before {
                try expectEq(store.projects[key], old, "anchor \(key) moved at step \(i)")
            }
            anchors.append(record)
        }
        try expectEq(anchors[0].hue, 258, "first anchor hue is fixed (deterministic first colour)")
        try expectEq(anchors[1].hue, 60, "second anchor takes the most distant free hue")
        // Band 1 (8 anchors on this wheel) stays fully legible…
        for i in 0..<8 {
            try expectClose(anchors[i].bandL, 0.62, accuracy: 0.0001,
                            "anchor \(i) should still be band 1")
            for j in 0..<i {
                let d = ColourEngine.worstCaseDistance(
                    OKLCH(L: anchors[i].bandL, C: 0.13, H: anchors[i].hue),
                    OKLCH(L: anchors[j].bandL, C: 0.13, H: anchors[j].hue))
                try expect(d >= ColourEngine.legibilityFloor,
                           "band-1 anchors \(i)/\(j) too close: \(d)")
            }
        }
        // …and the 9th project opens band 2 instead of squeezing band 1.
        try expectClose(anchors[8].bandL, 0.45, accuracy: 0.0001,
                        "9th project should open the second lightness band")
    }

    c.check("persistence round-trip: encode/decode returns identical colours") {
        // Restart-and-store-round-trip acceptance: `colour(for:)` must give
        // byte-identical answers after a relaunch, which reduces to the
        // store surviving Codable untouched.
        var store = ColourAssignments()
        let colours = allocateFixture(into: &store)
        let data = try JSONEncoder().encode(store)
        var reloaded = try JSONDecoder().decode(ColourAssignments.self, from: data)
        try expectEq(reloaded, store, "store changed across encode/decode")
        for (key, hex) in colours {
            let projectName = String(key.split(separator: "/")[0])
            try expectEq(ColourEngine.taskHex(key, projectKey: "op/title:\(projectName)",
                                              in: &reloaded),
                         hex, "reloaded store re-derived \(key)")
        }
    }

    c.check("migrated legacy snapshot is permanent and never overwritten") {
        // Upgrade rule: a task the user has already seen keeps EXACTLY the
        // colour it showed before — the allocator must treat the snapshot as
        // any other record (read it, score against it, never rewrite it).
        var store = ColourAssignments()
        ColourEngine.snapshotLegacy(taskKey: "op:7", hex: "#61D97C", in: &store, at: t0)
        try expectEq(ColourEngine.taskHex("op:7", projectKey: "op/id:14", in: &store),
                     "#61D97C", "snapshot not honoured")
        ColourEngine.snapshotLegacy(taskKey: "op:7", hex: "#FF0000", in: &store, at: t0)
        try expectEq(store.tasks["op:7"]?.hex, "#61D97C",
                     "second snapshot must not overwrite the first")
        // A new engine pick keeps its distance from the snapshot too.
        let fresh = ColourEngine.taskHex("op:8", projectKey: "op/id:14", in: &store, at: t0)
        try expect(ColourEngine.worstCaseDistance(hexA: fresh, hexB: "#61D97C")
                   >= ColourEngine.legibilityFloor,
                   "new pick ignored the migrated record")
    }

    c.check("upgrade keeps the project ring colour: legacy anchor repair beats fresh allocation") {
        // Pre-engine, the pie's project ring wore a child task's legacy
        // colour — so the upgrade must anchor a seen project to that hex,
        // not to a fresh engine pick (Martin's 2026-07-10 regression: dull
        // engine anchors replaced the bright colours he was using).
        var store = ColourAssignments()
        ColourEngine.snapshotLegacy(taskKey: "op:7", hex: "#7CC7E8", in: &store, at: t0)
        try expect(ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                    memberTaskKeys: ["op:7"],
                                                    storeLoadedPreV2: false,
                                                    in: &store, at: t0),
                   "legacy anchor repair should commit on an empty key")
        let record = ColourEngine.projectRecord("op/id:14", in: &store, at: t0)
        try expectEq(record.hex, "#7CC7E8", "anchor must be the pre-engine ring colour")
        try expectEq(record.provenance, "migrated")
        // The repaired anchor is permanent: a later repair attempt (however
        // the members are presented) is a no-op.
        try expect(!ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                     memberTaskKeys: ["op:7"],
                                                     storeLoadedPreV2: true,
                                                     in: &store, at: t0),
                   "a migrated anchor must never be re-repaired")
        try expectEq(store.projects["op/id:14"]?.hex, "#7CC7E8")
        // The anchor's coordinates are REAL (derived from the hex), so new
        // tasks in the project shade around the familiar hue.
        let expected = ColourEngine.oklch(from: RGB255(hex: "#7CC7E8")!)
        try expectClose(record.hue, expected.H, accuracy: 0.0001,
                        "anchor hue should derive from the migrated hex")
        // A project with no pre-engine colour still allocates normally.
        let fresh = ColourEngine.projectRecord("op/id:15", in: &store, at: t0)
        try expectEq(fresh.provenance, "auto")
    }

    c.check("poisoned-store recovery: a provenance-less anchor (2026-07-09 build) yields once to the legacy colour") {
        // The first engine build allocated fresh anchors for projects the
        // user had already seen — its records carry NO provenance field and
        // no store version. Decode such a file (this is what sits on an
        // upgraded Mac) and prove the repair replaces exactly those records,
        // exactly once, while anchors a v2 engine allocates are untouchable.
        let poisoned = Data("""
        {"projects": {"op/id:14": {"hue": 258, "bandL": 0.62,
                                   "hex": "#4A5568", "firstSeen": 700000000}},
         "tasks": {"op:7": {"hex": "#7CC7E8", "provenance": "migrated",
                            "firstSeen": 700000000}}}
        """.utf8)
        var store = try JSONDecoder().decode(ColourAssignments.self, from: poisoned)
        try expectNil(store.projects["op/id:14"]?.provenance,
                      "fixture premise: the 2026-07-09 build wrote no provenance")
        try expectNil(store.version,
                      "fixture premise: pre-versioning builds wrote no version stamp")
        try expect(ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                    memberTaskKeys: ["op:7"],
                                                    storeLoadedPreV2: true,
                                                    in: &store, at: t0),
                   "repair should replace the provenance-less anchor")
        try expectEq(store.projects["op/id:14"]?.hex, "#7CC7E8",
                     "the longer-seen legacy colour must win")
        try expectEq(store.projects["op/id:14"]?.provenance, "migrated")
        // Idempotent and terminating: the repaired record is closed.
        try expect(!ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                     memberTaskKeys: ["op:7"],
                                                     storeLoadedPreV2: true,
                                                     in: &store, at: t0),
                   "repair must run at most once per project")
        // And an anchor a v2 engine allocated is never overwritten, even if
        // its project has migrated members (a project can gain a legitimate
        // auto anchor after its journal-era tasks all closed).
        let auto = ColourEngine.projectRecord("op/id:15", in: &store, at: t0)
        ColourEngine.snapshotLegacy(taskKey: "op:8", hex: "#61D97C", in: &store, at: t0)
        try expect(!ColourEngine.repairProjectAnchor(projectKey: "op/id:15",
                                                     memberTaskKeys: ["op:8"],
                                                     storeLoadedPreV2: false,
                                                     in: &store, at: t0),
                   "a v2 auto anchor must never be replaced")
        try expectEq(store.projects["op/id:15"], auto)
    }

    c.check("repair window survives the bypass: an interim 'auto' anchor in a pre-v2 store still yields to the legacy colour") {
        // The 2026-07-10 interim repair only ran at pie render — a NEW task
        // first-sighted from the timeline/MiniPie/Settings paths minted an
        // "auto" anchor first, which both shaded the newcomer around the
        // wrong hue and closed the repair forever. The store version stamp
        // dates those anchors: in a store loaded WITHOUT a version (pre-v2),
        // an "auto" anchor on a project with migrated members can only be
        // the 2026-07-09/10 builds' wrong pick, so it stays repairable.
        var store = ColourAssignments()
        ColourEngine.snapshotLegacy(taskKey: "op:7", hex: "#7CC7E8", in: &store, at: t0)
        // The bypass: a new sibling allocates before any repair ran…
        _ = ColourEngine.taskHex("op:8", projectKey: "op/id:14", in: &store, at: t0)
        try expectEq(store.projects["op/id:14"]?.provenance, "auto",
                     "fixture premise: the bypass minted an auto anchor")
        // …and the repair still restores the legacy anchor afterwards.
        try expect(ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                    memberTaskKeys: ["op:7", "op:8"],
                                                    storeLoadedPreV2: true,
                                                    in: &store, at: t0),
                   "pre-v2 auto anchor should stay repairable")
        try expectEq(store.projects["op/id:14"]?.hex, "#7CC7E8")
        try expectEq(store.projects["op/id:14"]?.provenance, "migrated")
        // The bypass-shaded sibling rejoined the restored hue family (see
        // the cohort re-shade check for the full contract).
        let anchorHue = ColourEngine.oklch(from: RGB255(hex: "#7CC7E8")!).H
        let h = try unwrap(store.tasks["op:8"]?.H, "re-shaded pick should carry OKLCH")
        var d = abs(h - anchorHue).truncatingRemainder(dividingBy: 360)
        d = min(d, 360 - d)
        try expect(d <= 25.0001, "re-shaded sibling outside the restored neighbourhood")
        // A task allocated AFTER the repair shades around the right anchor.
        _ = ColourEngine.taskHex("op:9", projectKey: "op/id:14", in: &store, at: t0)
        let h9 = try unwrap(store.tasks["op:9"]?.H)
        var d9 = abs(h9 - anchorHue).truncatingRemainder(dividingBy: 360)
        d9 = min(d9, 360 - d9)
        try expect(d9 <= 25.0001, "post-repair allocation ignored the restored anchor")
    }

    c.check("deterministic legacy child: earliest migrated member wins, ties break lexicographically, member order is irrelevant") {
        // Which child the pre-engine ring actually wore depended on the
        // period the user was viewing (pie sort = seconds-in-range
        // descending) and is unrecoverable — so the repair must derive its
        // anchor from PERSISTED data only: same store ⇒ same anchor on every
        // device, whatever order the caller enumerates members in.
        func freshStore() -> ColourAssignments {
            var s = ColourAssignments()
            ColourEngine.snapshotLegacy(taskKey: "op:2", hex: "#61D97C", in: &s,
                                        at: t0.addingTimeInterval(1))
            ColourEngine.snapshotLegacy(taskKey: "op:1", hex: "#7CC7E8", in: &s, at: t0)
            ColourEngine.snapshotLegacy(taskKey: "op:3", hex: "#E8A87C", in: &s, at: t0)
            return s
        }
        for members in [["op:1", "op:2", "op:3"], ["op:3", "op:2", "op:1"],
                        ["op:2", "op:3", "op:1"]] {
            var store = freshStore()
            try expect(ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                        memberTaskKeys: members,
                                                        storeLoadedPreV2: true,
                                                        in: &store, at: t0))
            // op:1 and op:3 share the earliest firstSeen; "op:1" < "op:3".
            try expectEq(store.projects["op/id:14"]?.hex, "#7CC7E8",
                         "anchor should come from the earliest migrated member "
                         + "(tie → lexicographically first), got order \(members)")
        }
    }

    c.check("override hijack rejected: an override anchors a project only when the project verifiably predates the engine") {
        // settings.taskColours overrides carry no date — a brand-new project
        // whose first task the user recoloured must NOT be anchored to that
        // override under a false 'migrated' stamp. Only a migrated member
        // record (written once, at store bootstrap) proves the project
        // predates the engine.
        var store = ColourAssignments()
        _ = ColourEngine.taskHex("op:8", projectKey: nil, in: &store, at: t0)   // auto task, no project link proof
        try expect(!ColourEngine.repairProjectAnchor(projectKey: "op/id:20",
                                                     memberTaskKeys: ["op:8"],
                                                     overrides: ["op:8": "#FF00FF"],
                                                     storeLoadedPreV2: true,
                                                     in: &store, at: t0),
                   "no migrated member → no repair, however loud the override")
        try expectNil(store.projects["op/id:20"],
                      "rejected repair must not create a record")
        // A nil-provenance anchor on such a project is ADOPTED (the engine
        // pick was that project's first-ever colour), never recoloured to
        // the override.
        store.projects["op/id:20"] = ColourAssignments.ProjectRecord(
            hue: 100, bandL: 0.62, hex: "#4A5568", firstSeen: t0, provenance: nil)
        try expect(ColourEngine.repairProjectAnchor(projectKey: "op/id:20",
                                                    memberTaskKeys: ["op:8"],
                                                    overrides: ["op:8": "#FF00FF"],
                                                    storeLoadedPreV2: true,
                                                    in: &store, at: t0),
                   "adoption should stamp the orphan anchor")
        try expectEq(store.projects["op/id:20"]?.provenance, "auto")
        try expectEq(store.projects["op/id:20"]?.hex, "#4A5568",
                     "adoption keeps the colour — no recolour to the override")
        // On a genuinely pre-engine project, an override on the LEGACY child
        // is the colour the user actually saw on the ring, so it wins; an
        // override on any other member is ignored.
        var preEngine = ColourAssignments()
        ColourEngine.snapshotLegacy(taskKey: "op:1", hex: "#7CC7E8", in: &preEngine, at: t0)
        ColourEngine.snapshotLegacy(taskKey: "op:2", hex: "#61D97C", in: &preEngine,
                                    at: t0.addingTimeInterval(1))
        try expect(ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                    memberTaskKeys: ["op:1", "op:2"],
                                                    overrides: ["op:1": "#AA33BB",
                                                                "op:2": "#FF0000"],
                                                    storeLoadedPreV2: true,
                                                    in: &preEngine, at: t0))
        try expectEq(preEngine.projects["op/id:14"]?.hex, "#AA33BB",
                     "the legacy child's own override is what the user saw")
    }

    c.check("cohort re-shade: a repaired anchor pulls the project's auto tasks back into family; migrated records never move") {
        // Tasks auto-allocated while the anchor was wrong were shaded ±25°
        // around the WRONG hue — leaving them there after the repair is a
        // permanent intra-project clash with no path out. They are days old
        // and already changed once when the engine landed, so re-shading
        // them around the restored anchor is the lesser evil (documented
        // judgement); months-old migrated colours and user overrides are the
        // ones that must never move.
        let poisoned = Data("""
        {"projects": {"op/id:14": {"hue": 40, "bandL": 0.62,
                                   "hex": "#B08050", "firstSeen": 700000000}},
         "tasks": {"op:1": {"hex": "#7CC7E8", "provenance": "migrated",
                            "firstSeen": 700000000}}}
        """.utf8)
        var store = try JSONDecoder().decode(ColourAssignments.self, from: poisoned)
        // Two siblings allocate around the poisoned 40° anchor…
        _ = ColourEngine.taskHex("op:2", projectKey: "op/id:14", in: &store, at: t0)
        _ = ColourEngine.taskHex("op:3", projectKey: "op/id:14", in: &store, at: t0)
        let migratedBefore = store.tasks["op:1"]
        let seenBefore = (store.tasks["op:2"]?.firstSeen, store.tasks["op:3"]?.firstSeen)
        try expect(ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                    memberTaskKeys: ["op:1", "op:2", "op:3"],
                                                    storeLoadedPreV2: true,
                                                    in: &store, at: t0))
        let anchorHue = ColourEngine.oklch(from: RGB255(hex: "#7CC7E8")!).H
        for key in ["op:2", "op:3"] {
            let record = try unwrap(store.tasks[key], "re-shade lost \(key)")
            try expectEq(record.provenance, "auto", "re-shade must keep engine provenance")
            let h = try unwrap(record.H, "re-shaded pick should carry OKLCH")
            var d = abs(h - anchorHue).truncatingRemainder(dividingBy: 360)
            d = min(d, 360 - d)
            try expect(d <= 25.0001,
                       "\(key) hue \(h) outside the restored anchor's neighbourhood")
        }
        try expectEq(store.tasks["op:2"]?.firstSeen, seenBefore.0,
                     "re-shade must preserve firstSeen (identity, not a new sighting)")
        try expectEq(store.tasks["op:3"]?.firstSeen, seenBefore.1)
        try expectEq(store.tasks["op:1"], migratedBefore,
                     "the migrated record must be byte-identical after the repair")
        try expect(store.tasks["op:2"]?.hex != store.tasks["op:3"]?.hex,
                   "re-shaded siblings must stay distinct")
    }

    c.check("version stamp + adoption semantics: v2 closes auto anchors; the finalize pass closes orphans without recolouring") {
        // The per-record nil sentinel alone can't date records — a round
        // trip through a pre-provenance binary strips provenance AND the
        // store version (Codable drops unknown keys on decode, re-encode
        // loses them). The stamp's job here: 'auto' in a store LOADED as v2
        // is a legitimate engine pick (never repaired); 'auto' loaded pre-v2
        // may be the broken window's pick (repairable). adoptUnrepairedAnchors
        // is the finalize pass that closes whatever nil records remain, so
        // the store ends fully stamped — colours untouched.
        var store = ColourAssignments()
        try expectNil(store.version, "a fresh in-memory store carries no stamp yet")
        store.version = ColourAssignments.currentVersion
        let data = try JSONEncoder().encode(store)
        let reloaded = try JSONDecoder().decode(ColourAssignments.self, from: data)
        try expectEq(reloaded.version, ColourAssignments.currentVersion,
                     "the stamp must survive the round-trip")
        // Orphan adoption: nil-provenance anchors with no resolvable members
        // get stamped auto, colour intact; stamped records are left alone.
        store.projects["gone"] = ColourAssignments.ProjectRecord(
            hue: 10, bandL: 0.62, hex: "#4A5568", firstSeen: t0, provenance: nil)
        store.projects["kept"] = ColourAssignments.ProjectRecord(
            hue: 20, bandL: 0.62, hex: "#7CC7E8", firstSeen: t0, provenance: "migrated")
        try expectEq(ColourEngine.adoptUnrepairedAnchors(in: &store), 1)
        try expectEq(store.projects["gone"]?.provenance, "auto")
        try expectEq(store.projects["gone"]?.hex, "#4A5568", "adoption never recolours")
        try expectEq(store.projects["kept"]?.provenance, "migrated")
        try expectEq(ColourEngine.adoptUnrepairedAnchors(in: &store), 0,
                     "adoption is idempotent")
        // Re-run after a hypothetical strip: repairing an already-repaired
        // project re-derives the SAME anchor and skips the re-shade, so the
        // pass is a no-op on colours (the marker file normally prevents even
        // this — belt and braces).
        ColourEngine.snapshotLegacy(taskKey: "op:1", hex: "#7CC7E8", in: &store, at: t0)
        store.projects["op/id:14"] = ColourAssignments.ProjectRecord(
            hue: ColourEngine.oklch(from: RGB255(hex: "#7CC7E8")!).H,
            bandL: ColourEngine.oklch(from: RGB255(hex: "#7CC7E8")!).L,
            hex: "#7CC7E8", firstSeen: t0, provenance: nil)   // stripped repair
        let tasksBefore = store.tasks
        try expect(ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                    memberTaskKeys: ["op:1"],
                                                    storeLoadedPreV2: true,
                                                    in: &store, at: t0),
                   "a stripped repaired anchor re-stamps")
        try expectEq(store.projects["op/id:14"]?.hex, "#7CC7E8",
                     "re-repair converges on the same deterministic colour")
        try expectEq(store.tasks, tasksBefore,
                     "an anchor that did not move must not re-shade anything")
    }

    c.check("achromatic legacy child: the ring keeps the grey but the allocation hue never comes from quantisation noise") {
        // A grey hex has OKLCH chroma ≈ 0, so oklch(from:) returns a hue
        // that is pure atan2 noise (a neutral grey lands red-ish). If the
        // deterministic legacy child's colour is grey (e.g. a #888888
        // override), committing that noise would shade every future task in
        // the project ±25° around red — matching neither the grey nor
        // anything the user ever saw, forever. The contract: the anchor HEX
        // stays the grey (that IS what the user saw on the ring); the
        // allocation HUE falls back to the first chromatic migrated member,
        // else to the engine's own most-distinct-free-hue allocation.
        var store = ColourAssignments()
        ColourEngine.snapshotLegacy(taskKey: "op:1", hex: "#888888", in: &store, at: t0)
        try expect(ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                    memberTaskKeys: ["op:1"],
                                                    storeLoadedPreV2: true,
                                                    in: &store, at: t0))
        let record = try unwrap(store.projects["op/id:14"])
        try expectEq(record.hex, "#888888", "the ring must keep the grey the user saw")
        try expectEq(record.provenance, "migrated")
        // No chromatic member, no other anchors → the engine's deterministic
        // first allocation hue (258), never the grey's noise hue (~red).
        try expectClose(record.hue, 258, accuracy: 0.0001,
                        "all-grey project should take the engine's allocated hue")
        // Future tasks shade around that usable hue, not around red.
        _ = ColourEngine.taskHex("op:2", projectKey: "op/id:14", in: &store, at: t0)
        let h = try unwrap(store.tasks["op:2"]?.H)
        var d = abs(h - 258).truncatingRemainder(dividingBy: 360)
        d = min(d, 360 - d)
        try expect(d <= 25.0001, "task hue \(h) not in the allocated neighbourhood")
        // With a later CHROMATIC migrated sibling, the hue comes from that
        // sibling instead (a colour the project genuinely wore pre-engine),
        // while the ring still shows the earliest child's grey.
        var mixed = ColourAssignments()
        ColourEngine.snapshotLegacy(taskKey: "op:1", hex: "#888888", in: &mixed, at: t0)
        ColourEngine.snapshotLegacy(taskKey: "op:2", hex: "#7CC7E8", in: &mixed,
                                    at: t0.addingTimeInterval(1))
        try expect(ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                    memberTaskKeys: ["op:1", "op:2"],
                                                    storeLoadedPreV2: true,
                                                    in: &mixed, at: t0))
        try expectEq(mixed.projects["op/id:14"]?.hex, "#888888")
        try expectClose(try unwrap(mixed.projects["op/id:14"]?.hue),
                        ColourEngine.oklch(from: RGB255(hex: "#7CC7E8")!).H,
                        accuracy: 0.0001,
                        "hue should come from the chromatic sibling")
        // Same guard when the grey arrives as an OVERRIDE on a chromatic
        // legacy child: the override is what the user saw (hex), but its
        // hue is just as unusable.
        var overridden = ColourAssignments()
        ColourEngine.snapshotLegacy(taskKey: "op:1", hex: "#7CC7E8", in: &overridden, at: t0)
        try expect(ColourEngine.repairProjectAnchor(projectKey: "op/id:14",
                                                    memberTaskKeys: ["op:1"],
                                                    overrides: ["op:1": "#888888"],
                                                    storeLoadedPreV2: true,
                                                    in: &overridden, at: t0))
        try expectEq(overridden.projects["op/id:14"]?.hex, "#888888")
        try expectClose(try unwrap(overridden.projects["op/id:14"]?.hue), 258,
                        accuracy: 0.0001,
                        "a grey override must not leak its noise hue either")
    }

    c.check("project vs task derivation stay distinct: anchor from the display ladder, tasks from its hue neighbourhood") {
        // Two different derivations, never swapped: the project wedge shows
        // the anchor's own swatch (contrast-adjusted ladder lightness) and
        // each task takes a shade from the ±25° neighbourhood of the anchor
        // hue — a task never wears the anchor swatch and vice versa.
        var store = ColourAssignments()
        let anchor = ColourEngine.projectRecord("op/id:14", in: &store, at: t0)
        var taskHexes: [String] = []
        for i in 0..<4 {
            taskHexes.append(ColourEngine.taskHex("op:\(i)", projectKey: "op/id:14",
                                                  in: &store, at: t0))
        }
        for (key, record) in store.tasks {
            try expect(record.hex != anchor.hex,
                       "task \(key) wears the project's anchor swatch")
            let h = try unwrap(record.H, "engine pick \(key) should carry OKLCH")
            var d = abs(h - anchor.hue).truncatingRemainder(dividingBy: 360)
            d = min(d, 360 - d)
            try expect(d <= 25.0001,
                       "task \(key) hue \(h) outside the anchor's ±25° neighbourhood")
        }
        try expectEq(Set(taskHexes).count, taskHexes.count,
                     "sibling tasks must stay distinct")
    }

    c.check("project-key migration mirrors billing: id key wins, colour records follow renamed keys") {
        // Colour anchors share BillableRules' stable-key convention; when a
        // task refresh captures backend project ids, title-keyed anchors move
        // to the id key so subsequent renames keep the hue.
        var store = ColourAssignments()
        let anchor = ColourEngine.projectRecord("op/title:Old Name", in: &store, at: t0)
        let moved = store.migrateProjectKeys(["op/title:Old Name": "op/id:14"])
        try expectEq(moved, 1)
        try expectEq(store.projects["op/id:14"], anchor, "record should move intact")
        try expectNil(store.projects["op/title:Old Name"])
        // Idempotent + never clobbers a populated id key.
        _ = ColourEngine.projectRecord("op/title:Old Name", in: &store, at: t0)
        let movedAgain = store.migrateProjectKeys(["op/title:Old Name": "op/id:14"])
        try expectEq(movedAgain, 0, "an already-populated id key is never clobbered")
        try expectEq(store.projects["op/id:14"], anchor)
    }

    c.check("unknown-project tasks share the 'unfiled' neighbourhood, deterministically") {
        // A ref no longer in any cache still needs a stable colour; unfiled
        // tasks share one anchor rather than scattering, and keep the colour
        // if the project later becomes known (records never re-derive).
        var storeA = ColourAssignments()
        var storeB = ColourAssignments()
        let a = ColourEngine.taskHex("op:99", projectKey: nil, in: &storeA, at: t0)
        let b = ColourEngine.taskHex("op:99", projectKey: nil, in: &storeB, at: t0)
        try expectEq(a, b, "unfiled allocation not deterministic")
        try expect(storeA.projects[ColourAssignments.unfiledKey] != nil,
                   "unfiled anchor should exist")
        // Known-project later: the task record already exists, so the colour
        // holds even though the key resolution changed.
        try expectEq(ColourEngine.taskHex("op:99", projectKey: "op/id:14", in: &storeA),
                     a, "colour changed when the project became known")
    }
}
