import Foundation

/// A recognised email system and where, in its rendered page, the sender and
/// recipients live. The recipe is a DOM selector (run via the browser's JS
/// channel) — data, not code, so it can later ship in an updatable pack and be
/// self-healed when a provider redesigns. Only Gmail is validated so far
/// (`.gD` = open-message sender, `.g2` = recipients, confirmed 2026-06-29).
public enum EmailSystem: String, CaseIterable, Sendable {
    case gmail
    case outlookWeb
    case proton
    case yahoo
    case fastmail
    case unknown

    /// Identify the system from the active tab URL host (webmail) — native
    /// clients will route via bundle id in a later pass.
    public static func detect(urlHost host: String?) -> EmailSystem {
        guard let h = host?.lowercased() else { return .unknown }
        if h.hasSuffix("mail.google.com") { return .gmail }
        if h.hasSuffix("outlook.office.com") || h.hasSuffix("outlook.live.com")
            || h.hasSuffix("outlook.office365.com") { return .outlookWeb }
        if h.hasSuffix("mail.proton.me") || h.hasSuffix("mail.protonmail.com") { return .proton }
        if h.hasSuffix("mail.yahoo.com") { return .yahoo }
        if h == "fastmail.com" || h.hasSuffix(".fastmail.com") { return .fastmail }   // anchored: not myfastmail.com (C20)
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

    /// DOM selector for the open message's sender chip(s). nil = recipe not known
    /// yet (falls back to a probe / AI-derive).
    public var senderSelector: String? {
        switch self {
        case .gmail: return ".gD"
        default: return nil
        }
    }

    /// DOM selector for the open message's recipient chips.
    public var recipientSelector: String? {
        switch self {
        case .gmail: return ".g2"
        default: return nil
        }
    }

    public var hasRecipe: Bool { senderSelector != nil }

    /// Whether the tab URL names an OPEN MESSAGE rather than a list/label/
    /// search surface. Correspondent capture must only run on message views:
    /// Gmail keeps the last-open conversation's DOM cached when you return to
    /// a list, so the selectors report the PREVIOUS message's parties against
    /// the list surface (seen live 2026-07-09: `#inbox` carrying the
    /// correspondents of the message read a minute earlier) — and a list
    /// title makes a junk subject ("Inbox (1)"). Gmail message URLs end the
    /// fragment with a long alphanumeric thread id (`#inbox/FMfcgz…`,
    /// legacy 16-hex too); list/label/search/settings segments are short
    /// words. Systems with no known URL shape return true so a future recipe
    /// isn't silently gated before its classifier is written.
    public func isMessageView(urlString: String?) -> Bool {
        switch self {
        case .gmail:
            guard let s = urlString, let frag = URL(string: s)?.fragment else { return false }
            let path = frag.split(separator: "?").first.map(String.init) ?? frag
            guard let last = path.split(separator: "/").last else { return false }
            return last.count >= 16
                && last.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        default:
            return true
        }
    }
}
