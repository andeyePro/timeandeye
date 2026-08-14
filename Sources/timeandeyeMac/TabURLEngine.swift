import Foundation

/// Async active-tab URL reads — removing the LAST synchronous AppleScript
/// from the sensor hot path. Until 2026-08-14, `SensorHub.poll()` read the
/// frontmost browser's tab URL with a blocking `NSAppleScript` round-trip on
/// the main run loop — the same shape that froze the sampler on 2026-06-30
/// (email capture), and the 13 Aug event-driven early poll multiplied how
/// often it ran. This engine gives `poll()` an instant answer from a cache
/// and refreshes the cache off-main, exactly the `EmailCaptureEngine`
/// discipline: `/usr/bin/osascript` subprocess (never `NSAppleScript`),
/// hard deadline, one read in flight, results applied retroactively.
///
/// All engine state is MAIN-CONFINED (kick and completion both run on the
/// main queue; only the subprocess itself runs on the background queue), so
/// it composes with the C10 rule without locks.
///
/// Known, self-healing staleness: the cache keys on browser+title, so two
/// tabs sharing a title collide, and a tab switch that lands between kick
/// and subprocess execution can file the NEW tab's URL under the OLD title.
/// Both serve one wrong-URL surface for at most one fetch round trip — the
/// title change that accompanies any real tab switch triggers a fresh
/// fetch, whose corrected value re-polls the sensor.
package final class TabURLEngine {

    /// When a fetch is allowed to start — pure, so the cadence rules are
    /// checkable without a browser. `surfaceChanged` fetches immediately
    /// (a tab/window switch); otherwise the slow `refreshInterval` cadence
    /// catches same-title URL changes (SPA navigation). `settleInterval`
    /// stops the corrected re-poll (whose key change is our OWN doing) from
    /// buying a second, redundant subprocess straight after a completion
    /// for the same surface.
    package enum FetchPolicy {
        package static let refreshInterval: TimeInterval = 10
        package static let settleInterval: TimeInterval = 1.0

        package static func shouldFetch(scriptable: Bool, inFlight: Bool,
                                        surfaceChanged: Bool,
                                        sameSurfaceCompletedAgo: TimeInterval?,
                                        lastCompletedAgo: TimeInterval) -> Bool {
            guard scriptable, !inFlight else { return false }
            if let ago = sameSurfaceCompletedAgo, ago < settleInterval { return false }
            return surfaceChanged || lastCompletedAgo >= refreshInterval
        }
    }

    /// Bounded surface→URL memory. Eviction is deliberately crude — on
    /// overflow the whole map clears (it refills at one fetch per surface
    /// visit); an LRU would be more state for no observable difference at
    /// this size.
    package struct Cache {
        private var store: [String: String] = [:]
        package let capacity: Int

        package init(capacity: Int = 256) { self.capacity = capacity }

        package func url(forKey key: String) -> String? { store[key] }

        /// Returns true iff the stored value actually changed — the signal
        /// that the sensor's emitted surface is stale and worth re-polling.
        @discardableResult
        package mutating func set(_ url: String, forKey key: String) -> Bool {
            if store[key] == url { return false }
            if store[key] == nil, store.count >= capacity {
                store.removeAll(keepingCapacity: true)
            }
            store[key] = url
            return true
        }
    }

    /// AppleScript source for a browser we can script, nil otherwise.
    /// Chrome-likes share one verb; Safari has its own. (The Chromium set
    /// here mirrors `EmailCaptureEngine.chromeAppName` + Safari, which the
    /// JS capture channel can't script.)
    package static func scriptSource(bundleID: String) -> String? {
        if let appName = EmailCaptureEngine.chromeAppName(bundleID: bundleID) {
            return "tell application \"\(appName)\" to get URL of active tab of front window"
        }
        if bundleID == "com.apple.Safari" {
            return "tell application \"Safari\" to get URL of front document"
        }
        return nil
    }

    package static func cacheKey(bundleID: String, title: String?) -> String {
        "\(bundleID)|\(title ?? "")"
    }

    private let queue = DispatchQueue(label: "com.andeye.tabURL", qos: .userInitiated)
    private let deadline: TimeInterval
    private var cache = Cache()
    private var inFlight = false
    private var lastCompletedAt = Date.distantPast
    private var lastCompletedKey: String?
    /// Logged once per run, not per fetch — a missing Automation grant fails
    /// EVERY read, and per-fetch logging would flood the debug log.
    private var loggedFetchError = false
    /// True while Automation appears denied (-1743) for the last-scripted
    /// browser: tab URLs are invisible, browser surfaces degrade to
    /// app|title, email/site detection starves. Cleared by any successful
    /// read — the sensing-health surface reads this (2026-08-14; before,
    /// the one debug-log line was the only trace).
    package private(set) var automationDenied = false

    package init(deadline: TimeInterval = 1.5) {
        self.deadline = deadline
    }

    /// The instant answer `poll()` uses. Nil for non-browsers, uncached
    /// surfaces, and browsers whose Automation grant is missing.
    package func cachedURL(bundleID: String?, title: String?) -> String? {
        guard let bundleID else { return nil }
        return cache.url(forKey: Self.cacheKey(bundleID: bundleID, title: title))
    }

    /// Kick an async refresh if the policy allows; returns immediately.
    /// `onChange` fires on the main queue ONLY when the cached URL for this
    /// surface actually changed — the caller re-polls so the corrected URL
    /// flows through the normal surface pipeline. Main-thread only.
    package func refresh(bundleID: String, title: String?, surfaceChanged: Bool,
                         onChange: @escaping () -> Void) {
        guard let source = Self.scriptSource(bundleID: bundleID) else { return }
        let key = Self.cacheKey(bundleID: bundleID, title: title)
        let now = Date()
        let sameSurfaceAgo: TimeInterval? = lastCompletedKey == key
            ? now.timeIntervalSince(lastCompletedAt) : nil
        guard FetchPolicy.shouldFetch(scriptable: true, inFlight: inFlight,
                                      surfaceChanged: surfaceChanged,
                                      sameSurfaceCompletedAgo: sameSurfaceAgo,
                                      lastCompletedAgo: now.timeIntervalSince(lastCompletedAt))
        else { return }
        inFlight = true
        let deadline = self.deadline
        queue.async { [weak self] in
            let read = EmailCaptureEngine.runOsascript(source, deadline: deadline)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.lastCompletedAt = Date()
                self.lastCompletedKey = key
                if let failure = read.failure {
                    if failure.contains("-1743") || failure.contains("Not authorized") {
                        self.automationDenied = true
                    }
                    if !self.loggedFetchError {
                        self.loggedFetchError = true
                        // -1743 = Automation permission missing/denied:
                        // every URL read fails SILENTLY, browser surfaces
                        // degrade to app|title, and email detection
                        // starves. Make it findable.
                        DebugLog.write("tab URL osascript failed for \(bundleID): \(failure)")
                    }
                    return
                }
                self.automationDenied = false
                guard let url = read.out, !url.isEmpty else { return }
                if self.cache.set(url, forKey: key) { onChange() }
            }
        }
    }
}
