import Foundation

/// Email-signal helpers. The reusable kernel for the sender-as-a-signal work:
/// pull candidate email addresses out of arbitrary text (e.g. the strings an AX
/// walk of a webmail window yields). Pure, so it's unit-checkable; the platform
/// AX traversal that feeds it lives in timeandeyeMac.
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

    /// Pragmatic unicode-aware address shape (not full RFC 5321/6531): the
    /// local part and domain labels accept any letter or digit (`\p{L}\p{N}`),
    /// so EAI addresses (`杨@example.com`) and IDN domains (`user@bücher.de`)
    /// pass, and the final label must start with a letter and run ≥2 chars —
    /// which also admits punycode TLDs (`xn--p1ai`). The capture JS mirrors
    /// this shape (see `EmailCaptureEngine.jsScript`'s embedding-constrained
    /// spelling).
    private static let addressPattern =
        #"[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}.\-]+\.[\p{L}][\p{L}\p{N}\-]+"#
    /// Compiled ONCE: `isAddress`/`addresses(in:)` sit on the capture hot
    /// path (every party of every read), and NSRegularExpression compilation
    /// is the expensive half. The pattern is a literal, so force-try cannot
    /// actually throw (the checks suite exercises both immediately).
    // swiftlint:disable force_try
    private static let addressRegex = try! NSRegularExpression(pattern: addressPattern)
    private static let exactAddressRegex =
        try! NSRegularExpression(pattern: "^(?:\(addressPattern))$")
    // swiftlint:enable force_try

    /// Whether `s` is exactly one well-formed address and nothing else — the
    /// shape test validate-on-use applies to each captured party (a redesigned
    /// selector often yields opaque tokens or display names where addresses
    /// used to be).
    public static func isAddress(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: (s as NSString).length)
        return exactAddressRegex.firstMatch(in: s, range: range) != nil
    }

    /// Every distinct email address in `text`, in first-seen order
    /// (case-insensitively de-duplicated).
    public static func addresses(in text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in addressRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            if seen.insert(s.lowercased()).inserted { out.append(s) }
        }
        return out
    }
}
