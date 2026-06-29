import Foundation

/// The user-editable specificity ladder for email→task matching. Several rules
/// can match one message (its system, the sender's domain, the sender, words in
/// the subject); the MOST SPECIFIC matching rule wins. The order is a setting so
/// the user can retune it; `defaultOrder` is general → specific.
public enum EmailMatchLevel: String, CaseIterable, Codable, Sendable {
    case emailSystem    // "all mail in this system" — the broad catch-all
    case senderDomain   // e.g. harborlane.example
    case sender         // e.g. r.naismith@harborlane.example
    case subject        // e.g. contains "Insurance Renewals" — most specific

    /// Low (general) → high (specific). The last element wins ties of presence.
    public static let defaultOrder: [EmailMatchLevel] =
        [.emailSystem, .senderDomain, .sender, .subject]

    public var label: String {
        switch self {
        case .emailSystem: return "Email system"
        case .senderDomain: return "Sender domain"
        case .sender: return "Sender"
        case .subject: return "Subject"
        }
    }
}

/// What we know about the focused email, normalised for matching. Built from the
/// recipe read (sender/recipients) + the title/subject + the detected system.
public struct EmailContext: Equatable, Sendable {
    public let system: EmailSystem
    public let sender: String?        // primary external sender address
    public let senderDomain: String?
    public let subject: String?

    public init(system: EmailSystem, sender: String?, senderDomain: String?, subject: String?) {
        self.system = system
        self.sender = sender
        self.senderDomain = senderDomain
        self.subject = subject
    }

    public func value(for level: EmailMatchLevel) -> String? {
        switch level {
        case .emailSystem: return system == .unknown ? nil : system.rawValue
        case .senderDomain: return senderDomain
        case .sender: return sender
        case .subject: return subject
        }
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
        switch level {
        case .emailSystem:
            // Empty value = any system; else the named system must match.
            return value.isEmpty || value.caseInsensitiveCompare(context.system.rawValue) == .orderedSame
        case .senderDomain:
            guard let d = context.senderDomain else { return false }
            return value.caseInsensitiveCompare(d) == .orderedSame
        case .sender:
            guard let s = context.sender else { return false }
            return value.caseInsensitiveCompare(s) == .orderedSame
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
