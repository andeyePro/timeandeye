import Foundation

/// A site recipe: pluggable page understanding beyond Gmail (2026-07-09
/// site-recipes spec §3). A recipe structures what the sensors ALREADY see —
/// every field is parsed from the app/title/URL triple — it never sees more.
/// Tier 0 (all of v1) reads URL + window title only: free, synchronous, and
/// never stale. Tier 1 (later; Gmail is the only live example, deliberately
/// NOT migrated in v1) adds DOM extractors via the browser JS channel.
///
/// A value, not a protocol, and Codable throughout, so a bundled JSON pack
/// can later ship recipes without a redesign (spec §8). v1 ships built-ins
/// only (`SiteRecipes.builtIn`).
///
/// COMPLIANCE RULE for all recipe authorship, now and later (spec §8): a
/// recipe's sources may read ONLY the sensor-observed page — URL, window
/// title, and (Tier 1) the visible DOM. No recipe may ever incorporate
/// backend-API text (task subjects, contact names, project titles fetched
/// over HTTP) — that is the LearningStore compliance invariant (Xero T&Cs)
/// extended to the recipe layer, and it is what keeps recipe fields legal as
/// learned features even on go.xero.com pages.
///
/// Recipes vs backend recognizers (spec §7, the line drawn once): a
/// recognizer answers "which TASK is this page?" (deterministic, above
/// rules); a recipe answers "what FIELDS does this page show?" (evidence,
/// feeding rules and the learner). A recipe never parses task ids — the day
/// a site's pages name backend tasks, that parsing belongs in that backend's
/// recognizer. No "OP recipe" exists, ever.
public struct SiteRecipe: Codable, Equatable, Sendable {
    /// Stable id ("github") — keys rules, toggles and the ledger strip.
    public let id: String
    /// Display name ("GitHub") — Evidence Card / ledger.
    public let label: String
    /// Anchored host match: equal, or suffix at a dot boundary (the C20
    /// fastmail lesson — "github.com" must not match "notgithub.com").
    public let hosts: [String]
    /// 0 = URL/title only (all of v1). 1 = adds DOM extractors (later).
    public let tier: Int
    /// When extraction may run at all — the generalised `isMessageView`.
    /// Tier 0: a page-kind classifier (is the interesting entity open?).
    /// Tier 1 will ALSO make it the cached-DOM staleness gate.
    public let viewGate: URLShape
    /// General → specific — the ordered field list IS the grain ladder.
    public let fields: [Field]
    /// The field the post-pick grain footer defaults to (spec §6: "each
    /// recipe declares its default" — repo, document, organisation).
    public let defaultField: String

    public init(id: String, label: String, hosts: [String], tier: Int,
                viewGate: URLShape, fields: [Field], defaultField: String) {
        self.id = id
        self.label = label
        self.hosts = hosts
        self.tier = tier
        self.viewGate = viewGate
        self.fields = fields
        self.defaultField = defaultField
    }

    /// Anchored suffix semantics: exact host, or a subdomain at a dot
    /// boundary. Never a plain `hasSuffix` — "github.com.evil.example" and
    /// "notgithub.com" must both fail.
    public func matches(host: String) -> Bool {
        let h = host.lowercased()
        return hosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// One extractable field. Everything here is data so a future pack can
    /// ship new fields without code.
    public struct Field: Codable, Equatable, Sendable {
        /// Rule/feature key and `SegmentKind.recipeField`'s association.
        public let name: String
        /// Display name ("Repository").
        public let label: String
        public let source: Source
        /// true = subject-like CONTENT, matched by case-insensitive
        /// substring (rule values are substrings) and never emitted as a
        /// learned feature; false = identity, matched by equality.
        public let isContent: Bool
        /// Multi-value fields commit one rule per chosen value (the email
        /// multi-correspondent flow). No v1 recipe uses it; modelled so the
        /// Gmail correspondent field fits when it migrates (spec §3).
        public let multi: Bool
        /// When set, extraction ghosts unless the value (lowercased) is in
        /// this list — GitHub's `section` grain, Docs' `docType`.
        public let allowed: [String]?
        /// When set, extraction runs only when the URL PATH matches this
        /// regex — gates GitHub's item-title read to issue/PR pages so a
        /// repo-home title never mints a junk content value (the
        /// "Inbox (1)" staleness lesson applied to Tier 0's one stale-ish
        /// input, the window title — spec §9).
        public let pathRegex: String?
        /// When set, the identity chain DISPLAYS this other field's value
        /// while the rule keys on this field's own (Docs: the rule keys on
        /// the stable opaque doc id, the row shows the human title — the
        /// rule survives a rename).
        public let displayVia: String?

        public init(name: String, label: String, source: Source,
                    isContent: Bool = false, multi: Bool = false,
                    allowed: [String]? = nil, pathRegex: String? = nil,
                    displayVia: String? = nil) {
            self.name = name
            self.label = label
            self.source = source
            self.isContent = isContent
            self.multi = multi
            self.allowed = allowed
            self.pathRegex = pathRegex
            self.displayVia = displayVia
        }
    }

    /// Where a field's value comes from. Tier 0 sources only read the URL
    /// and window title; `domSelector` is Tier 1 and extracts nothing in v1.
    public enum Source: Codable, Equatable, Sendable {
        /// URL path segment by index (0 = first after the host).
        case pathComponent(Int)
        /// The segment following the FIRST of these markers present
        /// ("d" → a Docs id, "folders" → a Drive folder id).
        case pathAfter([String])
        /// The first path segment carrying this prefix (Xero's "!" org
        /// shortcode).
        case pathComponentPrefixed(String)
        /// The segment following the first prefixed one (Xero's app
        /// section, right after the shortcode).
        case pathAfterPrefixed(String)
        /// The URL fragment's last path component (Gmail's thread-id
        /// position — unused by v1 recipes, kept so the Gmail re-expression
        /// in the spec §3 stays honest).
        case fragmentLastComponent
        /// The window title minus the FIRST of these suffixes that matches;
        /// no suffix match = no value (a lagging SPA title must ghost, not
        /// mint junk).
        case titleStripSuffix([String])
        /// The window title's leading segment before this separator; no
        /// separator = no value.
        case titleLeadingSegment(String)
        /// Tier 1 only — a DOM selector for the browser JS channel. Never
        /// evaluated in v1 (no DOM probe, no new permissions).
        case domSelector(String, attribute: String?)
    }
}

/// A small declarative URL predicate (all conditions must hold) — the view
/// gate stays data rather than a closure so a recipe remains serialisable
/// and a future pack can ship new gates without code (spec §3).
public struct URLShape: Codable, Equatable, Sendable {
    public var minPathDepth: Int
    /// Reserved first path segments that are NOT the entity the recipe
    /// models (GitHub's /settings, /notifications, …). Lowercased.
    public var firstSegmentDenylist: [String]
    /// At least one of these markers must appear as a path component WITH a
    /// following component ("d" gates Docs to open documents).
    public var pathMarkers: [String]
    /// A path component with this prefix must exist (Xero's "!" shortcode).
    public var pathPrefixMarker: String?

    public init(minPathDepth: Int = 0, firstSegmentDenylist: [String] = [],
                pathMarkers: [String] = [], pathPrefixMarker: String? = nil) {
        self.minPathDepth = minPathDepth
        self.firstSegmentDenylist = firstSegmentDenylist
        self.pathMarkers = pathMarkers
        self.pathPrefixMarker = pathPrefixMarker
    }

    public func admits(_ url: URL) -> Bool {
        let path = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard path.count >= minPathDepth else { return false }
        if let first = path.first, firstSegmentDenylist.contains(first.lowercased()) {
            return false
        }
        if !pathMarkers.isEmpty {
            let hasMarker = pathMarkers.contains { marker in
                path.firstIndex(of: marker).map { $0 + 1 < path.count } ?? false
            }
            guard hasMarker else { return false }
        }
        if let prefix = pathPrefixMarker {
            guard path.contains(where: { $0.hasPrefix(prefix) && $0.count > prefix.count })
            else { return false }
        }
        return true
    }
}

/// What a recipe (or the recipe-less host fallback) understood about one
/// signal — the pure, derived-on-demand product of `SiteRecipes.extract`/
/// `context(for:)`. Nothing here is ever stored: attribution, identity
/// chains, learned features and the review footer all re-derive it from any
/// signal (which is what lets old review rows gain recipe grains
/// retroactively with no schema change).
public struct SiteContext: Equatable, Sendable {
    /// The matched recipe, or nil for the host-only degradation (the policy
    /// note's "one correction generalises the whole host" — learnable on
    /// EVERY non-mail URL page, no recipe needed).
    public let recipe: SiteRecipe?
    /// Lowercased URL host.
    public let host: String
    /// Extracted field values by field name. Missing fields are simply
    /// absent (they render as ghost rows), never empty strings.
    public let values: [String: String]

    public init(recipe: SiteRecipe?, host: String, values: [String: String]) {
        self.recipe = recipe
        self.host = host
        self.values = values
    }

    /// The grain ladder for matching, general → specific: the reserved
    /// `site` level below every recipe field, then the recipe's declared
    /// field order (spec §5).
    public var ladder: [String] {
        [SiteRule.siteField] + (recipe?.fields.map(\.name) ?? [])
    }
}

public enum SiteRecipes {
    /// v1 ships built-ins only (spec §0 Q5) — the three sites where Martin's
    /// browser time actually goes and URL + title are insufficient today.
    public static let builtIn: [SiteRecipe] = [github, gdocs, xero]

    /// The enabled recipe covering `host`, if any.
    public static func recipe(forHost host: String,
                              disabled: Set<String> = []) -> SiteRecipe? {
        builtIn.first { !disabled.contains($0.id) && $0.matches(host: host) }
    }

    /// Tier 0 extraction: nil when the signal has no URL, when the host is a
    /// known mail system (email keeps its own richer pipeline — the two rule
    /// domains are host-disjoint by construction, spec §3), when no enabled
    /// recipe's hosts match, or when the recipe's view gate refuses the
    /// page. Pure and synchronous — URL and title ARE the current signal.
    public static func extract(_ signal: ActivitySignal,
                               disabled: Set<String> = []) -> SiteContext? {
        guard let (url, host) = nonMailURL(of: signal),
              let recipe = Self.recipe(forHost: host, disabled: disabled),
              recipe.viewGate.admits(url) else { return nil }
        let path = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        var values: [String: String] = [:]
        for field in recipe.fields {
            if let value = extractValue(field, url: url, path: path,
                                        title: signal.windowTitle) {
                values[field.name] = value
            }
        }
        return SiteContext(recipe: recipe, host: host, values: values)
    }

    /// The matching context for ANY web page: full extraction where a recipe
    /// matches (and its gate admits), else the host-only degradation — which
    /// is what makes the `site` grain learnable everywhere (spec §0 Q2).
    /// Still nil for mail hosts and URL-less signals.
    public static func context(for signal: ActivitySignal,
                               disabled: Set<String> = []) -> SiteContext? {
        if let extracted = extract(signal, disabled: disabled) { return extracted }
        guard let (_, host) = nonMailURL(of: signal) else { return nil }
        return SiteContext(recipe: nil, host: host, values: [:])
    }

    /// The signal's URL + lowercased host, nil when absent or a known mail
    /// system (`EmailSystem.detect` — email keeps its own pipeline).
    private static func nonMailURL(of signal: ActivitySignal) -> (URL, String)? {
        guard let raw = signal.tabURL, let url = URL(string: raw),
              let host = url.host?.lowercased(),
              EmailSystem.detect(urlHost: host) == .unknown else { return nil }
        return (url, host)
    }

    private static func extractValue(_ field: SiteRecipe.Field, url: URL,
                                     path: [String], title: String?) -> String? {
        if let pattern = field.pathRegex,
           url.path.range(of: pattern, options: .regularExpression) == nil {
            return nil
        }
        let raw: String?
        switch field.source {
        case .pathComponent(let i):
            raw = i < path.count ? path[i] : nil
        case .pathAfter(let markers):
            raw = markers.compactMap { marker in
                path.firstIndex(of: marker).flatMap { i in
                    i + 1 < path.count ? path[i + 1] : nil
                }
            }.first
        case .pathComponentPrefixed(let prefix):
            raw = path.first { $0.hasPrefix(prefix) && $0.count > prefix.count }
        case .pathAfterPrefixed(let prefix):
            raw = path.firstIndex(where: { $0.hasPrefix(prefix) && $0.count > prefix.count })
                .flatMap { i in i + 1 < path.count ? path[i + 1] : nil }
        case .fragmentLastComponent:
            let fragPath = url.fragment.map {
                $0.split(separator: "?").first.map(String.init) ?? $0
            }
            raw = fragPath?.split(separator: "/").last.map(String.init)
        case .titleStripSuffix(let suffixes):
            guard let title else { raw = nil; break }
            raw = suffixes.compactMap { suffix in
                title.hasSuffix(suffix) ? String(title.dropLast(suffix.count)) : nil
            }.first
        case .titleLeadingSegment(let separator):
            guard let title, title.contains(separator) else { raw = nil; break }
            raw = title.components(separatedBy: separator).first
        case .domSelector:
            raw = nil   // Tier 1 — no DOM channel in v1 (spec §11)
        }
        guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty
        else { return nil }
        if let allowed = field.allowed, !allowed.contains(value.lowercased()) {
            return nil
        }
        return value
    }

    // MARK: - The v1 recipes (spec §4)

    /// GitHub (§4.1). The money grain is REPO — "example-repo → task X" in one
    /// correction, which neither `urlPath` learning (owner only) nor
    /// anything short of a hand-built pin reaches. The denylist keeps
    /// GitHub's reserved top-level surfaces (your notifications, search, …)
    /// from minting a junk "owner".
    static let github = SiteRecipe(
        id: "github", label: "GitHub", hosts: ["github.com"], tier: 0,
        viewGate: URLShape(minPathDepth: 1, firstSegmentDenylist: [
            "settings", "notifications", "orgs", "marketplace", "pulls",
            "issues", "search", "explore", "topics", "trending", "sponsors",
            "features", "about", "pricing", "login", "logout", "signup",
            "new", "codespaces", "dashboard", "apps", "collections", "events",
        ]),
        fields: [
            .init(name: "owner", label: "Owner", source: .pathComponent(0)),
            .init(name: "repo", label: "Repository", source: .pathComponent(1)),
            .init(name: "section", label: "Section", source: .pathComponent(2),
                  allowed: ["issues", "pulls", "pull", "actions", "wiki",
                            "discussions", "projects", "releases"]),
            // "Issue title · Issue #42 · owner/repo" — the leading segment,
            // gated to pages whose PATH names an issue/PR/discussion number
            // so a repo-home or file-browser title never becomes content.
            .init(name: "title", label: "Item title",
                  source: .titleLeadingSegment(" · "), isContent: true,
                  pathRegex: "/(issues|pull|discussions)/[0-9]+"),
        ],
        defaultField: "repo")

    /// Google Docs / Drive (§4.2). The DOCUMENT grain keys the rule on the
    /// stable opaque id but DISPLAYS the title-derived name (`displayVia`),
    /// so the rule survives the document being renamed. Title extraction is
    /// gated on the Google suffix actually matching — a lagging SPA title
    /// ghosts instead of minting a junk value.
    static let gdocs = SiteRecipe(
        id: "gdocs", label: "Google Docs / Drive",
        hosts: ["docs.google.com", "drive.google.com"], tier: 0,
        viewGate: URLShape(pathMarkers: ["d", "folders"]),
        fields: [
            .init(name: "docType", label: "Document type", source: .pathComponent(0),
                  allowed: ["document", "spreadsheets", "presentation", "forms", "drive"]),
            .init(name: "document", label: "Document",
                  source: .pathAfter(["d", "folders"]), displayVia: "docTitle"),
            .init(name: "docTitle", label: "Title",
                  source: .titleStripSuffix([" - Google Docs", " - Google Sheets",
                                             " - Google Slides", " - Google Forms",
                                             " - Google Drive"]),
                  isContent: true),
        ],
        defaultField: "document")

    /// Xero (§4.3) — ⚠️ EXTRACTORS ASSERTED FROM MEMORY, NOT A LIVE SESSION.
    /// The assumed shapes, which the fixtures in SiteRecipeChecks encode and
    /// which MUST be verified against real go.xero.com pages (use the
    /// Settings ▸ Diagnostics "What recipes see here" row) before this
    /// recipe's behaviour is claimed:
    ///   • URL: an org shortcode path segment starting with "!"
    ///     (go.xero.com/app/!x7Kp2/invoicing or go.xero.com/!x7Kp2/…), the
    ///     app section as the segment right after it.
    ///   • Title: "<page name> | Xero".
    /// If live pages differ, fix the source table here and the fixtures
    /// together. The ORGANISATION grain maps Xero orgs to their entity
    /// tasks in one correction each — the accounts-period use case.
    /// Everything on these pages is screen-observed; nothing touches the
    /// Xero API, so the LearningStore compliance invariant is untouched.
    static let xero = SiteRecipe(
        id: "xero", label: "Xero", hosts: ["go.xero.com"], tier: 0,
        viewGate: URLShape(minPathDepth: 1, pathPrefixMarker: "!"),
        fields: [
            .init(name: "organisation", label: "Organisation",
                  source: .pathComponentPrefixed("!")),
            .init(name: "section", label: "Section",
                  source: .pathAfterPrefixed("!")),
            .init(name: "pageTitle", label: "Page title",
                  source: .titleStripSuffix([" | Xero"]), isContent: true),
        ],
        defaultField: "organisation")

    // MARK: - Diagnostics

    /// The Settings ▸ Diagnostics "What recipes see here" dump — pure and
    /// deterministic so it's checkable without a Mac. Shows exactly what the
    /// recipe layer derives from a signal: the matched recipe, every field
    /// (extracted value or "not captured"), the view-gate outcome, or why
    /// nothing applies. Field VALUES are shown (this is an on-demand, user-
    /// initiated inspection of their own screen, like the Evidence Card) —
    /// but this text must never be routed to DebugLog (spec §9: log
    /// mechanics, never content).
    public static func probeText(for signal: ActivitySignal,
                                 disabled: Set<String> = []) -> String {
        guard let raw = signal.tabURL, let url = URL(string: raw),
              let host = url.host?.lowercased() else {
            return "No tab URL on the current window — recipes read URL + title only."
        }
        var lines = ["host: \(host)", "title: \(signal.windowTitle ?? "—")"]
        guard EmailSystem.detect(urlHost: host) == .unknown else {
            lines.append("mail system detected — email keeps its own pipeline; site recipes never run here.")
            return lines.joined(separator: "\n")
        }
        guard let recipe = builtIn.first(where: { $0.matches(host: host) }) else {
            lines.append("no recipe for this host — the site grain (host → task) still applies.")
            return lines.joined(separator: "\n")
        }
        if disabled.contains(recipe.id) {
            lines.append("recipe: \(recipe.label) — DISABLED in the rules ledger; extracting nothing.")
            return lines.joined(separator: "\n")
        }
        guard recipe.viewGate.admits(url) else {
            lines.append("recipe: \(recipe.label) — view gate refused this page (not an entity view); the site grain still applies.")
            return lines.joined(separator: "\n")
        }
        lines.append("recipe: \(recipe.label)")
        let context = extract(signal, disabled: disabled)
        for field in recipe.fields {
            let value = context?.values[field.name]
            lines.append("  \(field.label): \(value ?? "not captured")")
        }
        return lines.joined(separator: "\n")
    }
}
