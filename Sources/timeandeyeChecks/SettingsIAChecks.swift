import Foundation
import timeandeyeCore

/// The Settings window's information architecture: the sidebar categories and
/// the ⌘F search index. These prove the registry is coherent (unique ids,
/// every category populated) and that search behaves the way a user expects —
/// finds by visible label, by synonym (including US spellings), case-blind,
/// with label matches ranked above synonym matches.
func settingsIAChecks(_ c: Checks) {

    c.check("item ids are unique") {
        let ids = SettingsIA.items.map(\.id)
        try expectEq(Set(ids).count, ids.count, "duplicate item id")
    }

    c.check("every category has at least one item") {
        // A sidebar entry with nothing behind it is a dead click. Conditional
        // sections still index (search should land on the right category).
        let populated = Set(SettingsIA.items.map(\.category))
        for cat in SettingsIA.Category.allCases {
            try expect(populated.contains(cat), "category \(cat) has no items")
        }
    }

    c.check("titles and metadata are non-empty") {
        for item in SettingsIA.items {
            try expect(!item.title.isEmpty, "\(item.id) has empty title")
        }
        for cat in SettingsIA.Category.allCases {
            try expect(!cat.title.isEmpty, "\(cat) has empty title")
            try expect(!cat.systemImage.isEmpty, "\(cat) has empty symbol")
        }
    }

    c.check("empty and whitespace queries return nothing") {
        try expectEq(SettingsIA.search("").count, 0)
        try expectEq(SettingsIA.search("   ").count, 0)
    }

    c.check("search is case-insensitive on the visible label") {
        let hits = SettingsIA.search("SLEEP GRACE")
        try expectEq(hits.first?.id, "behaviour.sleepGrace")
    }

    c.check("US spelling finds the colour settings (synonym keywords)") {
        let ids = SettingsIA.search("color").map(\.id)
        try expect(ids.contains("menuBar.colourLow"), "color should find colourLow")
        try expect(ids.contains("menuBar.colourHigh"), "color should find colourHigh")
    }

    c.check("label matches rank above keyword-only matches") {
        // "colour" appears in two titles and (as "color") in keywords; the
        // title hits must come first so the obvious answer is on top.
        let hits = SettingsIA.search("colour")
        try expect(hits.count >= 2, "expected at least the two colour fields")
        try expectEq(Set(hits.prefix(2).map(\.id)),
                     Set(["menuBar.colourLow", "menuBar.colourHigh"]),
                     "title matches should lead")
    }

    c.check("palette rows: title search finds all three, old name still routes") {
        // The save/load rows wear "palette" in their visible labels; a user
        // who remembers the earlier "colour set" wording must land on the
        // same rows via keywords.
        let ids = SettingsIA.search("palette").map(\.id)
        for id in ["colours.save", "colours.saveGeneric", "colours.load"] {
            try expect(ids.contains(id), "palette should find \(id)")
        }
        let old = SettingsIA.search("colour set").map(\.id)
        try expect(old.contains("colours.save"), "colour set should still find save")
        try expect(old.contains("colours.load"), "colour set should still find load")
    }

    c.check("the menu-bar mark options are searchable by label and synonym") {
        try expectEq(SettingsIA.search("monochrome").first?.id, "menuBar.monochrome")
        try expect(SettingsIA.search("template").map(\.id).contains("menuBar.monochrome"),
                   "template should find the mono toggle")
        try expect(SettingsIA.search("calm").map(\.id).contains("menuBar.monochrome"),
                   "calm should find the mono toggle")
        try expect(SettingsIA.search("draw in").map(\.id).contains("menuBar.drawIn"),
                   "draw in should find the draw-in toggle")
        try expect(SettingsIA.search("reveal").map(\.id).contains("menuBar.drawIn"),
                   "reveal should find the draw-in toggle")
    }

    c.check("multi-token queries require every token") {
        let hits = SettingsIA.search("review floor")
        try expectEq(hits.map(\.id), ["tracking.floor"],
                     "both tokens must land on the same item")
    }

    c.check("synonyms route domain words to the right category") {
        // A user hunting "xero" has no Xero-labelled control yet — search
        // must still take them somewhere useful.
        let cats = Set(SettingsIA.search("xero").map(\.category))
        try expect(cats.contains(.billing), "xero should surface billing mappings")
        try expect(cats.contains(.backend), "xero should surface the licence (now under Connections)")
        let invoice = Set(SettingsIA.search("invoice").map(\.category))
        try expect(invoice.contains(.backend), "invoice should surface unlock (posting health)")
    }

    c.check("nonsense query matches nothing, oddball input doesn't crash") {
        try expectEq(SettingsIA.search("zzqqxjv").count, 0)
        _ = SettingsIA.search("⌘⇧L")
        _ = SettingsIA.search(String(repeating: "a", count: 10_000))
    }

    c.check("category sidebar order is stable and complete") {
        // Declaration order IS the sidebar order; a re-sort or a dropped case
        // would silently reshuffle the window. Tracking leads (Martin,
        // 2026-07-11: the backend connection is not the front page).
        try expectEq(SettingsIA.Category.allCases.first, .tracking)
        try expectEq(SettingsIA.Category.allCases.last, .about)
        try expectEq(SettingsIA.Category.allCases.count, 11)
        try expectEq(SettingsIA.Category.backend.title, "Connections")
    }
}
