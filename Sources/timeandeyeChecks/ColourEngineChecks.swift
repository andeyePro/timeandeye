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
