import Foundation

/// Email-signal helpers. The reusable kernel for the sender-as-a-signal work:
/// pull candidate email addresses out of arbitrary text (e.g. the strings an AX
/// walk of a webmail window yields). Pure, so it's unit-checkable; the platform
/// AX traversal that feeds it lives in andeyeTTMac.
public enum EmailSignal {
    /// A named address from a message header (sender or recipient).
    public struct Party: Equatable, Sendable {
        public let name: String
        public let email: String
        public init(name: String, email: String) {
            self.name = name
            self.email = email
        }
    }

    /// The external correspondents on a message: sender + recipient parties with
    /// YOURSELF removed. Gmail names your own address "me", so that's dropped;
    /// also drops anything in `ownAddresses` / `ownDomains`. First-seen order,
    /// de-duplicated by address. This is the strong "which task" signal — the
    /// other party (and especially their domain) usually identifies the work.
    public static func counterparties(senders: [Party], recipients: [Party],
                                      ownAddresses: Set<String> = [],
                                      ownDomains: Set<String> = []) -> [Party] {
        let own = Set(ownAddresses.map { $0.lowercased() })
        let ownD = Set(ownDomains.map { $0.lowercased() })
        var seen = Set<String>()
        var out: [Party] = []
        for p in senders + recipients {
            let email = p.email.lowercased()
            if email.isEmpty { continue }
            if p.name.trimmingCharacters(in: .whitespaces).lowercased() == "me" { continue }
            if own.contains(email) { continue }
            if let d = domain(of: email), ownD.contains(d) { continue }
            if seen.insert(email).inserted { out.append(p) }
        }
        return out
    }

    /// Best-effort subject from a webmail browser/tab title, which is typically
    /// "<subject> - <account> - <Provider> Mail" — take the part before " - ".
    public static func subject(fromTitle title: String?) -> String? {
        guard let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let r = t.range(of: " - ") { return String(t[..<r.lowerBound]) }
        return t
    }

    /// Parse the settings' raw own-email text ("martin@example.com, andeye.com")
    /// into the address/domain sets `counterparties` filters on: entries with
    /// an "@" are addresses, the rest are domains; lowercased, trimmed,
    /// empties dropped. Forgiving on separators (commas, whitespace,
    /// newlines) — it's a hand-typed field.
    public static func ownEntrySets(_ raw: String)
        -> (addresses: Set<String>, domains: Set<String>) {
        var addresses = Set<String>()
        var domains = Set<String>()
        for piece in raw.lowercased().split(whereSeparator: { ", \t\n;".contains($0) }) {
            let entry = String(piece)
            if entry.contains("@") { addresses.insert(entry) } else { domains.insert(entry) }
        }
        return (addresses, domains)
    }

    /// The domain part of an email address, lowercased (nil if malformed).
    public static func domain(of email: String) -> String? {
        guard let at = email.firstIndex(of: "@") else { return nil }
        let d = email[email.index(after: at)...]
        return d.isEmpty ? nil : String(d).lowercased()
    }

    /// Every distinct email address in `text`, in first-seen order
    /// (case-insensitively de-duplicated).
    public static func addresses(in text: String) -> [String] {
        let pattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            if seen.insert(s.lowercased()).inserted { out.append(s) }
        }
        return out
    }
}
