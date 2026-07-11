import Foundation
import timeandeyeCore

/// Palettes (Settings ▸ Colours — Martin's): the save/load file carries
/// either the FULL look (picks + engine store) or a GENERIC colour list that
/// seeds the automatic assignment pool. These prove the generic seeding is
/// honest against the engine's derivation model (colours become project
/// anchors in first-seen order; families shade around them), that the two
/// forms share one file format, and — hard requirement — that files saved
/// when the UI called these "colour sets" still decode byte-for-byte.
func colourPaletteChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    /// Three projects first-seen in the order pA, pB, pC, one engine task
    /// each — the minimal store where "palette order" is observable.
    func store3() -> ColourAssignments {
        var store = ColourAssignments()
        _ = ColourEngine.taskHex("pA/1", projectKey: "pA", in: &store, at: t0)
        _ = ColourEngine.taskHex("pB/1", projectKey: "pB", in: &store,
                                 at: t0.addingTimeInterval(60))
        _ = ColourEngine.taskHex("pC/1", projectKey: "pC", in: &store,
                                 at: t0.addingTimeInterval(120))
        return store
    }
    let groups = [(projectKey: "pA", memberTaskKeys: ["pA/1"]),
                  (projectKey: "pB", memberTaskKeys: ["pB/1"]),
                  (projectKey: "pC", memberTaskKeys: ["pC/1"])]
    let red = "#C03020"     // warm chromatic seed
    let blue = "#2060C0"    // cool chromatic seed

    func wrapDelta(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 360))
        return min(d, 360 - d)
    }

    c.check("generic seeding: colours become anchors in first-seen order, hex verbatim") {
        let rebuilt = ColourEngine.rederiveAll(
            groups: groups, paletteColours: [red, blue], in: store3(), at: t0)
        // The palette colour IS the anchor swatch — an explicit human
        // choice the engine must not contrast-"improve" — and its own OKLCH
        // hue/L become the allocation coordinates.
        for (key, hex) in [("pA", red), ("pB", blue)] {
            guard let anchor = rebuilt.projects[key] else {
                throw CheckFailure(description: "\(key) lost its anchor")
            }
            let seed = ColourEngine.oklch(from: RGB255(hex: hex)!)
            try expectEq(anchor.hex, hex, "\(key) swatch should be the seed verbatim")
            try expectEq(anchor.hue, seed.H, "\(key) anchor hue should be the seed's")
            try expectEq(anchor.bandL, seed.L, "\(key) bandL should be the seed's")
        }
    }

    c.check("generic seeding: each family shades its seed's hue neighbourhood") {
        let rebuilt = ColourEngine.rederiveAll(
            groups: groups, paletteColours: [red, blue], in: store3(), at: t0)
        for (key, hex) in [("pA/1", red), ("pB/1", blue)] {
            guard let h = rebuilt.tasks[key]?.H else {
                throw CheckFailure(description: "\(key) missing OKLCH record")
            }
            let seedHue = ColourEngine.oklch(from: RGB255(hex: hex)!).H
            try expect(wrapDelta(h, seedHue) <= 25.001,
                       "\(key) hue \(h) strays from seed hue \(seedHue)")
        }
    }

    c.check("projects past the palette's end allocate away from the seeds") {
        // Two seeds, three projects: pC gets a normal engine anchor, and the
        // argmax naturally spreads it clear of the seeded hues.
        let rebuilt = ColourEngine.rederiveAll(
            groups: groups, paletteColours: [red, blue], in: store3(), at: t0)
        guard let anchor = rebuilt.projects["pC"] else {
            throw CheckFailure(description: "pC lost its anchor")
        }
        try expectEq(anchor.provenance, "auto")
        for hex in [red, blue] {
            let seedHue = ColourEngine.oklch(from: RGB255(hex: hex)!).H
            try expect(wrapDelta(anchor.hue, seedHue) > 20,
                       "pC hue \(anchor.hue) crowds the seed at \(seedHue)")
        }
    }

    c.check("an achromatic seed keeps its swatch but steers no hue") {
        // A grey's OKLCH hue is quantisation noise: the swatch is honoured
        // (the user chose it) while the shading neighbourhood falls back to
        // the engine's own allocation — the same hue an unseeded re-derive
        // would pick.
        let oneGroup = [(projectKey: "pA", memberTaskKeys: ["pA/1"])]
        var store = ColourAssignments()
        _ = ColourEngine.taskHex("pA/1", projectKey: "pA", in: &store, at: t0)
        let seeded = ColourEngine.rederiveAll(
            groups: oneGroup, paletteColours: ["#808080"], in: store, at: t0)
        let unseeded = ColourEngine.rederiveAll(
            groups: oneGroup, in: store, at: t0)
        try expectEq(seeded.projects["pA"]?.hex, "#808080")
        try expectEq(seeded.projects["pA"]?.hue, unseeded.projects["pA"]?.hue,
                     "grey should fall back to the engine's own hue pick")
    }

    c.check("undecodable palette entries are skipped, not left as holes") {
        // A hand-edited typo shifts the remaining colours up rather than
        // silently un-colouring one project.
        let rebuilt = ColourEngine.rederiveAll(
            groups: groups, paletteColours: ["not-a-colour", red],
            in: store3(), at: t0)
        try expectEq(rebuilt.projects["pA"]?.hex, red)
    }

    c.check("a user's project pick still steers shading over the seed") {
        // Same contract as Re-derive: the settings-level override renders
        // the swatch, so the family shades HIS hue even when a palette
        // seeded the anchor.
        let overrideHue = 120.0
        let rebuilt = ColourEngine.rederiveAll(
            groups: groups, anchorHueOverrides: ["pA": overrideHue],
            paletteColours: [red], in: store3(), at: t0)
        guard let h = rebuilt.tasks["pA/1"]?.H else {
            throw CheckFailure(description: "pA/1 missing OKLCH record")
        }
        try expect(wrapDelta(h, overrideHue) <= 25.001,
                   "pA/1 hue \(h) ignores the user's override hue")
    }

    c.check("generic seeding is deterministic") {
        let a = ColourEngine.rederiveAll(groups: groups,
                                         paletteColours: [red, blue],
                                         in: store3(), at: t0)
        let b = ColourEngine.rederiveAll(groups: groups,
                                         paletteColours: [red, blue],
                                         in: store3(), at: t0)
        try expectEq(a, b)
    }

    c.check("a file saved by a pre-rename build (old \"colour set\" shape) still loads") {
        // Fixture written as a literal so it proves the ON-DISK contract,
        // not whatever today's encoder happens to emit. Dates are
        // JSONEncoder's default form (seconds since 2001).
        let old = """
        {
          "version": 1,
          "taskOverrides": {"p1/a": "#ABCDEF"},
          "projectOverrides": {"p1": "#012345"},
          "assignments": {
            "version": 2,
            "projects": {"p1": {"hue": 258, "bandL": 0.62, "hex": "#5566AA",
                                "firstSeen": 774000000, "provenance": "auto"}},
            "tasks": {"p1/a": {"hex": "#AA5566", "provenance": "migrated",
                               "firstSeen": 774000000}}
          }
        }
        """
        let palette = try JSONDecoder().decode(Palette.self,
                                               from: Data(old.utf8))
        try expect(!palette.isGeneric, "an old colour set is a FULL palette")
        try expectEq(palette.taskOverrides, ["p1/a": "#ABCDEF"])
        try expectEq(palette.projectOverrides, ["p1": "#012345"])
        try expectEq(palette.assignments?.projects["p1"]?.hex, "#5566AA")
        try expectEq(palette.assignments?.tasks["p1/a"]?.provenance, "migrated")
    }

    c.check("full form encodes with exactly the pre-rename keys") {
        // Byte-level compatibility both ways: a full palette saved today
        // must open in a build that still decodes the strict old shape.
        var store = ColourAssignments()
        _ = ColourEngine.taskHex("p1/a", projectKey: "p1", in: &store, at: t0)
        let palette = Palette(taskOverrides: ["p1/a": "#ABCDEF"],
                              projectOverrides: [:], assignments: store)
        let json = String(decoding: try JSONEncoder().encode(palette),
                          as: UTF8.self)
        for key in ["\"version\"", "\"taskOverrides\"",
                    "\"projectOverrides\"", "\"assignments\""] {
            try expect(json.contains(key), "full form must write \(key)")
        }
        try expect(!json.contains("\"colours\""),
                   "full form must not grow a colours key")
    }

    c.check("generic form round-trips and carries colours only") {
        let palette = Palette(colours: [red, blue, "#808080"])
        let data = try JSONEncoder().encode(palette)
        let decoded = try JSONDecoder().decode(Palette.self, from: data)
        try expectEq(decoded, palette)
        try expect(decoded.isGeneric)
        let json = String(decoding: data, as: UTF8.self)
        try expect(json.contains("\"colours\""))
        for key in ["\"taskOverrides\"", "\"projectOverrides\"",
                    "\"assignments\""] {
            try expect(!json.contains(key),
                       "generic form must not leak \(key) — no names in the file")
        }
    }

    c.check("a JSON that is neither form is refused") {
        // {"version": 1} alone is not a palette: refusing beats silently
        // loading emptiness over the user's colours.
        let data = Data("{\"version\": 1}".utf8)
        try expectThrows("empty palette should not decode") {
            _ = try JSONDecoder().decode(Palette.self, from: data)
        }
    }
}
