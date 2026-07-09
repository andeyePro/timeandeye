import Foundation
import timeandeyeCore
import timeandeyeMac
import AppKit

func sqliteJournalChecks(_ c: Checks) {
    journalStoreConformanceChecks(c) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("andeyett-checks-\(UUID().uuidString).sqlite").path
        return try! SQLiteJournalStore(path: path)
    }
}

func supportDirChecks(_ c: Checks) {
    func tempBase() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("andeye-support-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    c.check("data home is the andeye dir under Application Support") {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = AppController.supportDirectory(under: base)
        try expectEq(dir.lastPathComponent, "andeye")
    }

    c.check("the API key resolves through AppSupport (regression: 'No API key yet')") {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = AppSupport.directory(under: base)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("sekrit".utf8).write(to: APIKeyStore.fileURL(in: dir))
        try expectEq(String(data: try Data(contentsOf: APIKeyStore.fileURL(in: dir)),
                            encoding: .utf8), "sekrit",
                     "the key lookup follows the data home")
    }
}

func menuTitleChecks(_ c: Checks) {
    c.check("refresh cadence: 1 Hz first minute, then per-minute") {
        try expectEq(MenuTitle.refreshInterval(sinceTaskChange: 5), 1)
        try expectEq(MenuTitle.refreshInterval(sinceTaskChange: 59), 1)
        try expectEq(MenuTitle.refreshInterval(sinceTaskChange: 61), 60)
    }

    c.check("title formatting") {
        try expectEq(MenuTitle.text(elapsed: 47, certainty: nil, showPercent: false), "47s")
        try expectEq(MenuTitle.text(elapsed: 402, certainty: nil, showPercent: false), "6m")
        try expectEq(MenuTitle.text(elapsed: 5_400, certainty: nil, showPercent: false), "1h 30m")
        try expectEq(MenuTitle.text(elapsed: 60, certainty: 0.87, showPercent: true), "1m 87%")
    }

    c.check("single-digit seconds pad to two-digit width with a figure space") {
        try expectEq(MenuTitle.text(elapsed: 9, certainty: nil, showPercent: false), "\u{2007}9s")
        try expectEq(MenuTitle.text(elapsed: 0, certainty: nil, showPercent: false), "\u{2007}0s")
        try expectEq(MenuTitle.text(elapsed: 10, certainty: nil, showPercent: false), "10s",
                     "two digits need no pad")
        try expectEq(MenuTitle.text(elapsed: 9, certainty: nil, showPercent: false).count,
                     MenuTitle.text(elapsed: 10, certainty: nil, showPercent: false).count,
                     "9s and 10s occupy the same glyph count")
    }

    c.check("sizing templates cover every digit-count text() can emit within a bracket") {
        // Seconds bracket: both the padded single-digit shape and the plain
        // two-digit shape must be present, so the ZStack has both candidates
        // regardless of which one the font actually renders widest.
        try expectEq(MenuTitle.sizingTemplates(elapsed: 9, certainty: nil, showPercent: false),
                     ["\u{2007}0s", "00s"])
        try expectEq(MenuTitle.sizingTemplates(elapsed: 47, certainty: nil, showPercent: false),
                     ["\u{2007}0s", "00s"],
                     "same bracket (under a minute) regardless of which second within it")
        // Minutes bracket: one- and two-digit minute counts.
        try expectEq(MenuTitle.sizingTemplates(elapsed: 402, certainty: nil, showPercent: false),
                     ["0m", "00m"])
        // Hours bracket: one- and two-digit hour counts, minutes always 2-digit.
        try expectEq(MenuTitle.sizingTemplates(elapsed: 5_400, certainty: nil, showPercent: false),
                     ["0h 00m", "00h 00m"])
        // Percent suffix reserves its own widest (3-digit) form onto every template.
        try expectEq(MenuTitle.sizingTemplates(elapsed: 60, certainty: 0.87, showPercent: true),
                     ["0m 100%", "00m 100%"])
        // showPercent on but certainty nil (attribution uncertain) → still no
        // suffix, matching text()'s own showPercent-needs-a-certainty gate.
        try expectEq(MenuTitle.sizingTemplates(elapsed: 60, certainty: nil, showPercent: true),
                     ["0m", "00m"])

        // Every template must be at least as long, in characters, as the
        // actual text it stands in for — the invariant RootScenes' ZStack
        // relies on to guarantee the container never shrinks below any
        // candidate the real text could take within the bracket.
        for elapsed in [TimeInterval(0), 5, 9, 10, 30, 59, 60, 90, 600, 3_599,
                        3_600, 5_400, 7_260] {
            let body = MenuTitle.text(elapsed: elapsed, certainty: nil, showPercent: false)
            let templates = MenuTitle.sizingTemplates(elapsed: elapsed, certainty: nil,
                                                      showPercent: false)
            try expect(templates.contains { $0.count >= body.count },
                       "no template as wide as \"\(body)\" (elapsed \(elapsed)) in \(templates)")
        }
    }

    c.check("menu-bar task name suffix") {
        try expectEq(MenuTitle.withTaskName("timeandeye design", chars: 5, body: "21m"), "21m timea")
        try expectEq(MenuTitle.withTaskName("Inv", chars: 5, body: "21m"), "21m Inv",
                     "name shorter than the limit is shown whole")
        try expectEq(MenuTitle.withTaskName("timeandeye", chars: 0, body: "21m"), "21m",
                     "chars 0 leaves the time alone")
        try expectEq(MenuTitle.withTaskName(nil, chars: 5, body: "21m"), "21m")
        try expectEq(MenuTitle.withTaskName("   ", chars: 5, body: "21m"), "21m",
                     "blank name leaves the time alone")
    }

    c.check("displayed elapsed recovers re-tagged excursion seconds") {
        let now = Date(timeIntervalSince1970: 1_750_000_300)
        // Live slice opened 180 s ago and spans a reverted excursion; the
        // per-visit banked figure only saw the latest visit (70 s) and so
        // under-counts. liveSliceStart is authoritative → 180 s.
        try expectClose(
            MenuTitle.displayedElapsed(liveSliceStart: now.addingTimeInterval(-180),
                                       bankedFallback: 0, running: 70, now: now),
            180)
        // A just-committed live slice: the tracker reset to `now` (elapsed 0)
        // while the controller re-banked the committed time — the fallback wins.
        try expectClose(
            MenuTitle.displayedElapsed(liveSliceStart: now, bankedFallback: 600,
                                       running: 0, now: now),
            600)
    }

    c.check("displayed elapsed falls back to banked+running when no live slice") {
        let now = Date(timeIntervalSince1970: 1_750_000_300)
        try expectClose(
            MenuTitle.displayedElapsed(liveSliceStart: nil, bankedFallback: 120,
                                       running: 45, now: now),
            165)
        try expectClose(
            MenuTitle.displayedElapsed(liveSliceStart: nil, bankedFallback: 0,
                                       running: 0, now: now),
            0)
    }

    c.check("colour gradient and hex parsing") {
        let low = try unwrap(NSColor(hex: "#FF0000"))
        try expectClose(Double(low.redComponent), 1.0)
        try expectClose(Double(low.greenComponent), 0.0)
        // identical colours = signalling disabled, blend is constant
        let same = MenuTitle.colour(certainty: 0.3, lowHex: "#336699", highHex: "#336699")
        let same2 = MenuTitle.colour(certainty: 0.9, lowHex: "#336699", highHex: "#336699")
        try expectClose(Double(same.redComponent), Double(same2.redComponent), accuracy: 0.001)
        // stopped = grey
        try expectEq(MenuTitle.colour(certainty: nil, lowHex: "#FF0000", highHex: "#00FF00"),
                     .systemGray)
        // midpoint blends
        let mid = MenuTitle.colour(certainty: 0.5, lowHex: "#000000", highHex: "#FFFFFF")
        try expectClose(Double(mid.redComponent), 0.5, accuracy: 0.01)
    }
}
