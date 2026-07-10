import Foundation

/// A recognised email system and where, in its rendered page, the sender and
/// recipients live. The recipe is a DOM selector (run via the browser's JS
/// channel) — data, not code, so it can later ship in an updatable pack and be
/// self-healed when a provider redesigns. Gmail's recipe is validated live
/// (`.gD` = open-message sender, `.g2` = recipients, confirmed 2026-06-29);
/// the OWA/Proton/Yahoo/Fastmail recipes are researched from provider source /
/// extension evidence (per-case comments below) but NOT yet verified against a
/// live DOM — validate-on-use (`EmailRecipeValidation`) is the guard: a wrong
/// selector yields a suspect read that never enriches and self-reports
/// unhealthy after 3 strikes.
///
/// SELECTOR EMBEDDING CONSTRAINT: recipes travel inside a single-quoted JS
/// string inside a double-quoted AppleScript string (see
/// `EmailCaptureEngine.jsScript`), so a selector may contain NO quote of
/// either kind and NO backslash. Attribute values must therefore be written
/// unquoted — which CSS only allows for identifier-shaped values, so testids
/// containing ':' (Proton's `recipients:sender`) are matched with substring
/// operators (`[data-testid*=sender]`) instead. A checks-suite invariant
/// enforces this for every recipe.
public enum EmailSystem: String, CaseIterable, Sendable {
    case gmail
    case outlookWeb
    case proton
    case yahoo
    case fastmail
    case unknown

    /// Anchored host match: the domain itself or a true subdomain. A bare
    /// `hasSuffix` accepts lookalikes — "notmail.google.com" ends with
    /// "mail.google.com" — which matters now that every match carries a
    /// recipe that gets injected into the page as JavaScript.
    private static func hostMatches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// Identify the system from the active tab URL host (webmail) — native
    /// clients will route via bundle id in a later pass.
    public static func detect(urlHost host: String?) -> EmailSystem {
        guard let h = host?.lowercased() else { return .unknown }
        if hostMatches(h, "mail.google.com") { return .gmail }
        if hostMatches(h, "outlook.office.com") || hostMatches(h, "outlook.live.com")
            || hostMatches(h, "outlook.office365.com") { return .outlookWeb }
        if hostMatches(h, "mail.proton.me") || hostMatches(h, "mail.protonmail.com") { return .proton }
        if hostMatches(h, "mail.yahoo.com") { return .yahoo }
        if hostMatches(h, "fastmail.com") { return .fastmail }   // anchored: not myfastmail.com (C20)
        return .unknown
    }

    /// Human-readable name ("Gmail" not "gmail") — the Evidence Card / identity
    /// chain's display form.
    public var label: String {
        switch self {
        case .gmail: return "Gmail"
        case .outlookWeb: return "Outlook"
        case .proton: return "Proton Mail"
        case .yahoo: return "Yahoo Mail"
        case .fastmail: return "Fastmail"
        case .unknown: return "Email"
        }
    }

    /// DOM selector for the open message's sender chip(s). nil = recipe not
    /// known yet (falls back to a probe / AI-derive). The capture JS reduces
    /// each matched element to an address via an attribute ladder
    /// (`email`/`data-hovercard-id`/`data-email`/`title`, then address-shaped
    /// text) — so a recipe only has to FIND the sender element, not name the
    /// attribute the address hides in.
    public var senderSelector: String? {
        switch self {
        case .gmail:
            // Validated against the live DOM 2026-06-29; address in the
            // `email` attribute. A blanket `[email]` query is polluted by the
            // ~100+ inbox-list `.yP` rows Gmail keeps cached in the DOM.
            return ".gD"
        case .outlookWeb:
            // `data-testid="message-header-from"` container; address in the
            // `title` of an inner span (alimtvnetwork/email-assistant-spec
            // selectors.v1.json) or in `data-email` on the
            // `message-header-persona-primary` node (AlexMos555/linkshield
            // webmail.js; same testids in Dwarak18/Phishlink and
            // mithielesh/ShieldBox). Cross-corroborated across 4 independent
            // extension repos, retrieved 2026-07-10; unverified against live
            // DOM. Older OWA builds hid the SMTP address behind a LivePersona
            // hover fetch (mailvelope), so an empty read here is plausible —
            // health telemetry will say so.
            return "[data-testid=message-header-from] span[title], "
                + "[data-testid=message-header-from] [data-testid=message-header-persona-primary]"
        case .proton:
            // Authoritative from ProtonMail/WebClients source (retrieved
            // 2026-07-10, main branch): HeaderExpanded.tsx wraps the sender
            // RecipientItem in `.message-header-from-container` and stamps it
            // `data-testid="recipients:sender"`; RecipientItemLayout.tsx puts
            // the raw address in that node's `title`. `*=sender` because the
            // ':' in the testid can't be written unquoted (see the embedding
            // constraint above). Unverified against live DOM.
            return ".message-header-from-container [data-testid*=sender]"
        case .yahoo:
            // `data-test-id="message-from"` (note: test-id, not testid)
            // container in the open-message header; address in inner
            // `span[title]` (Remus-Chisleac/mail-scan extractors/yahoo.ts) or
            // `data-email` on the `email-pill` node (AlexMos555/linkshield);
            // mailvelope's maintained providerSpecific.js uses the same
            // message-from/email-pill pair. Retrieved 2026-07-10; unverified
            // against live DOM.
            return "[data-test-id=message-from] span[title], "
                + "[data-test-id=message-from] [data-test-id=email-pill]"
        case .fastmail:
            // WEAK EVIDENCE — best candidate only. Fastmail's app is closed
            // source; its own jmap-demo-webmail (jmapio, MessageView.js) puts
            // the sender in `h2.v-Message-from`, and a real-app user style
            // (gist DanH42/fastmail.css) confirms the live app keeps the same
            // `v-Message-*` Overture class family. In the demo that node
            // carries the display NAME only (the bare address only when no
            // contact name exists), so this recipe may read nothing for known
            // contacts; expect health telemetry to flag it. Retrieved
            // 2026-07-10; unverified against live DOM.
            return ".v-Message-from"
        case .unknown:
            return nil
        }
    }

    /// DOM selector for the open message's recipient chips. May legitimately
    /// match nothing (BCC-only mail); validation only needs SOME party across
    /// sender + recipients, so a weak recipient selector doesn't sink a
    /// healthy sender read.
    public var recipientSelector: String? {
        switch self {
        case .gmail:
            return ".g2"   // validated live 2026-06-29
        case .outlookWeb:
            // Same selectors-pack evidence as the sender (retrieved
            // 2026-07-10, unverified live): to/cc containers mirror the from
            // testid.
            return "[data-testid=message-header-to] span[title], "
                + "[data-testid=message-header-cc] span[title]"
        case .proton:
            // ProtonMail/WebClients source (2026-07-10): every recipient
            // chip is a RecipientItem whose testid CONTAINS "recipient"
            // (`recipients:item-<addr>` in the simple To row,
            // `recipient:details-dropdown-<addr>` in expanded details) and
            // whose `title` is the raw address. This also re-matches the
            // sender chip (`recipients:sender`) — harmless, counterparties
            // de-dupe by address. Unverified against live DOM.
            return "[data-testid*=recipient][title]"
        case .yahoo:
            // BEST GUESS mirroring the evidenced message-from shape — no
            // extractor in the researched sources reads open-message
            // recipients on Yahoo (mailvelope only handles compose pills).
            // Unverified against live DOM; a miss costs nothing (see above).
            return "[data-test-id=message-to] span[title], "
                + "[data-test-id=message-to] [data-test-id=email-pill]"
        case .fastmail:
            // Same weak evidence as the sender: jmap-demo-webmail renders
            // `div.v-Message-to`; unverified against the live app.
            return ".v-Message-to"
        case .unknown:
            return nil
        }
    }

    public var hasRecipe: Bool { senderSelector != nil }

    /// Whether the tab URL names an OPEN MESSAGE rather than a list/label/
    /// search surface. Correspondent capture must only run on message views:
    /// Gmail keeps the last-open conversation's DOM cached when you return to
    /// a list, so the selectors report the PREVIOUS message's parties against
    /// the list surface (seen live 2026-07-09: `#inbox` carrying the
    /// correspondents of the message read a minute earlier) — and a list
    /// title makes a junk subject ("Inbox (1)"). Each provider's classifier
    /// is derived from its route shape (per-case comments); all fail CLOSED
    /// (unrecognised URL → no capture), which costs a missed enrichment, not
    /// a polluted one. `.unknown` returns true so a future recipe isn't
    /// silently gated before its classifier is written (it has no recipe, so
    /// the gate is never reached today).
    public func isMessageView(urlString: String?) -> Bool {
        switch self {
        case .gmail:
            // Message URLs end the fragment with a long alphanumeric thread
            // id (`#inbox/FMfcgz…`, legacy 16-hex too); list/label/search/
            // settings segments are short words.
            guard let s = urlString, let frag = URL(string: s)?.fragment else { return false }
            let path = frag.split(separator: "?").first.map(String.init) ?? frag
            guard let last = path.split(separator: "/").last else { return false }
            return last.count >= 16
                && last.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        case .outlookWeb:
            // Selecting/opening a message appends `/id/<itemID>` to the
            // folder route (`/mail/inbox/id/AAQkAD…`); pop-out readers name
            // the item in an `itemid`/`id` query instead (evidence:
            // fordz0/DTNP-Extension getOutlookMessageId, 2026-07-10). Item
            // ids are long base64 — 16 chars screens out short route words.
            // The `/mail/` segment is required alongside the id: calendar/
            // settings/deeplink surfaces on the same hosts carry id-shaped
            // params too (`/calendar/deeplink/compose?itemid=…`), and they
            // must not classify as open messages (fail closed, as everywhere
            // in this classifier — the cost is a missed enrichment).
            guard let comps = Self.pathComponents(urlString),
                  comps.contains("mail") else { return false }
            if let i = comps.firstIndex(of: "id"), i + 1 < comps.count,
               comps[i + 1].count >= 16 { return true }
            guard let s = urlString, let q = URLComponents(string: s)?.queryItems else { return false }
            return q.contains { ["itemid", "id"].contains($0.name.lowercased())
                && ($0.value?.count ?? 0) >= 16 }
        case .proton:
            // List = `/u/<n>/<label>`; open conversation appends the element
            // id: `/u/<n>/<label>/<id>` (id = long base64, may carry '='
            // padding). Requiring ≥2 segments after `/u/<n>` keeps custom
            // folders — whose LABEL is itself a long id at 1 segment — out.
            guard let comps = Self.pathComponents(urlString),
                  comps.count >= 4, comps.first == "u" else { return false }
            let last = comps[comps.count - 1]
            return last.count >= 16 && last.allSatisfy {
                $0.isLetter || $0.isNumber || "-_=+".contains($0)
            }
        case .yahoo:
            // List = `/d/folders/<n>`; open message appends `/messages/<id>`.
            guard let comps = Self.pathComponents(urlString) else { return false }
            if let i = comps.firstIndex(of: "messages"), i + 1 < comps.count {
                return !comps[i + 1].isEmpty
            }
            return false
        case .fastmail:
            // List = `/mail/<mailbox>/`; open thread appends its id:
            // `/mail/<mailbox>/<threadId>`. Search lists (`/mail/search:…/`)
            // stay at 2 segments, so they classify as lists too.
            guard let comps = Self.pathComponents(urlString),
                  comps.count >= 3, comps.first == "mail" else { return false }
            return !comps[2].isEmpty
        case .unknown:
            return true
        }
    }

    /// The URL's path split into segments ("/" entries dropped,
    /// percent-decoding applied per component). nil when the string isn't a
    /// URL or has an empty path.
    private static func pathComponents(_ urlString: String?) -> [String]? {
        guard let s = urlString, let url = URL(string: s) else { return nil }
        let comps = url.pathComponents.filter { $0 != "/" }
        return comps.isEmpty ? nil : comps
    }
}
