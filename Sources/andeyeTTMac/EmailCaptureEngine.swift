import Foundation
import andeyeTTCore

/// The live email-sender capture engine (re-enable of the 2026-06-30 freeze).
/// What froze the sampler was a SYNCHRONOUS `NSAppleScript.executeAndReturnError`
/// round-trip into Chrome, run inline on the poll timer's thread. This engine
/// fixes both halves of that: every AppleScript call runs as an `/usr/bin/
/// osascript` SUBPROCESS (never `NSAppleScript`, which is main-thread-bound)
/// with a hard deadline, and the whole thing runs off a background queue with
/// only one capture in flight — `SensorHub.poll()` kicks a capture off and
/// moves on immediately; the result comes back later via `SensorEvent.
/// focusEnrichment`, applied retroactively by `SessionTracker` if the surface
/// is still current.
public final class EmailCaptureEngine {
    /// The merged, self-filtered result a live capture hands back to the
    /// sensor loop — just what `SessionTracker.applyEnrichment` needs.
    public struct Capture: Equatable, Sendable {
        public let system: EmailSystem
        public let correspondents: [String]
    }

    /// The fuller sender/recipient breakdown the diagnostics probe displays.
    public struct FullCapture {
        public let system: EmailSystem
        public let senders: [EmailSignal.Party]
        public let recipients: [EmailSignal.Party]
        public let error: String?
    }

    private let queue = DispatchQueue(label: "com.andeye.emailCapture", qos: .utility)
    /// Guards `inFlight` only — never runs capture work. The busy test can't
    /// live inside a `queue.async` block: `queue` is serial, so blocks only
    /// start when the previous one has finished, and an in-block guard would
    /// never see `inFlight == true` — it would QUEUE a backlog of stale
    /// probes instead of dropping them.
    private let gate = DispatchQueue(label: "com.andeye.emailCapture.gate")
    private var inFlight = false
    private let deadline: TimeInterval
    /// The user's own addresses/domains (Settings ▸ Email), never reported as
    /// counterparties — webmail's "me" heuristic only covers the logged-in
    /// account, so an alternate own address looked like a correspondent.
    /// Guarded by `gate`: written from the main thread on settings changes,
    /// read on the capture queue.
    private var ownAddresses: Set<String> = []
    private var ownDomains: Set<String> = []

    public init(deadline: TimeInterval = 2.0) {
        self.deadline = deadline
    }

    public func setOwnEmail(addresses: Set<String>, domains: Set<String>) {
        gate.sync {
            ownAddresses = addresses
            ownDomains = domains
        }
    }

    /// Kick off a capture for `appName`'s active tab, off the calling
    /// thread — safe to call from `poll()` because it returns immediately.
    /// One capture in flight at a time: a request that arrives while another
    /// is still running is simply dropped (`completion(nil)`) rather than
    /// queued — the rate limit the 2026-06-30 freeze needed. `completion`
    /// fires on this engine's background queue; callers must hop back to
    /// their own thread themselves (`SensorHub` hops to main).
    public func capture(appName: String, completion: @escaping (Capture?) -> Void) {
        let claimed: Bool = gate.sync {
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard claimed else { completion(nil); return }
        queue.async { [weak self] in
            guard let self else { completion(nil); return }
            let (own, ownD) = self.gate.sync { (self.ownAddresses, self.ownDomains) }
            let result = Self.mergedCapture(appName: appName, deadline: self.deadline,
                                            ownAddresses: own, ownDomains: ownD)
            self.gate.sync { self.inFlight = false }
            completion(result)
        }
    }

    /// One-shot synchronous run, NOT rate-limited — the diagnostics button's
    /// engine (an explicit user click, not the hot path). Still off-main by
    /// construction of the caller (`Task.detached`), and still deadline-bounded
    /// so a stuck page can't hang the button forever.
    public static func captureNow(appName: String, deadline: TimeInterval = 2.0) -> FullCapture? {
        fullCapture(appName: appName, deadline: deadline)
    }

    private static func mergedCapture(appName: String, deadline: TimeInterval,
                                      ownAddresses: Set<String> = [],
                                      ownDomains: Set<String> = []) -> Capture? {
        guard let full = fullCapture(appName: appName, deadline: deadline), full.error == nil
        else { return nil }
        let counterparties = EmailSignal.counterparties(senders: full.senders,
                                                        recipients: full.recipients,
                                                        ownAddresses: ownAddresses,
                                                        ownDomains: ownDomains)
        return Capture(system: full.system, correspondents: counterparties.map(\.email))
    }

    private static func fullCapture(appName: String, deadline: TimeInterval) -> FullCapture? {
        let urlRead = runOsascript(activeTabURLScript(appName: appName), deadline: deadline)
        guard let urlStr = urlRead.out, let host = URL(string: urlStr)?.host else {
            // Surface osascript's own words: "-1743 Not authorized to send
            // Apple events" names a missing Automation grant instantly,
            // where a bare "couldn't read" hid it (2026-07-03 diagnosis).
            return FullCapture(system: .unknown, senders: [], recipients: [],
                               error: "Couldn't read the active tab URL."
                                   + (urlRead.failure.map { " [\($0)]" } ?? ""))
        }
        let system = EmailSystem.detect(urlHost: host)
        guard let sSel = system.senderSelector, let rSel = system.recipientSelector else {
            return FullCapture(system: system, senders: [], recipients: [],
                               error: "No recipe for this system yet (host: \(host)).")
        }
        let jsRead = runOsascript(jsScript(appName: appName, sender: sSel, recipient: rSel),
                                  deadline: deadline)
        guard let raw = jsRead.out else {
            return FullCapture(system: system, senders: [], recipients: [],
                               error: "JavaScript execution failed or timed out."
                                   + (jsRead.failure.map { " [\($0)]" } ?? "")
                                   + " (If JS is off: Chrome ▸ View ▸ Developer ▸ "
                                   + "Allow JavaScript from Apple Events.)")
        }
        let parts = raw.components(separatedBy: "\u{1e}")
        return FullCapture(system: system,
                           senders: parseParties(parts.first ?? ""),
                           recipients: parseParties(parts.count > 1 ? parts[1] : ""),
                           error: nil)
    }

    private static func activeTabURLScript(appName: String) -> String {
        "tell application \"\(appName)\" to get URL of active tab of front window"
    }

    /// Read-only JS that dumps `name<TAB>email` lines for the sender selector
    /// and the recipient selector, separated by a record-separator char.
    /// Single quotes + fromCharCode → nothing to escape through AppleScript.
    private static func jsScript(appName: String, sender: String, recipient: String) -> String {
        let js = "(function(){var T=String.fromCharCode(9),L=String.fromCharCode(10);"
            + "function g(sel){var a=[];document.querySelectorAll(sel).forEach(function(e){"
            + "var em=e.getAttribute('email')||e.getAttribute('data-hovercard-id')||'';"
            + "var nm=(e.getAttribute('name')||e.textContent||'').trim();"
            + "if(em)a.push(nm+T+em);});return a.join(L);}"
            + "return g('\(sender)')+String.fromCharCode(30)+g('\(recipient)');})()"
        return "tell application \"\(appName)\" to execute active tab of front window javascript \"\(js)\""
    }

    private static func parseParties(_ block: String) -> [EmailSignal.Party] {
        block.split(separator: "\n").compactMap { line in
            let f = String(line).components(separatedBy: "\t")
            guard f.count == 2, !f[1].isEmpty else { return nil }
            return EmailSignal.Party(name: f[0], email: f[1])
        }
    }

    /// `/usr/bin/osascript -e <source>` as a subprocess — NEVER `NSAppleScript`,
    /// which is main-thread-bound and is exactly what froze the sampler on
    /// 2026-06-30. A watchdog terminates the process if it outruns `deadline`,
    /// so a hung tab/page can never hold the queue's one in-flight slot (or a
    /// caller's thread) open indefinitely. Arguments are passed as `Process`
    /// argv, not through a shell, so nothing here needs AppleScript-string
    /// escaping beyond what the source already does.
    private static func runOsascript(_ source: String,
                                     deadline: TimeInterval) -> (out: String?, failure: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        guard (try? process.run()) != nil else { return (nil, "couldn't launch osascript") }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline, execute: watchdog)
        // Drain BOTH pipes BEFORE waiting: a child that fills a ~64 KB pipe
        // buffer blocks on write, so wait-then-read deadlocks until the
        // watchdog kills it. stderr drains on a background reader (semaphore-
        // synchronised, so no race on errData); stdout on this thread. Both
        // reads return at EOF (exit or watchdog kill), so the wait is instant.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        errDone.wait()
        guard process.terminationStatus == 0 else {
            let err = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (nil, err.isEmpty ? "osascript exited \(process.terminationStatus)" : err)
        }
        return (String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    // MARK: - Capture gate (pure)

    /// Whether `bundleID`+`tabURL` name a chrome-like browser sitting on a
    /// KNOWN mail host with a page recipe, showing an OPEN MESSAGE — the gate
    /// for kicking off a capture at all. Pure (no AppleScript/Process), so
    /// `poll()` pays only this check on every non-email focus change. Returns
    /// the AppleScript application name to target, or nil when there's nothing
    /// to capture (unsupported browser, no URL, a recipe-less email system, or
    /// a list/label/search surface — where the DOM still holds the LAST-open
    /// conversation and the selectors would report stale parties).
    public static func captureTarget(bundleID: String?, tabURL: String?) -> String? {
        guard let bundleID, let appName = chromeAppName(bundleID: bundleID),
              let urlStr = tabURL, let host = URL(string: urlStr)?.host else { return nil }
        let system = EmailSystem.detect(urlHost: host)
        guard system.hasRecipe, system.isMessageView(urlString: urlStr) else { return nil }
        return appName
    }

    /// AppleScript app name for a Chromium-family bundle id (the JS probe
    /// channel; Safari isn't supported here, matches the pre-existing probe).
    static func chromeAppName(bundleID: String) -> String? {
        switch bundleID {
        case "com.google.Chrome": return "Google Chrome"
        case "com.operasoftware.Opera": return "Opera"
        case "com.brave.Browser": return "Brave Browser"
        default: return nil
        }
    }
}
