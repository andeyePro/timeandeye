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

    c.check("a window-name app pin survives the title's leading text changing") {
        // The bug: a Ghostty window pinned by name ("electroPioreactor") stopped
        // matching once the terminal prepended its mode to the title, so it fell
        // back to a broader attribution. App pins now match on PRESENCE.
        let pin = PinScope(kind: .app, prefix: ["Ghostty", "electroPioreactor"])
        func g(_ t: String) -> ActivitySignal {
            ActivitySignal(app: "Ghostty", windowTitle: t, timestamp: now)
        }
        try expect(pin.matches(g("electroPioreactor")), "name alone")
        try expect(pin.matches(g("nvim — electroPioreactor")), "editor prepended")
        try expect(pin.matches(g("electroPioreactor — fish")), "shell appended")
        try expect(pin.matches(g("~/code — electroPioreactor — vim")), "name in the middle")
        try expect(!pin.matches(g("nvim — somethingElse")), "a different window does NOT match")
        try expect(!pin.matches(ActivitySignal(app: "Terminal", windowTitle: "electroPioreactor",
                                               timestamp: now)), "wrong app does not match")
    }

    c.check("a more-specific app pin still requires all its segments present") {
        let pin = PinScope(kind: .app, prefix: ["Code", "Attributor.swift", "ambitick"])
        func c2(_ t: String) -> ActivitySignal {
            ActivitySignal(app: "Code", windowTitle: t, timestamp: now)
        }
        try expect(pin.matches(c2("Attributor.swift — ambitick")))
        try expect(pin.matches(c2("ambitick — Attributor.swift — zsh")), "order-independent")
        try expect(!pin.matches(c2("Attributor.swift — other")), "missing 'ambitick'")
    }

    c.check("a url pin never matches a native app and vice-versa") {
        let urlPin = PinScope(kind: .url, prefix: ["github.com"])
        try expect(!urlPin.matches(ActivitySignal(app: "github.com", windowTitle: "x", timestamp: now)))
    }

    c.check("a hostless tabURL (about:blank) falls through to .app identity") {
        // A malformed / hostless tabURL must NOT produce a url-kind identity with
        // an empty/garbage root — it falls through to the app, so the pin editor
        // and the matcher work off the real surface (Safari) instead of silently
        // mis-attributing a blank tab. Locks the current fall-through behaviour.
        let sig = ActivitySignal(app: "Safari", windowTitle: "Untitled",
                                 tabURL: "about:blank", timestamp: now)
        let id = PinScope.identity(of: sig)
        try expectEq(id?.kind, .app, "about:blank has no host → identity is the app, not a url")
        try expectEq(id?.segments ?? [], ["Safari", "Untitled"])
        // And an app pin on Safari covers it, as a url pin never could.
        try expect(PinScope(kind: .app, prefix: ["Safari"]).matches(sig))
        try expect(!PinScope(kind: .url, prefix: ["about"]).matches(sig))
    }
}
