import Foundation

/// One broad→narrow segment chain for any surface — the shared identity model
/// behind the Evidence Card's grain ladder, the pin editor's Components strip
/// and (later) site-recipe fields (2026-07-03 context-rules spec §5.1).
///
///   email:   Gmail ▸ harborlane.example ▸ r.naismith@… ▸ "Insurance Renewals"
///   plain:   github.com ▸ aqueum ▸ ambitick ▸ issues
///   app:     Ghostty ▸ ambitick ▸ Attributor.swift
///
/// Email segments follow the user's `emailMatchOrder` ladder, so reordering
/// the ladder in Settings reorders every card and strip app-wide. Segments are
/// never hidden: a field the capture didn't supply renders as an UNAVAILABLE
/// ghost row — its absence IS the coverage/privacy signal (spec §5.5).
public struct ContextIdentity: Sendable, Equatable {
    public enum SegmentKind: Sendable, Equatable {
        case app, urlHost, urlPath          // today's PinScope segments
        case emailSystem                    // "Gmail"
        case correspondentDomain            // "harborlane.example"
        case correspondent                  // "r.naismith@harborlane.example"
        case subject                        // normalised subject
        case recipeField(String)            // ◆ extracted; assoc = field name ("client")
    }

    public struct Segment: Sendable, Equatable {
        public var kind: SegmentKind
        /// The matchable value (lowercased/normalised where the matcher is).
        public var value: String
        /// Pretty form for UI ("Gmail", the raw subject).
        public var display: String
        /// gmail.com et al. — shared webmail, matches everyone; caution tint.
        public var shared: Bool
        /// false = "not captured" ghost row (no recipe / capture off).
        public var available: Bool

        public init(kind: SegmentKind, value: String, display: String,
                    shared: Bool = false, available: Bool = true) {
            self.kind = kind
            self.value = value
            self.display = display
            self.shared = shared
            self.available = available
        }
    }

    /// General → specific.
    public var segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    /// Build the chain for a signal.
    ///  • Email surface (a detected mail host, or a signal carrying email
    ///    context): the email ladder levels in `order`, missing fields as
    ///    ghost rows.
    ///  • Anything else: the PinScope identity — host + path segments for a
    ///    URL, app + window-title segments otherwise (title segments share
    ///    `.app`, the kind of the whole app-window identity).
    /// `recipeFields` is the extension point for site recipes (spec: spliced
    /// in after the root segment, marked ◆); recipes themselves come later.
    public static func from(_ signal: ActivitySignal,
                            order: [EmailMatchLevel] = EmailMatchLevel.defaultOrder,
                            recipeFields: [(name: String, value: String)] = []) -> ContextIdentity {
        let ctx = EmailContext.from(signal)
        let host = signal.tabURL.flatMap { URL(string: $0)?.host }
        let detected = EmailSystem.detect(urlHost: host)
        var segments: [Segment]
        if ctx != nil || detected != .unknown {
            segments = emailSegments(ctx: ctx, system: ctx?.system ?? detected, order: order)
        } else if let id = PinScope.identity(of: signal) {
            switch id.kind {
            case .url:
                segments = id.segments.enumerated().map { i, part in
                    Segment(kind: i == 0 ? .urlHost : .urlPath, value: part, display: part)
                }
            case .app:
                segments = id.segments.map { Segment(kind: .app, value: $0, display: $0) }
            }
        } else {
            segments = []
        }
        let recipes = recipeFields.map {
            Segment(kind: .recipeField($0.name), value: $0.value, display: $0.value)
        }
        if !recipes.isEmpty {
            segments.insert(contentsOf: recipes, at: segments.isEmpty ? 0 : 1)
        }
        return ContextIdentity(segments: segments)
    }

    private static func emailSegments(ctx: EmailContext?, system: EmailSystem,
                                      order: [EmailMatchLevel]) -> [Segment] {
        order.map { level in
            switch level {
            case .emailSystem:
                return Segment(kind: .emailSystem, value: system.rawValue,
                               display: system.label, available: system != .unknown)
            case .correspondentDomain:
                guard let domain = ctx?.correspondentDomains.first else {
                    return ghost(.correspondentDomain)
                }
                return Segment(kind: .correspondentDomain, value: domain, display: domain,
                               shared: Attributor.sharedWebmailDomains.contains(domain))
            case .correspondent:
                guard let cp = ctx?.correspondents.first else {
                    return ghost(.correspondent)
                }
                return Segment(kind: .correspondent, value: cp, display: cp)
            case .subject:
                guard let subj = Attributor.normalisedSubject(ctx?.subject), !subj.isEmpty else {
                    return ghost(.subject)
                }
                let raw = ctx?.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? subj
                return Segment(kind: .subject, value: subj, display: "\u{201C}\(raw)\u{201D}")
            }
        }
    }

    /// A "not captured" row: present (so its absence is visible) but unmatchable.
    private static func ghost(_ kind: SegmentKind) -> Segment {
        Segment(kind: kind, value: "", display: "not captured", available: false)
    }
}

extension Attributor {
    /// The identity chain for a signal, ordered per THIS attributor's
    /// user-configured email ladder — what the Evidence Card renders.
    public func identity(of signal: ActivitySignal) -> ContextIdentity {
        ContextIdentity.from(signal, order: emailMatchOrder)
    }
}
