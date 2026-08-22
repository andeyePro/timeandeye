import Foundation

/// One broad→narrow segment chain for any surface — the shared identity model
/// behind the Evidence Card's grain ladder, the pin editor's Components strip
/// and site-recipe fields (2026-07-03 context-rules spec §5.1; 2026-07-09
/// site-recipes spec §6).
///
///   email:   Gmail ▸ harborlane.example ▸ r.naismith@… ▸ "Insurance Renewals"
///   recipe:  github.com ▸ ◆example-org ▸ ◆example-repo ▸ ◆issues ▸ ◆"Pin editor loses focus"
///   plain:   forum.example.com ▸ andeyePro ▸ timeandeye ▸ issues
///   app:     Ghostty ▸ timeandeye ▸ Attributor.swift
///
/// Email segments follow the user's `emailMatchOrder` ladder, so reordering
/// the ladder in Settings reorders every card and strip app-wide. Segments are
/// never hidden: a field the capture didn't supply renders as an UNAVAILABLE
/// ghost row — its absence IS the coverage/privacy signal (spec §5.5).
package struct ContextIdentity: Sendable, Equatable {
    package enum SegmentKind: Sendable, Equatable {
        case app, urlHost, urlPath          // today's PinScope segments
        case emailSystem                    // "Gmail"
        case correspondentDomain            // "harborlane.example"
        case correspondent                  // "r.naismith@harborlane.example"
        case subject                        // normalised subject
        case recipeField(String)            // ◆ extracted; assoc = field name ("client")
    }

    package struct Segment: Sendable, Equatable {
        package var kind: SegmentKind
        /// The matchable value (lowercased/normalised where the matcher is).
        package var value: String
        /// Pretty form for UI ("Gmail", the raw subject).
        package var display: String
        /// gmail.com et al. — shared webmail, matches everyone; caution tint.
        package var shared: Bool
        /// false = "not captured" ghost row (no recipe / capture off).
        package var available: Bool

        package init(kind: SegmentKind, value: String, display: String,
                    shared: Bool = false, available: Bool = true) {
            self.kind = kind
            self.value = value
            self.display = display
            self.shared = shared
            self.available = available
        }
    }

    /// General → specific.
    package var segments: [Segment]

    package init(segments: [Segment]) {
        self.segments = segments
    }

    /// Build the chain for a signal.
    ///  • Email surface (a detected mail host, or a signal carrying email
    ///    context): the email ladder levels in `order`, missing fields as
    ///    ghost rows.
    ///  • A site-recipe page (2026-07-09 site-recipes spec §6): the host
    ///    root plus one ◆ `recipeField` segment per declared field (ghosts
    ///    for missing values, content last) — REPLACING the raw path
    ///    segments, not splicing alongside them: the fields ARE the path,
    ///    structured (a splice would render `github.com ▸ ◆example-org ▸ ◆example-repo
    ///    ▸ example-org ▸ example-repo`).
    ///  • Anything else: the PinScope identity — host + path segments for a
    ///    URL, app + window-title segments otherwise (title segments share
    ///    `.app`, the kind of the whole app-window identity).
    /// `recipeFields` remains the splice-after-root extension point for
    /// CALLER-SUPPLIED fields (Tier 1 DOM-sourced values, later) — Tier 0
    /// URL/title fields come from the internal recipe branch above.
    package static func from(_ signal: ActivitySignal,
                            order: [EmailMatchLevel] = EmailMatchLevel.defaultOrder,
                            recipeFields: [(name: String, value: String)] = [],
                            disabledRecipes: Set<String> = []) -> ContextIdentity {
        let ctx = EmailContext.from(signal)
        let host = signal.tabURL.flatMap { URL(string: $0)?.host }
        let detected = EmailSystem.detect(urlHost: host)
        var segments: [Segment]
        if ctx != nil || detected != .unknown {
            segments = emailSegments(ctx: ctx, system: ctx?.system ?? detected, order: order)
        } else if let site = SiteRecipes.extract(signal, disabled: disabledRecipes),
                  let recipe = site.recipe {
            segments = [Segment(kind: .urlHost, value: site.host, display: site.host)]
            for field in recipe.fields {
                guard let value = site.values[field.name] else {
                    segments.append(ghost(.recipeField(field.name)))
                    continue
                }
                // Identity display can come from a sibling field (Docs shows
                // the human title while the rule keys on the stable doc id);
                // content displays quote, like the subject row.
                let display = field.displayVia.flatMap { site.values[$0] } ?? value
                segments.append(Segment(
                    kind: .recipeField(field.name), value: value,
                    display: field.isContent ? "\u{201C}\(display)\u{201D}" : display))
            }
        } else if let id = PinScope.identity(of: signal) {
            switch id.kind {
            case .url:
                segments = id.segments.enumerated().map { i, part in
                    Segment(kind: i == 0 ? .urlHost : .urlPath, value: part, display: part)
                }
                // The prime's finer key (?v=…, #/route — B7) is NOT a grain
                // row: this ladder is the Evidence Card's rule/pin selector
                // and every row must map onto `PinScope.identity`, which
                // stops at host+path. An extra row here made
                // `defaultGrainCount` select a grain "Always" cannot express
                // (it pinned the whole host instead) and "Remember" ignored
                // outright. The fine key is reported honestly by the card's
                // matched-surface provenance line, which `explain()` already
                // fills with the key that fired.
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

    /// The pin editor's default grain when it opens: the most specific
    /// AVAILABLE segment (spec §5.5 — a ghost is never the default, since it
    /// can't be committed). 1-based, matching the Components strip's blue
    /// prefix length; 0 only if every segment is a ghost.
    package var defaultGrainCount: Int {
        segments.lastIndex(where: \.available).map { $0 + 1 } ?? 0
    }

    /// The pin editor's ← / → step over this chain, skipping ghost segments —
    /// they render (spec §5.5: never hidden) but are never selectable.
    /// `count` is the current 1-based grain (as `defaultGrainCount`/the strip's
    /// blue prefix length); `narrower` is true for → / false for ←. Staying put
    /// (returning `count`) when there is no available segment in that
    /// direction is the correct "can't go further" behaviour, not a bug.
    package func steppedGrainCount(from count: Int, narrower: Bool) -> Int {
        guard !segments.isEmpty else { return count }
        let current = max(0, min(count, segments.count) - 1)
        let candidates = narrower
            ? Array((current + 1)..<segments.count)
            : Array((0..<current).reversed())
        let next = candidates.first { segments[$0].available } ?? current
        return next + 1
    }

    /// The Evidence Card's default grain selection (2026-07-03 spec §5.2) —
    /// deliberately NOT `defaultGrainCount` (the pin editor's most-specific-
    /// available convention). This mirrors `learnEmailRule`'s own
    /// conservatism: an org domain generalises to the company, a shared-
    /// webmail correspondent stays per-person, and with no correspondent
    /// captured at all the default falls back to the narrowest AVAILABLE row
    /// (subject, or failing that the system) — spec §5.5's edge cases. nil
    /// when the chain carries no email grain at all (a plain surface), where
    /// the card degrades to the PinScope chain and `defaultGrainCount` applies
    /// instead.
    package var cardDefaultGrainIndex: Int? {
        guard segments.contains(where: { $0.kind.isEmailGrain }) else { return nil }
        if let i = segments.firstIndex(where: { $0.kind == .correspondentDomain && $0.available && !$0.shared }) {
            return i + 1
        }
        if let i = segments.firstIndex(where: { $0.kind == .correspondent && $0.available }) {
            return i + 1
        }
        if let i = segments.firstIndex(where: { $0.kind == .subject && $0.available }) {
            return i + 1
        }
        if let i = segments.firstIndex(where: { $0.kind == .emailSystem && $0.available }) {
            return i + 1
        }
        return nil
    }

    /// The recipe chain's default grain (site-recipes spec §6): the segment
    /// for the matched recipe's DECLARED default field (repo, document,
    /// organisation — email-style conservatism, never the content field),
    /// falling back to the host row when that field wasn't captured. nil for
    /// every non-recipe chain (email, plain URL, app window).
    package var siteDefaultGrainIndex: Int? {
        guard segments.first?.kind == .urlHost,
              segments.contains(where: { if case .recipeField = $0.kind { return true }
                                          return false }),
              let recipe = SiteRecipes.recipe(forHost: segments[0].value) else { return nil }
        if let i = segments.firstIndex(where: {
            $0.kind == .recipeField(recipe.defaultField) && $0.available
        }) {
            return i + 1
        }
        return 1   // default field not captured — the host row still commits
    }

    /// The post-pick/post-assign footers' one-line offer grain: email's
    /// conservative default when the chain carries email grains, the
    /// recipe's declared default on a recipe chain, else the HOST row on any
    /// plain URL chain (site-recipes spec §0 Q2 — "this site → task" is
    /// learnable everywhere). nil on app windows, where no site rule
    /// applies and the footer stays away.
    package var footerDefaultGrainIndex: Int? {
        if let i = cardDefaultGrainIndex { return i }
        if let i = siteDefaultGrainIndex { return i }
        return segments.first?.kind == .urlHost ? 1 : nil
    }

    /// The host-only chain a disagreeing review batch degrades to (site-
    /// recipes spec §6): when selected rows share a (non-mail) host but
    /// nothing finer, the shared `site` grain is still worth offering. nil
    /// for mail hosts (email keeps its own footer path) and URL-less
    /// signals.
    package static func siteHostChain(of signal: ActivitySignal) -> ContextIdentity? {
        guard let context = SiteRecipes.context(for: signal) else { return nil }
        return ContextIdentity(segments: [
            Segment(kind: .urlHost, value: context.host, display: context.host),
        ])
    }
}

/// Multi-correspondent expansion (2026-07-03 spec §5.5, "later polish"): a
/// message with more than one counterparty must let the user choose WHICH
/// addresses the correspondent-grain rule keys on, rather than silently
/// committing to the first (all `emailSegments` above tracks). Pure — the
/// Attributor write itself is the caller's job
/// (`AppController.commitCorrespondentGrain`).
extension ContextIdentity {
    /// Every distinct correspondent on `signal`, first-seen order,
    /// case-insensitively de-duplicated — the checkbox list source for the
    /// grain footer / Evidence Card. Empty for a signal with no email
    /// context at all.
    package static func correspondentChoices(_ signal: ActivitySignal) -> [String] {
        guard let ctx = EmailContext.from(signal) else { return [] }
        var seen = Set<String>()
        return ctx.correspondents.filter { seen.insert($0).inserted }
    }

    /// The addresses a correspondent-grain commit should write one rule
    /// each for: `chosen` filtered against, and ordered by,
    /// `correspondentChoices` — so the commit order is stable and `chosen`
    /// is matched case-insensitively (a checkbox label is the lowercased
    /// display value, but a caller shouldn't have to know that).
    package static func correspondentRuleValues(_ signal: ActivitySignal,
                                               chosen: Set<String>) -> [String] {
        let chosenLower = Set(chosen.map { $0.lowercased() })
        return correspondentChoices(signal).filter { chosenLower.contains($0.lowercased()) }
    }
}

extension ContextIdentity.SegmentKind {
    /// True for the four email-ladder levels (system/domain/correspondent/
    /// subject) — distinguishes an email-flavoured chain from the plain
    /// PinScope one (app/urlHost/urlPath) and the later recipe extension
    /// point. Drives the pin editor's choice between the classic Components
    /// strip and the email grain ladder (pin-editor slice, 2026-07-03 spec).
    package var isEmailGrain: Bool {
        switch self {
        case .emailSystem, .correspondentDomain, .correspondent, .subject: return true
        case .app, .urlHost, .urlPath, .recipeField: return false
        }
    }

    /// The `EmailMatchLevel` this segment kind commits as (the Evidence
    /// Card's Remember/Always — 2026-07-03 spec §5.2/§5.4), or nil for a
    /// PinScope/recipe kind that stays on the Pin path. Unlike `pinPredicate`
    /// below (the pin editor's Components strip, which keeps the system/site
    /// grain on the PinScope path for its "Always" pin), the card's Always
    /// writes a PINNED `EmailRule` for every email-flavoured grain INCLUDING
    /// the system row — spec §5.4: "Always writes a PINNED EmailRule for
    /// email grains, or a Pin for the site-section grain on a non-email
    /// surface."
    package var emailMatchLevel: EmailMatchLevel? {
        switch self {
        case .emailSystem: return .emailSystem
        case .correspondentDomain: return .correspondentDomain
        case .correspondent: return .correspondent
        case .subject: return .subject
        case .app, .urlHost, .urlPath, .recipeField: return nil
        }
    }
}

extension ContextIdentity.Segment {
    /// The Expression predicate this grain commits as, for the pin editor's
    /// email ladder (pin-editor slice of the 2026-07-03 context-rules spec,
    /// §5.1/§5.4): "correspondent/domain/subject grains become `.expression`
    /// predicate leaves … narrow-app/site grains keep the existing
    /// `.components(PinScope)` path". Returns nil for a ghost (never
    /// committable) and for every kind that stays on the PinScope path —
    /// `emailSystem` included, since "this whole site" is exactly what a
    /// PinScope root pin already means.
    package var pinPredicate: Predicate? {
        guard available else { return nil }
        switch kind {
        case .correspondentDomain: return .leaf(field: .sender, op: .contains, value: value)
        case .correspondent:       return .leaf(field: .sender, op: .equals, value: value)
        case .subject:             return .leaf(field: .subject, op: .contains, value: value)
        case .emailSystem, .app, .urlHost, .urlPath, .recipeField: return nil
        }
    }

    /// The value an `EmailRule` at `kind.emailMatchLevel` should store: the
    /// segment's own value, INCLUDING the system row — the card says
    /// "everything in Gmail", so the committed rule must scope to Gmail (an
    /// empty value would match every mail system, disagreeing with the label
    /// the user clicked; `EmailRule.matches` treats a named system exactly).
    package var emailMatchValue: String { value }
}

extension Attributor {
    /// The identity chain for a signal, ordered per THIS attributor's
    /// user-configured email ladder and honouring its per-recipe toggles —
    /// what the Evidence Card renders.
    package func identity(of signal: ActivitySignal) -> ContextIdentity {
        ContextIdentity.from(signal, order: emailMatchOrder,
                             disabledRecipes: disabledSiteRecipes)
    }
}
