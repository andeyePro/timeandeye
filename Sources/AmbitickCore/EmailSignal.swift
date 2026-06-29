import Foundation

/// Email-signal helpers. The reusable kernel for the sender-as-a-signal work:
/// pull candidate email addresses out of arbitrary text (e.g. the strings an AX
/// walk of a webmail window yields). Pure, so it's unit-checkable; the platform
/// AX traversal that feeds it lives in AmbitickMac.
public enum EmailSignal {
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
