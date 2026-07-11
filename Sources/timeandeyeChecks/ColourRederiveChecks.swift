import Foundation
import timeandeyeCore

/// Re-derive from scratch + full palettes (Settings ▸ Colours — Martin,
/// 2026-07-11): the cure for preserved pre-engine hues that share no family.
/// These prove the rebuild is deterministic, produces cohesive per-project
/// families, preserves what it wasn't asked to touch, and that a saved
/// full palette round-trips exactly. (Generic palettes and old-file
/// compatibility live in ColourPaletteChecks.)
func colourRederiveChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    /// A store shaped like Martin's: legacy tasks snapshotted with unrelated
    /// hues (migrated provenance), plus one engine-native task.
    func legacyStore() -> ColourAssignments {
        var store = ColourAssignments()
        ColourEngine.snapshotLegacy(taskKey: "p1/a", hex: "#FF0000",
                                    in: &store, at: t0)
        ColourEngine.snapshotLegacy(taskKey: "p1/b", hex: "#00FFFF",
                                    in: &store, at: t0.addingTimeInterval(60))
        ColourEngine.snapshotLegacy(taskKey: "p1/c", hex: "#00FF00",
                                    in: &store, at: t0.addingTimeInterval(120))
        _ = ColourEngine.taskHex("p2/x", projectKey: "p2", in: &store,
                                 at: t0.addingTimeInterval(180))
        return store
    }
    let groups = [(projectKey: "p1", memberTaskKeys: ["p1/a", "p1/b", "p1/c"]),
                  (projectKey: "p2", memberTaskKeys: ["p2/x"])]

    c.check("re-derive is deterministic") {
        let a = ColourEngine.rederiveAll(groups: groups, in: legacyStore(), at: t0)
        let b = ColourEngine.rederiveAll(groups: groups, in: legacyStore(), at: t0)
        try expectEq(a, b)
    }

    c.check("re-derived tasks form a cohesive family around their anchor") {
        let rebuilt = ColourEngine.rederiveAll(groups: groups, in: legacyStore(), at: t0)
        guard let anchor = rebuilt.projects["p1"] else {
            throw CheckFailure(description: "p1 lost its anchor")
        }
        for key in ["p1/a", "p1/b", "p1/c"] {
            guard let task = rebuilt.tasks[key], let h = task.H else {
                throw CheckFailure(description: "\(key) missing OKLCH record")
            }
            // Task candidates live within ±25° of the project anchor.
            let delta = abs((h - anchor.hue).truncatingRemainder(dividingBy: 360))
            let wrapped = min(delta, 360 - delta)
            try expect(wrapped <= 25.001, "\(key) hue \(h) strays \(wrapped)° from anchor \(anchor.hue)")
            try expectEq(task.provenance, "auto", "re-derived records are engine-owned")
        }
    }

    c.check("first-seen stamps order the pass and survive it") {
        let before = legacyStore()
        let rebuilt = ColourEngine.rederiveAll(groups: groups, in: before, at: t0)
        for key in ["p1/a", "p1/b", "p1/c", "p2/x"] {
            try expectEq(rebuilt.tasks[key]?.firstSeen, before.tasks[key]?.firstSeen,
                         "\(key) firstSeen changed")
        }
    }

    c.check("records outside the groups are preserved byte-for-byte") {
        var store = legacyStore()
        ColourEngine.snapshotLegacy(taskKey: "gone/z", hex: "#123456",
                                    in: &store, at: t0)
        let rebuilt = ColourEngine.rederiveAll(groups: groups, in: store, at: t0)
        try expectEq(rebuilt.tasks["gone/z"], store.tasks["gone/z"],
                     "an ungroupable history task must keep its colour")
    }

    c.check("a project override hue steers the re-derived family") {
        // Martin picked a project colour, then re-derived: the tasks must
        // shade around HIS hue, not the engine's own anchor (2026-07-11).
        let overrideHue = 30.0   // an orange family
        let rebuilt = ColourEngine.rederiveAll(
            groups: groups, anchorHueOverrides: ["p1": overrideHue],
            in: legacyStore(), at: t0)
        for key in ["p1/a", "p1/b", "p1/c"] {
            guard let h = rebuilt.tasks[key]?.H else {
                throw CheckFailure(description: "\(key) missing OKLCH record")
            }
            let delta = abs((h - overrideHue).truncatingRemainder(dividingBy: 360))
            let wrapped = min(delta, 360 - delta)
            try expect(wrapped <= 25.001,
                       "\(key) hue \(h) ignores the override hue \(overrideHue)")
        }
    }

    c.check("full palette round-trips exactly through JSON") {
        let palette = Palette(taskOverrides: ["p1/a": "#ABCDEF"],
                              projectOverrides: ["p1": "#012345"],
                              assignments: legacyStore())
        let data = try JSONEncoder().encode(palette)
        let decoded = try JSONDecoder().decode(Palette.self, from: data)
        try expectEq(decoded, palette)
    }
}
