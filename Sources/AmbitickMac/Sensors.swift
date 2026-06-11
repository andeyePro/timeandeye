import Foundation
import AppKit
import CoreAudio
import CoreGraphics
import ApplicationServices
import AmbitickCore

/// All real-world observation, emitting Core's SensorEvents through one callback.
/// Polling design (2 s) keeps the AX surface minimal; event-driven AXObserver
/// is a future refinement.
public final class SensorHub {
    public var onEvent: (SensorEvent) -> Void = { _ in }
    public private(set) var accessibilityTrusted = false

    private var pollTimer: Timer?
    private var lastSurfaceKey: String?
    private var micMonitor: MicMonitor?

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

        micMonitor = MicMonitor { [weak self] active in
            self?.onEvent(.microphone(active: active, at: Date()))
        }
        micMonitor?.start()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        micMonitor?.stop()
    }

    // MARK: - Polling

    private func poll() {
        let now = Date()
        // Input recency: CGEventSource needs no permission.
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        onEvent(.input(now.addingTimeInterval(-idleSeconds)))

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appName = app.localizedName ?? "Unknown"
        let title = focusedWindowTitle(pid: app.processIdentifier)
        let url = chromeLikeBundleIDs.contains(app.bundleIdentifier ?? "")
            ? activeChromeTabURL(bundleID: app.bundleIdentifier!) : nil

        let key = "\(appName)|\(title ?? "")|\(url ?? "")"
        if key != lastSurfaceKey {
            lastSurfaceKey = key
            onEvent(.focus(ActivitySignal(app: appName, windowTitle: title,
                                          tabURL: url, timestamp: now)))
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
