import Foundation
import AppKit
import CoreAudio
import CoreGraphics
import ApplicationServices
import timeandeyeCore

/// All real-world observation, emitting Core's SensorEvents through one callback.
/// Polling design (2 s) keeps the AX surface minimal; since 2026-08-13 an
/// event-driven layer (app-activation notification + AXObserver on the
/// focused window's title) triggers an EARLY poll so a tab/app switch is
/// seen in ~0.3 s instead of up to a full poll period — the timer remains
/// the backstop and the only authority; events never read anything
/// themselves, they only advance WHEN the same poll runs (C10 honoured:
/// everything still fires on the main run loop).
package final class SensorHub {
    /// Every emitter today runs on the main run loop (Timer poll, workspace/
    /// distributed notification blocks on .main queues), and the consumer
    /// (AppController.tracker) is main-actor state — so emission is FUNNELED
    /// through this trampoline, which asserts main and hops if a future
    /// emitter (the planned event-driven AXObserver refinement, C10) ever
    /// calls from elsewhere. The guard exists BEFORE that refinement lands,
    /// so it can never silently corrupt tracker state from a background
    /// thread.
    package var onEvent: (SensorEvent) -> Void = { _ in }

    func emit(_ event: SensorEvent) {
        if Thread.isMainThread {
            onEvent(event)
        } else {
            assertionFailure("SensorHub emitter off the main thread — C10 guard")
            DispatchQueue.main.async { self.onEvent(event) }
        }
    }
    package private(set) var accessibilityTrusted = false

    private var pollTimer: Timer?
    private var lastSurfaceKey: String?
    // Event-driven early-poll layer (13 Aug reply 15: the pause before
    // tracking follows a tab change "wastes user time"). Trailing-coalesced
    // + spaced so page-load title churn can never hammer the AppleScript
    // URL fetch harder than ~2 polls/s on the affected window.
    private var axObserver: AXObserver?
    private var axObservedPID: pid_t = 0
    private var axTitleElement: AXUIElement?
    private var eventPollTimer: Timer?
    private var lastEventPollAt = Date.distantPast
    private var micMonitor: MicMonitor?
    private var screenLocked = false
    private let emailCapture = EmailCaptureEngine()

    /// Settings pass-through: the user's own addresses/domains, which capture
    /// must never report as counterparties.
    package func setOwnEmail(addresses: Set<String>, domains: Set<String>) {
        emailCapture.setOwnEmail(addresses: addresses, domains: domains)
    }

    package init() {
        // Health telemetry surfaces in the debug log (plus the email probe
        // report); this log line IS the degrade story until the self-heal
        // loop lands on this same seam. Fires on the capture queue —
        // DebugLog appends to a file, no main-thread requirement.
        emailCapture.onRecipeUnhealthy = { system, record in
            DebugLog.write("email recipe unhealthy: \(system.rawValue) failed validate-on-use "
                + "\(record.consecutiveFailures)x in a row (last: "
                + "\(record.lastFault?.rawValue ?? "?")) — correspondent enrichment "
                + "withheld until a healthy read")
        }
    }

    /// Diagnostics pass-through: per-system validate-on-use health, printed
    /// by the email probe report. Empty until a recipe'd system has captured.
    package func emailRecipeHealth() -> [EmailSystem: EmailRecipeHealth] {
        emailCapture.recipeHealth()
    }

    /// Prompts for Accessibility on first run (window titles need it).
    package func requestPermissions() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    package func start() {
        accessibilityTrusted = AXIsProcessTrusted()

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                              object: nil, queue: .main) { [weak self] _ in
            self?.emit(.willSleep(Date()))
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                              object: nil, queue: .main) { [weak self] _ in
            self?.emit(.didWake(Date()))
        }

        // Screen lock/unlock: while locked, the frontmost window is not really
        // in use, so we suppress window detail (and tell Core to close the open
        // span). These are the documented loginwindow distributed notifications.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
            self?.emit(.screenLocked(Date()))
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
            self?.emit(.screenUnlocked(Date()))
        }

        micMonitor = MicMonitor { [weak self] active in
            self?.emit(.microphone(active: active, at: Date()))
        }
        micMonitor?.start()

        // App activation is the one focus change AppKit already events for
        // free — poll immediately instead of waiting out the 2 s tick, and
        // move the AX title observer onto the newly-front app.
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                              object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.scheduleEventPoll()
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication {
                self.attachAXObserver(to: app)
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Focus sampling doesn't care about sub-second phase; tolerance lets
        // the OS coalesce this wakeup with the mic poll (same cadence).
        pollTimer?.tolerance = 0.5
        if let front = NSWorkspace.shared.frontmostApplication {
            attachAXObserver(to: front)
        }
        poll()
    }

    // MARK: - Event-driven early poll (tab/window switches)

    /// Coalesce bursts (a loading page retitles constantly) and keep event
    /// polls ≥0.5 s apart; the poll itself — the SAME poll the timer runs —
    /// happens on the main run loop via this one-shot timer.
    private func scheduleEventPoll() {
        eventPollTimer?.invalidate()
        let sinceLast = Date().timeIntervalSince(lastEventPollAt)
        let delay = max(0.25, 0.5 - sinceLast)
        eventPollTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                              repeats: false) { [weak self] _ in
            guard let self else { return }
            self.lastEventPollAt = Date()
            self.poll()
        }
    }

    /// Observe the front app for focused-window changes, and its focused
    /// window for title changes (a Chrome tab switch IS a title change on
    /// the same window). Best-effort: any AX failure just leaves the 2 s
    /// timer as the sole cadence, exactly as before.
    private func attachAXObserver(to app: NSRunningApplication) {
        guard accessibilityTrusted else { return }
        let pid = app.processIdentifier
        guard pid > 0, pid != axObservedPID else { return }
        detachAXObserver()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let hub = Unmanaged<SensorHub>.fromOpaque(refcon).takeUnretainedValue()
            if notification as String == kAXFocusedWindowChangedNotification {
                hub.reobserveFocusedWindowTitle()
            }
            hub.scheduleEventPoll()
        }
        guard AXObserverCreate(pid, callback, &created) == .success,
              let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, appElement,
                                  kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        axObservedPID = pid
        reobserveFocusedWindowTitle()
        DebugLog.write("sensor events: observing \(app.localizedName ?? String(pid))")
    }

    /// (Re-)point the title observer at the CURRENT focused window — title
    /// notifications only arrive per-element, so a window switch must move
    /// the subscription.
    private func reobserveFocusedWindowTitle() {
        guard let observer = axObserver else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let previous = axTitleElement {
            AXObserverRemoveNotification(observer, previous,
                                         kAXTitleChangedNotification as CFString)
            axTitleElement = nil
        }
        let appElement = AXUIElementCreateApplication(axObservedPID)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement,
                                            kAXFocusedWindowAttribute as CFString,
                                            &focused) == .success,
              let window = focused, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return }
        let element = unsafeDowncast(window as AnyObject, to: AXUIElement.self)
        if AXObserverAddNotification(observer, element,
                                     kAXTitleChangedNotification as CFString,
                                     refcon) == .success {
            axTitleElement = element
        }
    }

    private func detachAXObserver() {
        if let observer = axObserver {
            if let element = axTitleElement {
                AXObserverRemoveNotification(observer, element,
                                             kAXTitleChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObserver = nil
        axObservedPID = 0
        axTitleElement = nil
    }

    /// Drop the surface dedup key so the NEXT poll re-emits the current
    /// window even though it hasn't changed — manual start/confirm needs the
    /// span to reopen without waiting for a real focus change.
    package func reemitCurrentSurface() {
        lastSurfaceKey = nil
    }

    package func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        eventPollTimer?.invalidate()
        eventPollTimer = nil
        detachAXObserver()
        micMonitor?.stop()
    }

    // MARK: - Polling

    private func poll() {
        // Re-check live BOTH ways: a grant mid-run starts window titles
        // flowing, and a REVOKE mid-run must stop us believing we still have
        // them (C11 — the old check latched true forever).
        accessibilityTrusted = AXIsProcessTrusted()
        let now = Date()
        // Input recency: CGEventSource needs no permission.
        // kCGAnyInputEventType is ~0 but has no Swift constant; the failable
        // init returns nil only for out-of-range values, yet a force-unwrap
        // here would crash the sensor loop if that ever changed (C12).
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: anyInput)
        emit(.input(now.addingTimeInterval(-idleSeconds)))
        // Locked: don't sample the frontmost window at all (no window detail
        // should accrue while the Mac is locked).
        if screenLocked { lastSurfaceKey = nil; return }
        // After a real idle gap, re-emit the current surface even if unchanged
        // so the tracker can auto-resume when the user returns to it.
        if idleSeconds > 60 { lastSurfaceKey = nil; return }

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Never observe ourselves: opening the popover/review window made
        // andeye the "current surface", so user confirms bound tasks to
        // andeye instead of the window they were working in.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        let appName = app.localizedName ?? "Unknown"
        let title = focusedWindowTitle(pid: app.processIdentifier)
        let url = activeTabURL(bundleID: app.bundleIdentifier)

        let key = "\(appName)|\(title ?? "")|\(url ?? "")"
        if key != lastSurfaceKey {
            lastSurfaceKey = key
            let signal = ActivitySignal(app: appName, windowTitle: title, tabURL: url, timestamp: now)
            // The plain signal goes out FIRST and unconditionally — tracking
            // never waits on email capture. Correspondents/subject arrive
            // later, if at all, as a separate .focusEnrichment event.
            emit(.focus(signal))
            captureEmailIfEligible(signal, bundleID: app.bundleIdentifier)
        }
    }

    /// Kicks off async, deadline-bounded correspondent capture when the new
    /// surface is a chrome-like browser on a known, recipe'd mail host —
    /// NEVER inline: a synchronous AppleScript round-trip run right here on
    /// the poll timer's thread is what froze tracking on 2026-06-30. The
    /// engine itself rate-limits (one capture in flight); a probe that
    /// outlives the user's next focus change is dropped by SessionTracker's
    /// same-surface check on arrival, not here.
    private func captureEmailIfEligible(_ signal: ActivitySignal, bundleID: String?) {
        guard let appName = EmailCaptureEngine.captureTarget(bundleID: bundleID, tabURL: signal.tabURL)
        else { return }
        // The subject is a cheap, synchronous read of the title — no need to
        // wait on the probe for it; only correspondents require the JS recipe.
        let subject = EmailSignal.subject(fromTitle: signal.windowTitle)
        emailCapture.capture(appName: appName) { [weak self] capture in
            let correspondents = capture?.correspondents ?? []
            guard !correspondents.isEmpty || (subject?.isEmpty == false) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let enriched = ActivitySignal(app: signal.app, windowTitle: signal.windowTitle,
                                              tabURL: signal.tabURL, timestamp: signal.timestamp,
                                              correspondents: correspondents.isEmpty ? nil : correspondents,
                                              emailSubject: subject)
                self.emit(.focusEnrichment(enriched))
            }
        }
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        guard accessibilityTrusted else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString,
                                            &window) == .success,
              let windowRef = window,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let windowElement = windowRef as! AXUIElement   // provably safe: type-checked above
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement,
                                            kAXTitleAttribute as CFString,
                                            &title) == .success else { return nil }
        return title as? String
    }

    // MARK: - Browser tabs (Apple Events; triggers the Automation prompt once)

    private let chromeLikeBundleIDs: Set<String> = [
        "com.google.Chrome", "com.operasoftware.Opera", "com.brave.Browser",
    ]

    /// Logged once per run, not per poll — a missing Automation grant fails
    /// EVERY read, and per-poll logging would flood the debug log.
    private var loggedTabURLError = false

    /// The frontmost tab's URL for any browser we can script: Chrome-likes
    /// share one AppleScript verb; Safari has its own ("URL of front
    /// document"). nil for everything else — and for browsers whose
    /// Automation grant is missing (logged once).
    private func activeTabURL(bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let source: String
        let appName: String
        if chromeLikeBundleIDs.contains(bundleID) {
            appName = bundleID == "com.google.Chrome" ? "Google Chrome"
                : bundleID == "com.operasoftware.Opera" ? "Opera" : "Brave Browser"
            source = "tell application \"\(appName)\" to get URL of active tab of front window"
        } else if bundleID == "com.apple.Safari" {
            appName = "Safari"
            source = "tell application \"Safari\" to get URL of front document"
        } else {
            return nil
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, !loggedTabURLError {
            loggedTabURLError = true
            // -1743 = Automation permission missing/denied for this browser:
            // every URL read fails SILENTLY, browser surfaces degrade to
            // app|title, and email detection starves. Make it findable.
            DebugLog.write("tab URL AppleScript failed for \(appName): \(error)")
        }
        return error == nil ? result?.stringValue : nil
    }
}

/// System-wide microphone-in-use via the default input device's
/// kAudioDevicePropertyDeviceIsRunningSomewhere.
final class MicMonitor {
    private let onChange: (Bool) -> Void
    private var deviceID = AudioDeviceID(0)
    private var lastActive = false
    private var timer: Timer?

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &deviceID)
        // Poll: property listeners on this selector are flaky across devices;
        // 2 s polling is cheap and robust.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.check()
        }
        timer?.tolerance = 0.5   // coalesces with the focus poll's wakeup
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        guard deviceID != 0 else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr
        else { return }
        let active = running != 0
        if active != lastActive {
            lastActive = active
            onChange(active)
        }
    }
}

/// Reads the display-sleep minutes from pmset; the spec derives the idle
/// threshold from the user's own sleep settings.
package enum PowerSettings {
    package static func displaySleepSeconds() -> TimeInterval? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "displaysleep", let minutes = Double(parts[1]) {
                return minutes > 0 ? minutes * 60 : nil   // 0 = never
            }
        }
        return nil
    }
}
