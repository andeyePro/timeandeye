import Foundation
import AmbitickCore

func pinScopeChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    func urlSig(_ raw: String) -> ActivitySignal {
        ActivitySignal(app: "Google Chrome", windowTitle: "x", tabURL: raw, timestamp: now)
    }

    c.check("url identity is host + path segments, query dropped") {
        let id = PinScope.identity(of: urlSig("https://github.com/aqueum/ambitick/issues/42?tab=1"))
        try expectEq(id?.kind, .url)
        try expectEq(id?.segments ?? [], ["github.com", "aqueum", "ambitick", "issues", "42"])
    }

    c.check("url default selection is host + first path segment") {
        let segs = ["github.com", "aqueum", "ambitick", "issues", "42"]
        try expectEq(PinScope.defaultPrefixCount(kind: .url, segments: segs), 2)
    }

    c.check("bare-host url defaults to host only") {
        let id = PinScope.identity(of: urlSig("https://mail.google.com"))
        try expectEq(id?.segments ?? [], ["mail.google.com"])
        try expectEq(PinScope.defaultPrefixCount(kind: .url, segments: id?.segments ?? []), 1)
    }

    c.check("app identity is app name + title segments; default is app + window") {
        let sig = ActivitySignal(app: "Visual Studio Code",
                                 windowTitle: "Attributor.swift — ambitick", timestamp: now)
        let id = PinScope.identity(of: sig)
        try expectEq(id?.kind, .app)
        try expectEq(id?.segments ?? [], ["Visual Studio Code", "Attributor.swift", "ambitick"])
        // Default now grabs the window (most users run several windows of one
        // app on different tasks — e.g. named Ghostty windows). Widen with ←.
        try expectEq(PinScope.defaultPrefixCount(kind: .app, segments: id?.segments ?? []), 2)
    }

    c.check("a titleless app still defaults to app only") {
        let id = PinScope.identity(of: ActivitySignal(app: "Calculator", timestamp: now))
        try expectEq(id?.segments ?? [], ["Calculator"])
        try expectEq(PinScope.defaultPrefixCount(kind: .app, segments: id?.segments ?? []), 1)
    }

    c.check("a prefix pin matches any deeper identity, not a sibling") {
        let pin = PinScope(kind: .url, prefix: ["github.com", "aqueum"])
        try expect(pin.matches(urlSig("https://github.com/aqueum/ambitick/issues/42")))
        try expect(pin.matches(urlSig("https://github.com/aqueum")))
        try expect(!pin.matches(urlSig("https://github.com/other/repo")))
        try expect(!pin.matches(urlSig("https://github.com")), "shorter than the prefix")
    }

    c.check("an app-only pin matches every window of that app") {
        let pin = PinScope(kind: .app, prefix: ["Ghostty"])
        try expect(pin.matches(ActivitySignal(app: "Ghostty", windowTitle: "a", timestamp: now)))
        try expect(pin.matches(ActivitySignal(app: "Ghostty", windowTitle: "b", timestamp: now)))
        try expect(!pin.matches(ActivitySignal(app: "Terminal", windowTitle: "a", timestamp: now)))
    }

    c.check("a url pin never matches a native app and vice-versa") {
        let urlPin = PinScope(kind: .url, prefix: ["github.com"])
        try expect(!urlPin.matches(ActivitySignal(app: "github.com", windowTitle: "x", timestamp: now)))
    }
}
