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

// MARK: - Validate-on-use + per-system recipe health (the NAIL self-heal
// architecture's cheap half). Pure Core logic, so webmail-redesign scenarios
// are checkable with no browser in the loop; the impure wiring (engine drops
// suspect captures, seam fires at the threshold) follows the same functions.

func emailRecipeHealthChecks(_ c: Checks) {
    func party(_ name: String, _ email: String) -> EmailSignal.Party {
        EmailSignal.Party(name: name, email: email)
    }
    let own: Set<String> = ["martin@andeye.com"]

    c.check("one plausible sender -> healthy, with that counterparty") {
        try expectEq(EmailRecipeValidation.validate(
            senders: [party("Rae", "r.naismith@harborlane.example")],
            recipients: [party("me", "martin@andeye.com")],
            ownAddresses: own),
            .healthy([party("Rae", "r.naismith@harborlane.example")]))
    }

    // A note-to-self (or an own-domain-only thread) reads FINE — the recipe
    // resolved, there just is no external party. Branding it a failure would
    // tick the streak on every self-addressed note and eventually trigger a
    // pointless re-learn of a working recipe.
    c.check("own-address-only read -> selfOnly, and it does NOT count as a recipe failure") {
        let v = EmailRecipeValidation.validate(
            senders: [party("Martin", "martin@andeye.com")],
            recipients: [party("me", "martin@andeye.com")],
            ownAddresses: own)
        try expectEq(v, .selfOnly)
        var h = EmailRecipeHealth().recording(.suspect(.noParties))
        h = h.recording(v)
        try expectEq(h.consecutiveFailures, 0, "selfOnly must reset, not increment")
    }

    // The redesign symptom that motivates the whole programme: Gmail renames
    // `.gD` and the selector matches nothing on a page the capture gate has
    // ALREADY classified as an open message — so emptiness means broken
    // recipe, not absence of mail (list surfaces never reach validation).
    c.check("zero parties on a message view -> suspect(noParties)") {
        try expectEq(EmailRecipeValidation.validate(senders: [], recipients: []),
                     .suspect(.noParties))
    }

    // The other redesign shape: selectors still match nodes, but the email
    // attribute now carries opaque tokens / display names, not addresses.
    c.check("nothing address-shaped -> suspect(garbage)") {
        try expectEq(EmailRecipeValidation.validate(
            senders: [party("Rae", "Rae Naismith"), party("", "1kX9fzQ")],
            recipients: []),
            .suspect(.garbage))
    }

    // Gmail decorates some chips with opaque hovercard ids while the header
    // chip stays sound — a PARTIAL redesign must not discard the good read.
    c.check("one sound address among garbage chips is still healthy") {
        try expectEq(EmailRecipeValidation.validate(
            senders: [party("", "1kX9fzQ"), party("Rae", "rae@harborlane.example")],
            recipients: []),
            .healthy([party("Rae", "rae@harborlane.example")]))
    }

    // A selector that has started matching the LIST surface scrapes one
    // address per inbox row — far beyond any single message's header. A big
    // (but plausible) CC list must stay healthy, though.
    c.check("an implausible flood of counterparties -> suspect(partyFlood); a big CC list is fine") {
        let flood = (0..<20).map { party("P\($0)", "p\($0)@example.com") }
        try expectEq(EmailRecipeValidation.validate(senders: flood, recipients: []),
                     .suspect(.partyFlood))
        let cc = (0..<EmailRecipeValidation.maxPlausibleCounterparties)
            .map { party("P\($0)", "p\($0)@example.com") }
        try expectEq(EmailRecipeValidation.validate(
            senders: [cc[0]], recipients: Array(cc.dropFirst())),
            .healthy(cc))
    }

    c.check("streak marks unhealthy exactly at the threshold, not before") {
        var h = EmailRecipeHealth()
        for i in 1...EmailRecipeHealth.unhealthyThreshold {
            try expectEq(h.isUnhealthy, false, "already unhealthy before failure \(i)")
            h = h.recording(.suspect(.noParties))
        }
        try expect(h.isUnhealthy)
        try expectEq(h.lastFault, .noParties)
    }

    c.check("a healthy read resets the streak completely") {
        var h = EmailRecipeHealth()
        h = h.recording(.suspect(.garbage))
        h = h.recording(.suspect(.garbage))
        h = h.recording(.healthy([party("J", "j@example.com")]))
        try expectEq(h.consecutiveFailures, 0)
        try expectNil(h.lastFault)
        // A fresh failure after recovery starts from 1 — transient wobbles
        // (slow page loads) must never accumulate ACROSS healthy reads into
        // a false unhealthy.
        h = h.recording(.suspect(.noParties))
        try expectEq(h.isUnhealthy, false)
        try expectEq(h.consecutiveFailures, 1)
    }
}
