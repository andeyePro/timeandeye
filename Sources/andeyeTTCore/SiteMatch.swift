import Foundation

/// One site→task rule, learned (from a grain commit) or pinned (explicit) —
/// the third rule domain, mirroring `EmailRule`/`CalendarRule` deliberately
/// (2026-07-09 site-recipes spec §5, reaffirming the calendar spec's
/// "parallel type over premature abstraction": email levels are a closed
/// enum, site levels are open per-recipe field names, so a shared generic
/// would have to erase exactly the part that differs; the protocol refactor
/// is now justified with three verses in — a dedicated later pass, not this
/// feature).
public struct SiteRule: Equatable, Codable, Sendable {
    /// The reserved recipe-less level: the rule keys on the URL host itself
    /// — the ambiguous-web-page policy note's "one correction generalises
    /// the whole host", learnable on every non-mail page.
    public static let siteField = "site"

    /// The recipe whose field this rule keys on; nil for the `site`
    /// (host-level) rule, which needs no recipe.
    public let recipeID: String?
    /// `Self.siteField`, or a recipe field name ("repo", "organisation").
    public let field: String
    /// Lowercased. Identity fields match by equality; content fields by
    /// case-insensitive substring (the rule value is the substring).
    public let value: String
    public let target: TaskRef
    /// True for explicit user pins (which outrank a learned rule at the same
    /// level). Still capped at the 0.95 inferred ceiling in attribution —
    /// distinct from a PinScope host pin (1.0, standing law), which remains
    /// the "Always" form for the host row.
    public let pinned: Bool
    /// Provenance metadata, verbatim `EmailRule`'s block: decodes with
    /// defaults so a future field addition can't brick siterules.json.
    public var createdAt: Date
    public var origin: EmailRule.Origin
    /// Bumped by the Attributor each time this rule WINS an attribution.
    public var fireCount: Int
    public var lastFired: Date?

    public init(recipeID: String?, field: String, value: String, target: TaskRef,
                pinned: Bool = false, createdAt: Date = Date(),
                origin: EmailRule.Origin = .correction,
                fireCount: Int = 0, lastFired: Date? = nil) {
        self.recipeID = recipeID
        self.field = field
        self.value = value
        self.target = target
        self.pinned = pinned
        self.createdAt = createdAt
        self.origin = origin
        self.fireCount = fireCount
        self.lastFired = lastFired
    }

    /// Custom decode ONLY for the metadata defaults; encoding stays
    /// synthesized (always writes the full form) — `EmailRule`'s pattern.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipeID = try c.decodeIfPresent(String.self, forKey: .recipeID)
        field = try c.decode(String.self, forKey: .field)
        value = try c.decode(String.self, forKey: .value)
        target = try c.decode(TaskRef.self, forKey: .target)
        pinned = try c.decode(Bool.self, forKey: .pinned)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        origin = try c.decodeIfPresent(EmailRule.Origin.self, forKey: .origin) ?? .migrated
        fireCount = try c.decodeIfPresent(Int.self, forKey: .fireCount) ?? 0
        lastFired = try c.decodeIfPresent(Date.self, forKey: .lastFired)
    }

    /// The identity of a rule for replace/forget purposes: what it matches
    /// and where it points, NOT its metadata (a fireCount bump must not make
    /// a rule "different" from the snapshot a card captured).
    public func sameRule(as other: SiteRule) -> Bool {
        recipeID == other.recipeID && field == other.field
            && target == other.target && pinned == other.pinned
            && value.caseInsensitiveCompare(other.value) == .orderedSame
    }

    public func matches(_ context: SiteContext) -> Bool {
        guard !value.isEmpty else { return false }
        if field == Self.siteField {
            return value.caseInsensitiveCompare(context.host) == .orderedSame
        }
        // A recipe-field rule needs ITS recipe matched on this page — a
        // "repo" value can't accidentally fire on a Xero "section".
        guard let recipe = context.recipe, recipe.id == recipeID,
              let fieldDef = recipe.fields.first(where: { $0.name == field }),
              let extracted = context.values[field] else { return false }
        if fieldDef.isContent {
            return extracted.range(of: value, options: .caseInsensitive) != nil
        }
        return extracted.caseInsensitiveCompare(value) == .orderedSame
    }

    /// The rule's grain caption for the ledger/notices — "GitHub repository"
    /// / "Site". Falls back to the raw field name for a rule whose recipe is
    /// no longer shipped (the rule is kept, never silently dropped).
    public var grainLabel: String {
        if field == Self.siteField { return "Site" }
        guard let recipe = SiteRecipes.builtIn.first(where: { $0.id == recipeID }),
              let fieldDef = recipe.fields.first(where: { $0.name == field }) else {
            return field
        }
        return "\(recipe.label) \(fieldDef.label.lowercased())"
    }
}

public enum SiteMatcher {
    /// The winning rule for `context`: the most specific level with any
    /// match wins, over the ladder `["site"] + the matched recipe's declared
    /// field order` (general → specific). At one level a pinned rule beats a
    /// learned one; otherwise the newest unpinned wins ties —
    /// `EmailMatcher.match()`'s semantics verbatim (spec §5).
    public static func match(_ context: SiteContext, rules: [SiteRule]) -> SiteRule? {
        for level in context.ladder.reversed() {
            let here = rules.filter { $0.field == level && $0.matches(context) }
            if here.isEmpty { continue }
            return here.first { $0.pinned } ?? here.last   // newest unpinned wins ties
        }
        return nil
    }
}
