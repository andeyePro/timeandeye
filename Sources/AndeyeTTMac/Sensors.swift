import Foundation
import AppKit
import CoreAudio
import CoreGraphics
import ApplicationServices
import AndeyeTTCore

/// All real-world observation, emitting Core's SensorEvents through one callback.
/// Polling design (2 s) keeps the AX surface minimal; event-driven AXObserver
/// is a future refinement.
public final class SensorHub {
    public var onEvent: (SensorEvent) -> Void = { _ in }
    public private(set) var accessibilityTrusted = false

    private var pollTimer: Timer?
    private var lastSurfaceKey: String?
    private var micMonitor: MicMonitor?
    private var screenLocked = false
    private let emailCapture = EmailCaptureEngine()

    public init() {}

    /// Prompts for Accessibility on first run (window titles need it).
    public func requestPermissions() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    public func start() {
        accessibilityTrusted = AXIsProcessTrusted()

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                              object: nil, queue: .main) { [weak self] _ in
            self?.onEvent(.willSleep(Date()))
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                              object: nil, queue: .main) { [weak self] _ in
            self?.onEvent(.didWake(Date()))
        }

        // Screen lock/unlock: while locked, the frontmost window is not really
        // in use, so we suppress window detail (and tell Core to close the open
        // span). These are the documented loginwindow distributed notifications.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
            self?.onEvent(.screenLocked(Date()))
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
            self?.onEvent(.screenUnlocked(Date()))
        }

        micMonitor = MicMonitor { [weak self] active in
            self?.onEvent(.microphone(active: active, at: Date()))
        }
        micMonitor?.start()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Focus sampling doesn't care about sub-second phase; tolerance lets
        // the OS coalesce this wakeup with the mic poll (same cadence).
        pollTimer?.tolerance = 0.5
        poll()
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        micMonitor?.stop()
    }

    // MARK: - Polling

    private func poll() {
        // Re-check live: the user may grant Accessibility while we run, and a
        // launch-time cache held window titles at nil for a whole session.
        if !accessibilityTrusted { accessibilityTrusted = AXIsProcessTrusted() }
        let now = Date()
        // Input recency: CGEventSource needs no permission.
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        onEvent(.input(now.addingTimeInterval(-idleSeconds)))
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
        let url = chromeLikeBundleIDs.contains(app.bundleIdentifier ?? "")
            ? activeChromeTabURL(bundleID: app.bundleIdentifier!) : nil

        let key = "\(appName)|\(title ?? "")|\(url ?? "")"
        if key != lastSurfaceKey {
            lastSurfaceKey = key
            let signal = ActivitySignal(app: appName, windowTitle: title, tabURL: url, timestamp: now)
            // The plain signal goes out FIRST and unconditionally — tracking
            // never waits on email capture. Correspondents/subject arrive
            // later, if at all, as a separate .focusEnrichment event.
            onEvent(.focus(signal))
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
                self.onEvent(.focusEnrichment(enriched))
            }
        }
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        guard accessibilityTrusted else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString,
                                            &window) == .success,
              let windowElement = window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement as! AXUIElement,
                                            kAXTitleAttribute as CFString,
                                            &title) == .success else { return nil }
        return title as? String
    }

    // MARK: - Browser tabs (Apple Events; triggers the Automation prompt once)

    private let chromeLikeBundleIDs: Set<String> = [
        "com.google.Chrome", "com.operasoftware.Opera", "com.brave.Browser",
    ]

    private func activeChromeTabURL(bundleID: String) -> String? {
        let appName = bundleID == "com.google.Chrome" ? "Google Chrome"
            : bundleID == "com.operasoftware.Opera" ? "Opera" : "Brave Browser"
        let source = "tell application \"\(appName)\" to get URL of active tab of front window"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
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
public enum PowerSettings {
    public static func displaySleepSeconds() -> TimeInterval? {
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
