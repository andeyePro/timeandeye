#if os(macOS)
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

    c.check("every recipe'd system captures on its open-message URL, never on its list URL") {
        // One (message URL, list URL) pair per 2026-07-10 recipe-pack system —
        // the end-to-end gate: detect → hasRecipe → isMessageView. IDs are
        // realistic shapes (OWA base64 item id, Proton base64 element id,
        // Yahoo message id, Fastmail thread id).
        let pairs: [(String, String)] = [
            ("https://outlook.office.com/mail/inbox/id/AAQkADAwATM3ZmYAZS05NmQ4LWI4ZjMtMDACLTAwCgAQAJk3PTVyc0RGvYWkzhMkX9Y%3D",
             "https://outlook.office.com/mail/inbox"),
            ("https://mail.proton.me/u/0/inbox/hcBqAeQhI4LzXtRkq1zdQz5W0uwOSbrhMcO2b_9DTBjkZ2rBTCzXCtNMe0KvGqYm==",
             "https://mail.proton.me/u/0/inbox"),
            ("https://mail.yahoo.com/d/folders/1/messages/AIkzXW4AAAN1Zr0mVw9dR0X6xw",
             "https://mail.yahoo.com/d/folders/1"),
            ("https://app.fastmail.com/mail/Inbox/Tf6d8f01a24f3b1e8.M5a3c9d21b1a2?u=abc123",
             "https://app.fastmail.com/mail/Inbox/"),
        ]
        for (message, list) in pairs {
            try expectEq(EmailCaptureEngine.captureTarget(
                bundleID: "com.google.Chrome", tabURL: message), "Google Chrome", message)
            try expectNil(EmailCaptureEngine.captureTarget(
                bundleID: "com.google.Chrome", tabURL: list), list)
        }
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

    c.check("isMessageView: unknown (recipe-less) systems default to true") {
        // A future recipe'd system must not be silently gated before its
        // classifier is written — hasRecipe screens .unknown out long before
        // the gate, so the permissive default is unreachable in the pipeline.
        try expectEq(EmailSystem.unknown.isMessageView(urlString:
            "https://example.com/anything"), true)
    }

    c.check("isMessageView: Gmail with no fragment at all is not a message") {
        try expectEq(EmailSystem.gmail.isMessageView(urlString:
            "https://mail.google.com/mail/u/0"), false)
        try expectEq(EmailSystem.gmail.isMessageView(urlString: nil), false)
    }

    c.check("isMessageView: OWA pop-out readers name the item in the query") {
        // Deeplink/pop-out route has no /id/ path segment; the item id rides
        // in an itemid (or id) query parameter instead.
        try expectEq(EmailSystem.outlookWeb.isMessageView(urlString:
            "https://outlook.office.com/mail/deeplink/read?ItemID=AAQkADAwATM3ZmYAZS05NmQ4LWI4ZjMtMDACLTAwCgAQAJk3"), true)
        try expectEq(EmailSystem.outlookWeb.isMessageView(urlString:
            "https://outlook.office.com/mail/options/general"), false)
        try expectEq(EmailSystem.outlookWeb.isMessageView(urlString: nil), false)
    }

    c.check("isMessageView: OWA id params outside /mail/ never classify as messages") {
        // Calendar, settings and deeplink surfaces on the outlook hosts carry
        // id-shaped params too — an open message needs the /mail/ route
        // segment ALONGSIDE the id, or every calendar deeplink would feed
        // noParties strikes into the mail recipe's health.
        for url in ["https://outlook.office.com/calendar/deeplink/compose?itemid=AAQkADAwATM3ZmYAZS05NmQ4LWI4ZjMtMDACLTAw",
                    "https://outlook.office.com/calendar/item/AAQkADAwATM3ZmYAZS05NmQ4LWI4ZjMtMDACLTAwCgAQAJk3",
                    "https://outlook.office.com/options/general?id=AAQkADAwATM3ZmYAZS05NmQ4"] {
            try expectEq(EmailSystem.outlookWeb.isMessageView(urlString: url), false, url)
        }
    }

    c.check("isMessageView: a Proton custom folder whose LABEL is a long id is still a list") {
        // Custom folders route as /u/<n>/<labelId> — one segment after the
        // account index, however id-like it looks. Only a SECOND long
        // segment (the element id) marks an open conversation.
        try expectEq(EmailSystem.proton.isMessageView(urlString:
            "https://mail.proton.me/u/0/hcBqAeQhI4LzXtRkq1zdQz5W0uwOSbrhMcO2b9DTBjk"), false)
        try expectEq(EmailSystem.proton.isMessageView(urlString:
            "https://mail.proton.me/u/0/hcBqAeQhI4LzXtRkq1zdQz5W0uwOSbrhMcO2b9DTBjk/WzK9vXtRkq1zdQz5W0uwOSbrhMcO2b9DTBjkZ2rBTCzX=="), true)
        try expectEq(EmailSystem.proton.isMessageView(urlString:
            "https://mail.proton.me/u/0/inbox/short"), false, "short trailing segment is a route word, not an id")
    }

    c.check("isMessageView: Yahoo and Fastmail search/settings surfaces are lists") {
        try expectEq(EmailSystem.yahoo.isMessageView(urlString:
            "https://mail.yahoo.com/d/search/keyword=andeye"), false)
        try expectEq(EmailSystem.fastmail.isMessageView(urlString:
            "https://app.fastmail.com/mail/search:from%3Arae/"), false,
            "search: mailbox segment with no thread id is a list")
        try expectEq(EmailSystem.fastmail.isMessageView(urlString:
            "https://app.fastmail.com/settings/account"), false)
    }
}

// MARK: - EmailSystem recipe pack (detection + selector invariants). The
// selectors themselves are validated at RUNTIME by design (EmailRecipeHealth)
// — no fake DOM here; these pin the pure model around them.

func emailSystemRecipeChecks(_ c: Checks) {
    c.check("host detection: every recipe-pack host maps to its system") {
        let cases: [(String, EmailSystem)] = [
            ("mail.google.com", .gmail),
            ("outlook.office.com", .outlookWeb),
            ("outlook.live.com", .outlookWeb),
            ("outlook.office365.com", .outlookWeb),
            ("mail.proton.me", .proton),
            ("mail.protonmail.com", .proton),
            ("mail.yahoo.com", .yahoo),
            ("fastmail.com", .fastmail),
            ("app.fastmail.com", .fastmail),
            ("MAIL.YAHOO.COM", .yahoo),   // hosts compare case-insensitively
        ]
        for (host, system) in cases {
            try expectEq(EmailSystem.detect(urlHost: host), system, host)
        }
    }

    c.check("host detection is anchored: lookalike hosts never match") {
        // hasSuffix alone accepts "notmail.google.com" (it ends with
        // "mail.google.com") — a page we must never inject recipe JS into.
        // Matches must be the domain itself or a true dot-separated subdomain.
        for host in ["notmail.google.com",
                     "notmail.yahoo.com",
                     "myfastmail.com",
                     "mail.proton.me.evil.example",   // prefix lookalike
                     "outlook.office.com.phish.example",
                     "mail.yahoo.com.example.net",
                     "github.com"] {
            try expectEq(EmailSystem.detect(urlHost: host), .unknown, host)
        }
    }

    c.check("every webmail system ships a recipe; both selectors always travel together") {
        for system in EmailSystem.allCases where system != .unknown {
            try expect(system.hasRecipe, "\(system) lost its recipe")
            try expect(!(system.senderSelector ?? "").isEmpty, "\(system) sender selector empty")
            try expect(!(system.recipientSelector ?? "").isEmpty, "\(system) recipient selector empty")
        }
        try expectNil(EmailSystem.unknown.senderSelector)
        try expectNil(EmailSystem.unknown.recipientSelector)
    }

    c.check("selectors are AppleScript/JS embedding-safe (no quotes, no backslashes)") {
        // Recipes travel inside a single-quoted JS string inside a
        // double-quoted AppleScript string (EmailCaptureEngine.jsScript) —
        // any quote or backslash in a selector breaks the whole capture, so
        // attribute values with non-identifier chars must use substring
        // matchers instead of quoting.
        for system in EmailSystem.allCases {
            for selector in [system.senderSelector, system.recipientSelector].compactMap({ $0 }) {
                try expect(!selector.contains("'"), "\(system): single quote in \(selector)")
                try expect(!selector.contains("\""), "\(system): double quote in \(selector)")
                try expect(!selector.contains("\\"), "\(system): backslash in \(selector)")
            }
        }
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

    // The capture JS pre-filters value-less nodes, so a redesign that swaps
    // attributes to opaque tokens reaches Swift as EMPTY party lists — only
    // the JS's matched-but-unparseable count can tell that apart from
    // selectors matching nothing. Without it, garbage would misreport as
    // noParties and misdirect diagnosis (and the future re-learn loop).
    c.check("empty parties WITH unparseable matches -> garbage, not noParties") {
        try expectEq(EmailRecipeValidation.validate(
            senders: [], recipients: [], unparseable: 3),
            .suspect(.garbage))
        try expectEq(EmailRecipeValidation.validate(
            senders: [], recipients: [], unparseable: 0),
            .suspect(.noParties))
    }

    // EAI local parts and IDN domains are real addresses — an ASCII-only
    // shape test silently dropped them (and misclassified such reads).
    c.check("unicode addresses pass the shape test; opaque tokens still fail") {
        for good in ["杨@example.com", "user@bücher.de", "béatrice@exemple.fr",
                     "info@пример.рф", "user@example.xn--p1ai",
                     "a.b+tag@sub.example.co.uk"] {
            try expect(EmailSignal.isAddress(good), good)
        }
        for bad in ["1kX9fzQ", "Rae Naismith", "user@", "@example.com",
                    "user@nodot", "a b@example.com", "user@example.c"] {
            try expect(!EmailSignal.isAddress(bad), bad)
        }
        // And the verdict pipeline enriches with them, not around them.
        try expectEq(EmailRecipeValidation.validate(
            senders: [party("杨", "杨@例子.中国")], recipients: []),
            .healthy([party("杨", "杨@例子.中国")]))
    }

    // Gmail decorates some chips with opaque hovercard ids while the header
    // chip stays sound — a PARTIAL redesign must not discard the good read.
    c.check("one sound address among garbage chips is still healthy") {
        try expectEq(EmailRecipeValidation.validate(
            senders: [party("", "1kX9fzQ"), party("Rae", "rae@harborlane.example")],
            recipients: []),
            .healthy([party("Rae", "rae@harborlane.example")]))
    }

    // Implausibly many counterparties can be a selector scraping the LIST
    // surface — but just as well a legitimate reply-all storm, and either
    // way the selectors demonstrably resolved addresses. So a flood enriches
    // with the sender + leading recipients (capped) and NEVER strikes recipe
    // health; a big (but plausible) CC list stays plain healthy.
    c.check("a flood of counterparties -> flooded: capped enrichment, sender kept, NO health strike") {
        let sender = party("S", "sender@example.com")
        let storm = (0..<20).map { party("P\($0)", "p\($0)@example.com") }
        let v = EmailRecipeValidation.validate(senders: [sender], recipients: storm)
        // counterparties() lists senders first, so the cap keeps the sender
        // (the strong signal) and truncates the recipient tail.
        try expectEq(v, .flooded([sender] + storm.prefix(
            EmailRecipeValidation.maxPlausibleCounterparties - 1)))
        // Health: a flood neither strikes (the selectors plainly work — it
        // must never drive a re-learn) nor resets an existing streak (its
        // untrusted tail is not proof of a sound recipe).
        var h = EmailRecipeHealth().recording(.suspect(.noParties))
        h = h.recording(v)
        try expectEq(h.consecutiveFailures, 1, "flooded must leave the streak untouched")
        try expectEq(h.lastFault, .noParties)
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
#endif
