import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut backed by Carbon's `RegisterEventHotKey`.
///
/// `NSEvent` local monitors (used for ⌘Z undo) and SwiftUI `.keyboardShortcut`
/// only fire while Ambitick — or its popover — is the key window. "Away" needs
/// to toggle while you're in *another* app on your way out the door, so it has
/// to be a true global hotkey. Carbon's RegisterEventHotKey is the documented,
/// non-sandbox-tripping way to do that without an Accessibility-tap CGEvent.
///
/// The Carbon event handler is a bare C function pointer and cannot capture
/// Swift context, so we hand the instance through as `userData` and recover it
/// inside the handler. The actual callback runs on the main actor — Carbon
/// dispatches the handler on the main run loop already, but we hop explicitly
/// so the `@MainActor`-isolated AppController state mutation is sound.
public final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32
    private let onFire: () -> Void

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `kVK_ANSI_L`.
    ///   - modifiers: Carbon modifier mask, e.g. `cmdKey | shiftKey`.
    ///   - signature: a 4-char OSType identifying the app's hotkeys.
    ///   - id: an app-unique id for this hotkey (matched in the handler).
    ///   - onFire: invoked on the main actor each time the chord is pressed.
    public init?(keyCode: UInt32,
                 modifiers: UInt32,
                 signature: OSType,
                 id: UInt32,
                 onFire: @escaping () -> Void) {
        self.id = id
        self.onFire = onFire

        // Install one application-level handler for hot-key-pressed events. The
        // GlobalHotKey instance is the userData; passUnretained is safe because
        // we unregister the handler in deinit, before self goes away.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            GlobalHotKey.handlerCallback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef)
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Matched against the EventHotKeyID carried by the event, then fires on
    /// the main actor. Carbon already calls the handler on the main run loop,
    /// but the explicit hop keeps the `@MainActor` callback contract honest and
    /// future-proof against handler-target changes.
    fileprivate func fireIfMatches(_ eventID: EventHotKeyID) {
        guard eventID.id == id else { return }
        let cb = onFire
        DispatchQueue.main.async { cb() }
    }

    /// Bare C function pointer — no Swift context capture. Recovers the
    /// GlobalHotKey from userData and pulls the EventHotKeyID off the event.
    private static let handlerCallback: EventHandlerUPP = { _, eventRef, userData in
        guard let userData, let eventRef else { return noErr }
        let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID)
        guard status == noErr else { return status }
        me.fireIfMatches(hotKeyID)
        return noErr
    }
}
