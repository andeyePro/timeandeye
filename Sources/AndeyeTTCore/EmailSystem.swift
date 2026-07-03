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
        if h.hasSuffix("fastmail.com") { return .fastmail }
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
}
