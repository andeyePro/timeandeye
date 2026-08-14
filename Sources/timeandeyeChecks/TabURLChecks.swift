#if os(macOS)
import Foundation
import timeandeyeMac

// MARK: - TabURLEngine policy + cache — the pure halves of the async tab-URL
// read (2026-08-14, the last synchronous AppleScript off the sensor hot
// path). The osascript subprocess itself is impure and browser-dependent,
// so it's exercised on-device, not here.

func tabURLChecks(_ c: Checks) {
    typealias Policy = TabURLEngine.FetchPolicy

    c.check("a tab/window switch fetches immediately") {
        try expect(Policy.shouldFetch(scriptable: true, inFlight: false,
                                          surfaceChanged: true,
                                          sameSurfaceCompletedAgo: nil,
                                          lastCompletedAgo: 0))
    }

    c.check("a non-scriptable app never fetches") {
        try expect(!Policy.shouldFetch(scriptable: false, inFlight: false,
                                           surfaceChanged: true,
                                           sameSurfaceCompletedAgo: nil,
                                           lastCompletedAgo: .infinity))
    }

    c.check("an in-flight fetch drops the request instead of queueing") {
        try expect(!Policy.shouldFetch(scriptable: true, inFlight: true,
                                           surfaceChanged: true,
                                           sameSurfaceCompletedAgo: nil,
                                           lastCompletedAgo: .infinity))
    }

    c.check("the corrected re-poll never buys a redundant fetch (settle)") {
        // Our own onChange re-poll changes the surface KEY (the URL part),
        // but the same browser+title just completed — must not refetch.
        try expect(!Policy.shouldFetch(scriptable: true, inFlight: false,
                                           surfaceChanged: true,
                                           sameSurfaceCompletedAgo: 0.3,
                                           lastCompletedAgo: 0.3))
    }

    c.check("an unchanged surface refreshes only at the slow cadence") {
        try expect(!Policy.shouldFetch(scriptable: true, inFlight: false,
                                           surfaceChanged: false,
                                           sameSurfaceCompletedAgo: 5,
                                           lastCompletedAgo: 5))
        try expect(Policy.shouldFetch(scriptable: true, inFlight: false,
                                          surfaceChanged: false,
                                          sameSurfaceCompletedAgo: Policy.refreshInterval,
                                          lastCompletedAgo: Policy.refreshInterval))
    }

    c.check("cache change-detection: only a genuinely new value re-polls") {
        var cache = TabURLEngine.Cache()
        try expect(cache.set("https://a.example/1", forKey: "chrome|A"))
        try expect(!cache.set("https://a.example/1", forKey: "chrome|A"))
        try expect(cache.set("https://a.example/2", forKey: "chrome|A"))
        try expectEq(cache.url(forKey: "chrome|A"), "https://a.example/2")
    }

    c.check("cache overflow clears and refills; overwrites never evict") {
        var cache = TabURLEngine.Cache(capacity: 2)
        cache.set("u1", forKey: "k1")
        cache.set("u2", forKey: "k2")
        // Overwriting an existing key at capacity keeps the neighbours.
        cache.set("u2b", forKey: "k2")
        try expectEq(cache.url(forKey: "k1"), "u1")
        // A NEW key at capacity clears the map, then holds only the new one.
        cache.set("u3", forKey: "k3")
        try expectNil(cache.url(forKey: "k1"))
        try expectNil(cache.url(forKey: "k2"))
        try expectEq(cache.url(forKey: "k3"), "u3")
    }

    c.check("script sources: Chrome-likes + Safari scriptable, others nil") {
        try expectEq(TabURLEngine.scriptSource(bundleID: "com.google.Chrome"),
                     "tell application \"Google Chrome\" to get URL of active tab of front window")
        try expectEq(TabURLEngine.scriptSource(bundleID: "com.apple.Safari"),
                     "tell application \"Safari\" to get URL of front document")
        try expectNil(TabURLEngine.scriptSource(bundleID: "com.apple.Terminal"))
    }
}
#endif
