import Foundation
import AmbitickCore
import AmbitickMac
import AppKit

func sqliteJournalChecks(_ c: Checks) {
    journalStoreConformanceChecks(c) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambitick-checks-\(UUID().uuidString).sqlite").path
        return try! SQLiteJournalStore(path: path)
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

    c.check("menu-bar task name suffix") {
        try expectEq(MenuTitle.withTaskName("Ambitick design", chars: 5, body: "21m"), "21m Ambit")
        try expectEq(MenuTitle.withTaskName("Inv", chars: 5, body: "21m"), "21m Inv",
                     "name shorter than the limit is shown whole")
        try expectEq(MenuTitle.withTaskName("Ambitick", chars: 0, body: "21m"), "21m",
                     "chars 0 leaves the time alone")
        try expectEq(MenuTitle.withTaskName(nil, chars: 5, body: "21m"), "21m")
        try expectEq(MenuTitle.withTaskName("   ", chars: 5, body: "21m"), "21m",
                     "blank name leaves the time alone")
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
