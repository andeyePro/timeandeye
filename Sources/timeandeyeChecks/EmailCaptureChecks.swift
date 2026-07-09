import Foundation
import timeandeyeCore
import timeandeyeMac

// MARK: - EmailCaptureEngine.captureTarget (the pure gate poll() pays on every
// non-email focus change; osascript/Process execution itself is impure and
// browser-dependent, so it's exercised on-device, not here).

func emailCaptureChecks(_ c: Checks) {
    // A realistic current-format Gmail thread id (32 alnum) and a legacy one
    // (16 hex) — the message-view classifier keys on this final segment.
    let thread = "FMfcgzQhVNSwdZHpvKxcJSqgPNZjDGrM"
    let legacy = "15f3a4b2c8d9e0f1"

    c.check("chrome-like browser on an OPEN Gmail message -> the AppleScript app name") {
        try expectEq(EmailCaptureEngine.captureTarget(
            bundleID: "com.google.Chrome",
            tabURL: "https://mail.google.com/mail/u/0/#inbox/\(thread)"), "Google Chrome")
    }

    c.check("a non-browser bundle id never captures") {
        try expectNil(EmailCaptureEngine.captureTarget(
            bundleID: "com.apple.Terminal",
            tabURL: "https://mail.google.com/mail/u/0/#inbox/\(thread)"))
    }

    c.check("a browser on a non-email host never captures") {
        try expectNil(EmailCaptureEngine.captureTarget(
            bundleID: "com.google.Chrome", tabURL: "https://github.com/andeyePro/timeandeye"))
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
            tabURL: "https://mail.google.com/mail/u/0/#inbox/\(thread)"), "Opera")
        try expectEq(EmailCaptureEngine.captureTarget(
            bundleID: "com.brave.Browser",
            tabURL: "https://mail.google.com/mail/u/0/#inbox/\(legacy)"), "Brave Browser")
    }

    // The stale-DOM guard (live fault 2026-07-09): returning to the inbox LIST
    // kept the previous conversation's .gD/.g2 nodes in Gmail's cached DOM, so
    // a capture on the list surface reported the LAST message's correspondents
    // — and the list title became a junk subject ("Inbox (1)"). List/label/
    // search/settings surfaces must never kick a capture off.
    c.check("Gmail LIST surfaces never capture (stale-DOM guard)") {
        for url in ["https://mail.google.com/mail/u/0/#inbox",
                    "https://mail.google.com/mail/u/0/#starred",
                    "https://mail.google.com/mail/u/0/#label/Client%20X",
                    "https://mail.google.com/mail/u/0/#search/andeye",
                    "https://mail.google.com/mail/u/0/#settings/general",
                    "https://mail.google.com/mail/u/0"] {
            try expectNil(EmailCaptureEngine.captureTarget(
                bundleID: "com.google.Chrome", tabURL: url))
        }
    }

    c.check("a message opened FROM search or a label is still a message view") {
        let thread = "FMfcgzQhVNSwdZHpvKxcJSqgPNZjDGrM"
        try expectEq(EmailCaptureEngine.captureTarget(
            bundleID: "com.google.Chrome",
            tabURL: "https://mail.google.com/mail/u/0/#search/andeye/\(thread)"), "Google Chrome")
        try expectEq(EmailCaptureEngine.captureTarget(
            bundleID: "com.google.Chrome",
            tabURL: "https://mail.google.com/mail/u/0/#label/Client%20X/\(thread)"), "Google Chrome")
    }

    c.check("isMessageView: systems with no known URL shape default to true") {
        // A future recipe'd system must not be silently gated before its
        // classifier is written — the gate stays recipe-only for them.
        try expectEq(EmailSystem.outlookWeb.isMessageView(urlString:
            "https://outlook.office.com/mail/inbox"), true)
    }

    c.check("isMessageView: Gmail with no fragment at all is not a message") {
        try expectEq(EmailSystem.gmail.isMessageView(urlString:
            "https://mail.google.com/mail/u/0"), false)
        try expectEq(EmailSystem.gmail.isMessageView(urlString: nil), false)
    }
}
