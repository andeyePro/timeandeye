import Foundation

/// The user-editable specificity ladder for email→task matching. Several rules
/// can match one message (its system, the correspondent's domain, the
/// correspondent, words in the subject); the MOST SPECIFIC matching rule wins.
/// The order is a setting so the user can retune it; `defaultOrder` is general →
/// specific.
///
/// "Correspondent" is the OTHER party, in either direction: the sender of an
/// inbound message, or the recipient(s) of one you sent. So a rule learned from a
/// mail you received from a company also fires on a mail you send to it.
public enum EmailMatchLevel: String, CaseIterable, Codable, Sendable {
    case emailSystem          // "all mail in this system" — the broad catch-all
    case correspondentDomain  // e.g. harborlane.example
    case correspondent        // e.g. r.naismith@harborlane.example
    case subject              // e.g. contains "Insurance Renewals" — most specific

    /// Low (general) → high (specific). The last element wins ties of presence.
    public static let defaultOrder: [EmailMatchLevel] =
        [.emailSystem, .correspondentDomain, .correspondent, .subject]

    public var label: String {
        switch self {
        case .emailSystem: return "Email system"
        case .correspondentDomain: return "Correspondent domain"
        case .correspondent: return "Correspondent"
        case .subject: return "Subject"
        }
    }
}

/// What we know about the focused email, normalised for matching. The
/// correspondents are the external parties (sender+recipients minus yourself) —
/// see `EmailSignal.counterparties`. Addresses are stored lowercased.
public struct EmailContext: Equatable, Sendable {
    public let system: EmailSystem
    public let correspondents: [String]
    public let subject: String?

    public init(system: EmailSystem, correspondents: [String], subject: String?) {
        self.system = system
        self.correspondents = correspondents.map { $0.lowercased() }
        self.subject = subject
    }

    public var correspondentDomains: [String] {
        var seen = Set<String>(); var out: [String] = []
        for c in correspondents {
            if let d = EmailSignal.domain(of: c), seen.insert(d).inserted { out.append(d) }
        }
        return out
    }

    /// Build a context from a focus signal, or nil if it carries no email info
    /// (the common case — only email surfaces have correspondents/subject). The
    /// system is detected from the tab URL host.
    public static func from(_ signal: ActivitySignal) -> EmailContext? {
        let correspondents = signal.correspondents ?? []
        guard !correspondents.isEmpty || (signal.emailSubject?.isEmpty == false) else { return nil }
        let host = signal.tabURL.flatMap { URL(string: $0)?.host }
        return EmailContext(system: EmailSystem.detect(urlHost: host),
                            correspondents: correspondents, subject: signal.emailSubject)
    }
}

/// One email→task rule, learned (from a correction) or pinned (explicit). `value`
/// is empty for `emailSystem` ("any mail in the system").
public struct EmailRule: Equatable, Codable, Sendable {
    public let level: EmailMatchLevel
    public let value: String
    public let target: TaskRef
    /// True for explicit user pins (which outrank a learned rule at the same level).
    public let pinned: Bool

    public init(level: EmailMatchLevel, value: String, target: TaskRef, pinned: Bool = false) {
        self.level = level
        self.value = value
        self.target = target
        self.pinned = pinned
    }

    public func matches(_ context: EmailContext) -> Bool {
        let v = value.lowercased()
        switch level {
        case .emailSystem:
            // Empty value = any system; else the named system must match.
            return value.isEmpty || v == context.system.rawValue.lowercased()
        case .correspondentDomain:
            return context.correspondentDomains.contains(v)
        case .correspondent:
            return context.correspondents.contains(v)
        case .subject:
            guard let subj = context.subject, !value.isEmpty else { return false }
            return subj.range(of: value, options: .caseInsensitive) != nil
        }
    }
}

public enum EmailMatcher {
    /// The winning rule for `context`: the most-specific level (per `order`,
    /// general → specific) that has a matching rule. At one level a pinned rule
    /// beats a learned one; otherwise the first match wins.
    public static func match(_ context: EmailContext, rules: [EmailRule],
                             order: [EmailMatchLevel] = EmailMatchLevel.defaultOrder)
        -> EmailRule? {
        for level in order.reversed() {
            let here = rules.filter { $0.level == level && $0.matches(context) }
            if here.isEmpty { continue }
            return here.first { $0.pinned } ?? here.first
        }
        return nil
    }
}
