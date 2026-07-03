import Foundation
import AndeyeTTMac

// MARK: - EmailCaptureEngine.captureTarget (the pure gate poll() pays on every
// non-email focus change; osascript/Process execution itself is impure and
// browser-dependent, so it's exercised on-device, not here).

func emailCaptureChecks(_ c: Checks) {
    c.check("chrome-like browser on a recipe'd mail host -> the AppleScript app name") {
        try expectEq(EmailCaptureEngine.captureTarget(
            bundleID: "com.google.Chrome",
            tabURL: "https://mail.google.com/mail/u/0/#inbox/abc"), "Google Chrome")
    }

    c.check("a non-browser bundle id never captures") {
        try expectNil(EmailCaptureEngine.captureTarget(
            bundleID: "com.apple.Terminal",
            tabURL: "https://mail.google.com/mail/u/0/#inbox/abc"))
    }

    c.check("a browser on a non-email host never captures") {
        try expectNil(EmailCaptureEngine.captureTarget(
            bundleID: "com.google.Chrome", tabURL: "https://github.com/andeyePro/andeyeTT"))
    }

    c.check("a detected email system with no recipe yet (Outlook) never captures") {
        try expectNil(EmailCaptureEngine.captureTarget(
            bundleID: "com.google.Chrome", tabURL: "https://outlook.office.com/mail/inbox"))
    }

    c.check("no tab URL at all -> never captures") {
        try expectNil(EmailCaptureEngine.captureTarget(bundleID: "com.google.Chrome", tabURL: nil))
    }

    c.check("Opera and Brave are recognised the same as Chrome") {
        try expectEq(EmailCaptureEngine.captureTarget(
            bundleID: "com.operasoftware.Opera",
            tabURL: "https://mail.google.com/mail/u/0"), "Opera")
        try expectEq(EmailCaptureEngine.captureTarget(
            bundleID: "com.brave.Browser",
            tabURL: "https://mail.google.com/mail/u/0"), "Brave Browser")
    }
}
