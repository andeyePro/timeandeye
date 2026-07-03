import Foundation

/// The fields we can actually observe about a window. NOTE: there is no
/// window-content field — we see the app name, the titlebar text, and (browsers
/// only) the active tab URL, nothing inside the page. A `content` case will be
/// added if/when opt-in "look inside" apps land (see TODO).
public enum PinField: String, Codable, Sendable, CaseIterable {
    case app, title, url, sender, subject, any

    /// The string(s) this field exposes on a signal. Most fields are
    /// single-valued; `sender` (the email correspondents) is a list, and `any`
    /// spans every observable string — app, title, url, subject and every
    /// correspondent. A leaf matches when ANY of these values matches. A nil
    /// `correspondents` yields `[]` (no match, no crash); a nil `emailSubject`
    /// yields `[""]`, which never matches a non-empty query.
    public func values(of signal: ActivitySignal) -> [String] {
        switch self {
        case .app:     return [signal.app]
        case .title:   return [signal.windowTitle ?? ""]
        case .url:     return [signal.tabURL ?? ""]
        case .sender:  return signal.correspondents ?? []
        case .subject: return [signal.emailSubject ?? ""]
        case .any:
            return [signal.app, signal.windowTitle ?? "", signal.tabURL ?? "",
                    signal.emailSubject ?? ""] + (signal.correspondents ?? [])
        }
    }

    /// A single representative value (the first), retained for callers/tests
    /// that want one string. Multi-valued matching goes through `values(of:)`.
    public func value(of signal: ActivitySignal) -> String {
        values(of: signal).first ?? ""
    }
}

public enum PinOp: String, Codable, Sendable, CaseIterable {
    case equals, contains, startsWith, regex

    public func test(_ field: String, _ value: String) -> Bool {
        switch self {
        case .equals:     return field.caseInsensitiveCompare(value) == .orderedSame
        case .contains:   return field.range(of: value, options: .caseInsensitive) != nil
        case .startsWith:
            // Case-insensitive, to match `equals`/`contains` above — the typed
            // expression editor offers "starts with" as their peer, so a
            // case-sensitive odd-one-out is a surprise. Empty prefix matches all
            // (as hasPrefix did).
            return value.isEmpty
                || field.range(of: value, options: [.caseInsensitive, .anchored]) != nil
        case .regex:
            // UNANCHORED — a contains-pattern (firstMatch anywhere). Use ^…$ in
            // the pattern for a whole-string match. Compiled per call, but
            // .focus events fire at human focus-change cadence, so no cache.
            guard let re = try? NSRegularExpression(pattern: value) else { return false }
            return re.firstMatch(in: field, range: NSRange(field.startIndex..., in: field)) != nil
        }
    }
}

/// A boolean predicate over the observable fields. `contains` and `regex` are
/// just operators here — there is no separate "contains rule" or "regex rule".
/// This is what the Boolean editor and the AI mode both produce.
public indirect enum Predicate: Codable, Equatable, Sendable {
    case leaf(field: PinField, op: PinOp, value: String)
    case and([Predicate])
    case or([Predicate])
    case not(Predicate)

    public func evaluate(_ signal: ActivitySignal) -> Bool {
        switch self {
        case .leaf(let f, let op, let v): return f.values(of: signal).contains { op.test($0, v) }
        case .and(let ps): return ps.allSatisfy { $0.evaluate(signal) }
        case .or(let ps):  return ps.contains { $0.evaluate(signal) }
        case .not(let p):  return !p.evaluate(signal)
        }
    }

    /// Specificity proxy: how many leaf conditions constrain the match. More
    /// conditions = more specific = wins ties against looser rules.
    public var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .and(let ps), .or(let ps): return ps.reduce(0) { $0 + $1.leafCount }
        case .not(let p): return p.leafCount
        }
    }
}

/// One pin: a rule, the task it forces, and (optional, Advanced) a manual
/// priority that overrides specificity-based precedence.
public struct Pin: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var rule: PinRule
    public var task: TaskRef
    public var priority: Int?

    public init(id: UUID = UUID(), rule: PinRule, task: TaskRef, priority: Int? = nil) {
        self.id = id
        self.rule = rule
        self.task = task
        self.priority = priority
    }

    public func matches(_ signal: ActivitySignal) -> Bool { rule.matches(signal) }
}

/// A pin rule is either the friendly component-prefix form (the blue/grey
/// editor) or a general boolean expression. Both reduce to a match test.
public enum PinRule: Codable, Equatable, Sendable {
    case components(PinScope)
    case expression(Predicate)

    public func matches(_ signal: ActivitySignal) -> Bool {
        switch self {
        case .components(let s): return s.matches(signal)
        case .expression(let p): return p.evaluate(signal)
        }
    }

    /// Higher = more specific; used to pick a winner when several pins match.
    /// Only comparable WITHIN a kind — `prefix.count` and `leafCount` are not
    /// commensurable (see `sameKind(as:)`).
    public var specificity: Int {
        switch self {
        case .components(let s): return s.prefix.count
        case .expression(let p): return p.leafCount
        }
    }

    /// Same rule kind, so the two specificities mean the same thing. A 2-leaf
    /// expression isn't "more specific" than a 3-segment component pin, so the
    /// tiebreak only applies the specificity comparison within a kind.
    public func sameKind(as other: PinRule) -> Bool {
        switch (self, other) {
        case (.components, .components), (.expression, .expression): return true
        default: return false
        }
    }

    /// Short human label for the badge (the most specific identifying bit).
    public var shortLabel: String {
        switch self {
        case .components(let s): return s.prefix.last ?? ""
        case .expression(let p): return p.shortLabel
        }
    }
}

extension Predicate {
    /// A compact one-liner for the badge, e.g. `title∋andeye` or `…`. For a
    /// compound rule, show the MOST DISTINCTIVE leaf (longest value) rather than
    /// just the first clause — that's the bit that actually identifies what's
    /// pinned, which is what the badge is for.
    var shortLabel: String {
        switch self {
        case .leaf(let f, let op, let v):
            let sym = op == .contains ? "∋" : op == .regex ? "~" : op == .equals ? "=" : "^"
            return "\(f.rawValue)\(sym)\(v)"
        case .and(let ps), .or(let ps):
            return (ps.max { $0.labelWeight < $1.labelWeight })?.shortLabel ?? "…"
        case .not(let p):  return "¬" + p.shortLabel
        }
    }

    /// How distinctive a sub-tree's strongest leaf is — the length of its
    /// longest matched value. Drives `shortLabel`'s "most specific clause" pick.
    private var labelWeight: Int {
        switch self {
        case .leaf(_, _, let v): return v.count
        case .and(let ps), .or(let ps): return ps.map(\.labelWeight).max() ?? 0
        case .not(let p): return p.labelWeight
        }
    }
}
