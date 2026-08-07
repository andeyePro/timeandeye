import Foundation

/// The user's explicit categorisation of a context, sticky for the rest of the
/// LOCAL DAY. Fixes Martin's 2026-07-02 report: typing an email, every
/// leave-and-return re-ran the inferred ladder and an older email rule
/// re-took the slice — "if you're working on one email and you categorise it,
/// that should take precedence over anything else, at least within that one
/// session". A sticky outranks every INFERRED source (email rules, primes,
/// URL recognition, ranker); only an explicit pin (1.0, standing law) sits
/// above it. Ephemeral by design: dies at end of day or app relaunch.
package struct SessionSticky: Equatable, Sendable {
    /// Hashable so the pre-correction snapshot store can key on it (see
    /// `Attributor.displacedByCorrection`).
    package enum Key: Hashable, Sendable {
        /// Email thread identity: the normalised subject (re:/fwd: stripped,
        /// lowercased). Chosen over the raw Surface because a draft's window
        /// title mutates as you type — the subject is what stays put.
        case emailSubject(String)
        /// Subject-less email: the correspondent set.
        case correspondents(Set<String>)
        /// Any non-email context: the focus surface.
        case surface(Surface)
    }
    package var key: Key
    package var target: Target
    /// Start of the local day it was created; valid only that day.
    package var day: Date

    package init(key: Key, target: Target, day: Date) {
        self.key = key
        self.target = target
        self.day = day
    }
}

package struct Candidate: Equatable, Sendable {
    package var target: Target
    package var score: Double
    package init(target: Target, score: Double) {
        self.target = target
        self.score = score
    }
}

package struct Attribution: Equatable, Sendable {
    package var best: Candidate?
    package var ranked: [Candidate]
    /// Which source decided `best` (+ the matched rule/key when one
    /// existed) — journalled at flush so the Evidence Card can name the
    /// original decider verbatim. Defaults keep older call sites compiling.
    package var provenance: SessionProvenance?
    /// True iff this signal fell all the way to the RANKED tier — no pin,
    /// sticky, OP URL/title, email rule, site rule or prime fired — AND it
    /// is a web page (a tab URL) whose host the site-rule ladder and the
    /// learner have both never heard from (ambiguous-web-page policy,
    /// Martin 2026-07-23: "Yes stay on current task (but monitor
    /// window/tab change)"). Computed fresh every call, never latched: the
    /// very next signal with rule-grade evidence or a learned host
    /// attributes normally. `SessionTracker` reads this to hold the
    /// running task instead of opening a pending switch to whatever the
    /// bare ranker liked on an unfamiliar page. Defaults keep older call
    /// sites compiling.
    package var ambiguousSurface: Bool
    package var certainty: Double { best?.score ?? 0 }
    package init(best: Candidate?, ranked: [Candidate],
                provenance: SessionProvenance? = nil,
                ambiguousSurface: Bool = false) {
        self.best = best
        self.ranked = ranked
        self.provenance = provenance
        self.ambiguousSurface = ambiguousSurface
    }
}

/// A human-readable account of WHY a signal attributed to a target — the
/// timeline "why was this tracked as X?" view. Mirrors `attribute()` exactly so
/// the explanation can never disagree with the real decision.
public struct AttributionExplanation: Equatable, Sendable {
    public enum Source: String, Sendable, Equatable {
        case pin                 // an explicit user pin (100%)
        case sessionSticky       // the user categorised this context today
        case opTaskURL           // a work-package URL in the tab
        case opTaskTitle         // a work-package id in the window title / app
        case emailRule           // a learned email correspondent/domain/subject → task rule
        case siteRule            // a learned site recipe-field/host → task rule
        case pendingPrime        // a just-opened OP task priming the next surface
        case primedSurface       // a remembered surface→task (a past correction)
        case ranked              // learned associations + status/recency priors
        case none
    }
    /// One candidate task and how its score broke down (learned vs prior).
    package struct Line: Equatable, Sendable {
        package var target: Target
        package var score: Double
        package var learned: Double   // contribution from learned associations
        package var prior: Double     // contribution from status/recency/time-of-day
        /// Contribution from a live calendar match (calendar signal spec §5)
        /// – defaults to 0 so every existing call site stays source-compatible;
        /// the Attributor's scoring path sets it once wired.
        package var calendarPart: Double
        package init(target: Target, score: Double, learned: Double, prior: Double,
                    calendarPart: Double = 0) {
            self.target = target; self.score = score; self.learned = learned; self.prior = prior
            self.calendarPart = calendarPart
        }
    }
    /// What the engine believed BEFORE the user's correction displaced it —
    /// captured the moment the correction lands (`confirm`/`assign`) so the
    /// Evidence Card can keep the story straight instead of pretending it
    /// always agreed (2026-07-05 hardware-test report: "I'm confident it's
    /// X" → correction → "I'm confident it's Y, I never thought it was X").
    package struct Prior: Equatable, Sendable {
        package var source: Source
        package var chosen: Target
        package var score: Double
        package init(source: Source, chosen: Target, score: Double) {
            self.source = source; self.chosen = chosen; self.score = score
        }
    }
    package var source: Source
    package var chosen: Target?
    package var chosenScore: Double
    /// Ranked alternatives with their score breakdown (empty for pin/OP sources,
    /// where the decision bypasses scoring).
    package var lines: [Line]
    /// The signal features the learner keys on (e.g. "app=chrome",
    /// "title=insurance") — what you'd correct to change the outcome.
    package var features: [String]
    /// The exact rule/pin that fired, when the source is .emailRule /
    /// .siteRule / .pin — carried here (with its metadata) so the Evidence
    /// Card never re-derives them and can never disagree with the decision.
    package var matchedEmailRule: EmailRule?
    package var matchedSiteRule: SiteRule?
    package var matchedPin: Pin?
    /// The remembered surface that matched, when the source is
    /// .primedSurface / .pendingPrime — carried so the card can SHOW the
    /// key that fired: an over-broad prime (e.g. a whole mail tab keyed by
    /// its URL fragment, or a title-less window keyed by app alone) is
    /// invisible — and effectively unforgettable — unless the matched key
    /// is on the card (Martin's 2026-07-10 why-panel report).
    package var matchedSurface: Surface?
    /// Set only when the source is a correction (`.sessionSticky`) that
    /// displaced a real prior belief — the card's "before your correction:
    /// Apple 71% (learned)" history line. nil when the engine already agreed
    /// with the pick, or believed nothing.
    package var priorToCorrection: Prior?
    /// Mirrors `Attribution.ambiguousSurface` exactly for the same signal —
    /// a re-derivation can never disagree with the live hold decision
    /// (ambiguous-web-page policy, Martin 2026-07-23). Source stays
    /// `.ranked`/`.none` as before (no new source word); this flag is what
    /// a why-panel names the hold from, honestly, without inventing jargon.
    package var ambiguousSurface: Bool
    package init(source: Source, chosen: Target?, chosenScore: Double,
                lines: [Line], features: [String],
                matchedEmailRule: EmailRule? = nil, matchedSiteRule: SiteRule? = nil,
                matchedPin: Pin? = nil, priorToCorrection: Prior? = nil,
                matchedSurface: Surface? = nil, ambiguousSurface: Bool = false) {
        self.source = source; self.chosen = chosen; self.chosenScore = chosenScore
        self.lines = lines; self.features = features
        self.matchedEmailRule = matchedEmailRule; self.matchedSiteRule = matchedSiteRule
        self.matchedPin = matchedPin
        self.priorToCorrection = priorToCorrection
        self.matchedSurface = matchedSurface
        self.ambiguousSurface = ambiguousSurface
    }

    /// An `explain()` is always a RE-DERIVATION from the current stores. For
    /// a journalled slice that already has a recorded outcome, the stores may
    /// have moved on since the decision was made — a correction elsewhere can
    /// prime this slice's surface toward a task that never actually fired
    /// here (Martin's 2026-07-10 report: a window in a Time&I slice whose
    /// BECAUSE read "remembered from a past correction → andeye Ltd
    /// confirmation statement…", a reason learned AFTER the slice was
    /// decided). True when this re-derivation contradicts the record — the
    /// why-panel must then anchor BECAUSE on the record and demote this
    /// explanation to "what today's rules would say".
    package func contradicts(recorded: Target) -> Bool {
        chosen != recorded
    }
}

package extension AttributionExplanation.Source {
    /// A plain word for where a certainty comes from — the review drawer's
    /// shared vocabulary (compressed `EvidenceCardView.becauseLabel`), used
    /// by the slice detail line and the assign buttons' hover build alike
    /// so the two can never drift apart.
    var plainWord: String {
        switch self {
        case .pin: return "pinned"
        case .sessionSticky: return "categorised earlier that day"
        case .opTaskURL, .opTaskTitle: return "OP page"
        case .emailRule: return "learned rule"
        case .siteRule: return "learned site rule"
        case .pendingPrime: return "just-opened OP task"
        case .primedSurface: return "past correction"
        case .ranked: return "learned associations + priors"
        case .none: return "nothing matched"
        }
    }
}

/// Turns one ActivitySignal into a ranked list of targets.
/// Source strength order (spec): OP task URL > primed surface > pending prime
/// > learned associations + priors.
package final class Attributor {
    /// Mutable so the app can apply a changed OP URL without a relaunch.
    package var instanceHost: String
    /// Override for non-OP backends; nil = the default OP recognizer built
    /// from `instanceHost`. Standalone: `NoPageRecognizer()`.
    package var customRecognizer: BackendPageRecognizer?
    private var recognizer: BackendPageRecognizer {
        customRecognizer ?? OPPageRecognizer(instanceHost: instanceHost)
    }
    package private(set) var learning: LearningStore
    private let ranker: TaskRanker

    private var lastOpenedBackendTask: TaskRef?
    private var pendingPrime: (surface: Surface, task: TaskRef, at: Date)?
    /// A pending prime is a HYPOTHESIS ("you just opened task X, this next
    /// surface is probably its workspace") — it must not outrank a confirmed
    /// prime forever (reviewer B8: one glance at another task's page silently
    /// re-attributed a confirmed surface at 0.7 for the rest of the run).
    static let pendingPrimeTTL: TimeInterval = 900
    /// Public so the app can persist and restore it across launches —
    /// losing primed associations on relaunch dropped session certainty
    /// below the push threshold (found 2026-06-11).
    package var primedSurfaces: [Surface: TaskRef] = [:]
    /// Explicit user pins. Within `attribute()` a pin is the only producer
    /// that returns `humanWord` (1.0): every inferred source caps at
    /// `inferredCeiling`, the ranked fallback at `rankedCeiling`. But 1.0 is
    /// the HUMAN-WORD tier, not the pin's alone — the controller's review
    /// confirm, timeline reassign and Unknown-sweep gestures write it too (a
    /// person asserted the assignment), so a pin is the sole 1.0 the ENGINE
    /// derives, not the sole 1.0 in the journal. A pin overrides the ranker,
    /// learning, soft primes and even a work-package URL. Each pin carries a rule (component
    /// prefix or boolean expression). Set only by the explicit pin editor,
    /// never by an ordinary correction (those stay soft primes). When several
    /// match, the most specific wins (manual `priority` first, then leaf count,
    /// then most-recently-added). See `Pin` / `PinRule`.
    package var pins: [Pin] = []
    /// Learned email correspondent→task rules (the auto-learner's deterministic
    /// ladder). Populated by corrections on email surfaces; matched most-specific
    /// first per `emailMatchOrder`. Caps at 0.95 like any inferred source.
    package var emailRules: [EmailRule] = []
    /// The user-editable specificity order the email ladder resolves through
    /// (mirrors the setting; defaults general→specific).
    package var emailMatchOrder: [EmailMatchLevel] = EmailMatchLevel.defaultOrder
    /// Learned/pinned site rules (recipe field / host → task) — the third
    /// rule domain (2026-07-09 site-recipes spec §5), on the SAME 0.95 rung
    /// as `emailRules`; the two are host-disjoint (mail hosts never produce
    /// a SiteContext), so no page can ever match both. Persisted to
    /// siterules.json by the app, like the other stores.
    package var siteRules: [SiteRule] = []
    /// Per-recipe capture toggles, mirrored from the setting (spec §0 Q4:
    /// recipes ship enabled; the ledger's recipe strip can turn each off). A
    /// disabled recipe extracts nothing — its rules go dormant (kept, never
    /// deleted) and it emits no identity segments or learned features.
    package var disabledSiteRecipes: Set<String> = []
    /// Fires exactly once per rule's lifetime, the moment it wins its FIRST
    /// attribution ever (fireCount 0 → 1) — the popover's First-FIRE toast
    /// hook (2026-07-03 spec §6 "later polish", brought forward: "the user
    /// discovers the automation is real"). nil by default. `explain()` never
    /// triggers it — only a real `attribute()` win bumps fireCount — and a
    /// rule that's forgotten then re-taught fires again (it's a fresh
    /// `EmailRule` with fireCount reset to 0, not the same rule). Wired in
    /// `AppController` to publish a popover notice.
    package var onFirstFire: ((EmailRule) -> Void)?
    /// `onFirstFire`'s site-rule twin — same once-per-rule-lifetime
    /// semantics, driven only by a real `attribute()` win.
    package var onFirstSiteFire: ((SiteRule) -> Void)?
    /// The live calendar match (2026-07-09 calendar-signal spec §5), set by
    /// the platform layer whenever the bridge's event window or a boundary
    /// crossing changes it. Feeds the ranker's calendar term inside
    /// `scoredComponents`, so a live meeting nudges the ranked fallback —
    /// bounded by the existing 0.9 cap, never above a pin/sticky/URL/email
    /// match.
    package var currentCalendarMatch: (task: TaskRef, tentative: Bool)?
    /// Today's explicit categorisations, by context (see SessionSticky).
    /// Deliberately not persisted — a sticky is a same-day working decision.
    package private(set) var sessionStickies: [SessionSticky] = []
    /// What the engine believed before a correction displaced it, keyed by
    /// the sticky that correction wrote — the Evidence Card's "before your
    /// correction: Apple 71%" history line, so a correction never rewrites
    /// history into "Y is the only thing I ever thought it could be"
    /// (2026-07-05 hardware-test report). Shares the sticky's lifetime
    /// exactly (pruned at day rollover, removed on forget, dies at relaunch).
    /// Public var, like the other stores, so the app's undo can snapshot and
    /// restore it wholesale.
    package var displacedByCorrection: [SessionSticky.Key: AttributionExplanation.Prior] = [:]

    package init(instanceHost: String, learning: LearningStore = LearningStore(),
                ranker: TaskRanker = TaskRanker()) {
        self.instanceHost = instanceHost
        self.learning = learning
        self.ranker = ranker
    }

    /// The three tier ceilings (attribution-calculus spec §The three tiers).
    /// Only a HUMAN WORD (`humanWord`, 1.0 — a pin, manual start, review
    /// confirm, timeline reassign or Unknown-sweep repoint) reaches 1.0. A
    /// learned/structural rule (sticky, OP URL/title, email/site rule, primed
    /// surface, idle-gap claim, adjacency-corroborated lift) caps at
    /// `inferredCeiling`; an uncorroborated engine ranking at `rankedCeiling`.
    /// The floor is 0 — no producer journals a negative certainty.
    package static let humanWord = 1.0
    package static let inferredCeiling = 0.95
    package static let rankedCeiling = 0.9
    /// A just-opened OP task priming the NEXT surface — a hypothesis, scored
    /// below the inferred rules it may become so it never masquerades as one.
    package static let pendingPrimeScore = 0.7

    /// What the clock is running on, as an attribution prior (Martin,
    /// 2026-07-10, his): the tracker passes the COMMITTED task of the
    /// open slice and when activity last fed it, and `attribute` lifts that
    /// task's candidate by the one-sided adjacency boost. Only the ranked
    /// fallback is touched — a pin, sticky, backend URL/title or learned
    /// rule is definitive evidence and returns before this applies.
    package struct Continuity: Equatable, Sendable {
        package let target: Target
        /// The last moment activity actually fed the running slice; the
        /// boost decays over the gap to `now` exactly like a journal
        /// neighbour's (full ≤30s, zero at 15min).
        package let lastActive: Date
        package init(target: Target, lastActive: Date) {
            self.target = target
            self.lastActive = lastActive
        }
    }

    /// The live boost the most recent `attribute` call applied — nil when
    /// none. The tracker logs it (reasoning + sizes) so the shared constants
    /// can later be FITTED from correction outcomes.
    package private(set) var lastLiveBoost: AdjacencyBoost?

    package func attribute(_ signal: ActivitySignal, tasks: [WorkTask], now: Date,
                          continuity: Continuity? = nil) -> Attribution {
        lastLiveBoost = nil
        // An explicit pin is law: it wins over a work-package URL and the
        // ranker alike. Alternatives still rank beneath it for the switch-list.
        if let pin = matchingPin(for: signal) {
            var ranked = scored(signal, tasks: tasks, now: now)
            ranked.removeAll { $0.target == .task(pin.task) }
            let c = Candidate(target: .task(pin.task), score: 1.0)
            ranked.insert(c, at: 0)
            return Attribution(best: c, ranked: ranked,
                               provenance: .init(source: .pin))
        }
        // The user categorised THIS context today: their word beats every
        // inferred source below (URL, email rules, primes, ranker) so a
        // leave-and-return can never silently re-allocate the slice.
        if let sticky = stickyMatch(for: signal, now: now) {
            var ranked = scored(signal, tasks: tasks, now: now)
            ranked.removeAll { $0.target == sticky.target }
            let c = Candidate(target: sticky.target, score: Self.inferredCeiling)
            ranked.insert(c, at: 0)
            return Attribution(best: c, ranked: ranked,
                               provenance: .init(source: .sessionSticky))
        }
        if let url = signal.tabURL, let ref = recognizer.taskRef(inURL: url) {
            lastOpenedBackendTask = ref
            let c = Candidate(target: .task(ref), score: Self.inferredCeiling)
            return Attribution(best: c, ranked: [c],
                               provenance: .init(source: .opTaskURL))
        }
        // No URL (e.g. OP as a Chrome PWA): the WP id may be in the window
        // title — or in the app name, which PWAs set to the page title.
        for text in [signal.windowTitle, signal.app].compactMap({ $0 }) {
            if let ref = recognizer.taskRef(inTitle: text) {
                lastOpenedBackendTask = ref
                let c = Candidate(target: .task(ref), score: Self.inferredCeiling)
                return Attribution(best: c, ranked: [c],
                                   provenance: .init(source: .opTaskTitle))
            }
        }
        // A learned email rule (correspondent / domain / subject → task) outranks
        // the soft primes and the ranker — you've effectively taught "mail from X
        // is task Y". Still an inferred source, so it caps at 0.95, below a pin /
        // OP-URL.
        if let rule = emailRuleMatch(signal) {
            recordFire(rule, now: now)
            var ranked = scored(signal, tasks: tasks, now: now)
            ranked.removeAll { $0.target == .task(rule.target) }
            let c = Candidate(target: .task(rule.target), score: Self.inferredCeiling)
            ranked.insert(c, at: 0)
            return Attribution(best: c, ranked: ranked,
                               provenance: .init(source: .emailRule,
                                                 detail: rule.value.isEmpty ? nil : rule.value))
        }
        // A learned site rule (recipe field / host → task) sits on the SAME
        // rung as an email rule — email is consulted first purely for
        // determinism; the two are host-disjoint (a mail host never produces
        // a SiteContext), so no page can ever match both.
        if let rule = siteRuleMatch(signal) {
            recordSiteFire(rule, now: now)
            var ranked = scored(signal, tasks: tasks, now: now)
            ranked.removeAll { $0.target == .task(rule.target) }
            let c = Candidate(target: .task(rule.target), score: Self.inferredCeiling)
            ranked.insert(c, at: 0)
            return Attribution(best: c, ranked: ranked,
                               provenance: .init(source: .siteRule,
                                                 detail: "\(rule.field): \(rule.value)"))
        }
        let surface = Surface(signal: signal)
        var ranked = scored(signal, tasks: tasks, now: now)
        var primeSource: (target: Target, source: AttributionExplanation.Source)?
        if let pending = pendingPrime, pending.surface == surface,
           now.timeIntervalSince(pending.at) <= Self.pendingPrimeTTL {
            ranked.removeAll { $0.target == .task(pending.task) }
            ranked.insert(Candidate(target: .task(pending.task), score: Self.pendingPrimeScore), at: 0)
            primeSource = (.task(pending.task), .pendingPrime)
        } else if let primed = primedSurfaces[surface] {
            if pendingPrime?.surface == surface { pendingPrime = nil }   // expired: dead hypothesis
            ranked.removeAll { $0.target == .task(primed) }
            // A primed surface is a remembered correction — an inferred rule,
            // same rung as email/site rules, so the ceiling constant (not a
            // bare 0.95) keeps it moving in lockstep if that rung is retuned.
            ranked.insert(Candidate(target: .task(primed), score: Self.inferredCeiling), at: 0)
            primeSource = (.task(primed), .primedSurface)
        }
        applyLiveAdjacency(&ranked, continuity: continuity, tasks: tasks, now: now)
        // Provenance names whatever actually ENDED UP on top: a prime if it
        // held, ranked otherwise — with the live-adjacency reasoning as the
        // detail when the boost decided/steadied the winner.
        let provenance: SessionProvenance? = ranked.first.map { best in
            if let prime = primeSource, prime.target == best.target {
                return SessionProvenance(source: prime.source)
            }
            if let boost = lastLiveBoost, continuity?.target == best.target {
                return SessionProvenance(source: .ranked, detail: boost.reasoning)
            }
            return SessionProvenance(source: .ranked)
        }
        // Ambiguous-web-page policy (Martin, 2026-07-23): only when NOTHING
        // rule-grade fired — not even a prime — and the page itself is
        // genuinely unfamiliar (see `hostIsUnknown`).
        let ambiguous = primeSource == nil && hostIsUnknown(signal)
        return Attribution(best: ranked.first, ranked: ranked, provenance: provenance,
                           ambiguousSurface: ambiguous)
    }

    /// The "genuinely unknown" half of the ambiguous-web-page test: a web
    /// page (has a parseable tab URL + host) whose host carries neither a
    /// `site`-level `SiteRule` (pinned or learned) nor any learned
    /// `urlHost`/`urlPath` association — the moment either exists, the page
    /// is no longer ambiguous by this test (a learned host still switches).
    /// Non-web signals (no tab URL) are never ambiguous.
    private func hostIsUnknown(_ signal: ActivitySignal) -> Bool {
        guard let raw = signal.tabURL, let url = URL(string: raw),
              let host = url.host?.lowercased() else { return false }
        let hasSiteRule = siteRules.contains {
            $0.field == SiteRule.siteField
                && $0.value.caseInsensitiveCompare(host) == .orderedSame
        }
        return !hasSiteRule && !learning.hasAssociation(urlHost: host)
    }

    /// Lift the running task's candidate by the live adjacency prior (see
    /// `Continuity`). A task the ranker gave nothing still enters at the
    /// boosted-from-zero score (~0.29 at full strength) — visible in the
    /// switch list as the continuation hypothesis, but below every
    /// tracking threshold on its own.
    private func applyLiveAdjacency(_ ranked: inout [Candidate],
                                    continuity: Continuity?,
                                    tasks: [WorkTask], now: Date) {
        // TIER CROSSING (spec §The three tiers, boundary rule 1): the running
        // task's candidate is a ranked one (≤ rankedCeiling), but live-adjacency
        // corroboration is rule-grade evidence — a neighbour agreeing lifts it
        // INTO the inferred tier, capped at inferredCeiling (AdjacencyBoost's
        // default ceiling), never above. This is the ONLY sanctioned ranked→
        // inferred crossing; nothing here may reach humanWord.
        guard let continuity, case .task(let ref) = continuity.target else { return }
        let gap = max(0, now.timeIntervalSince(continuity.lastActive))
        guard AdjacencyBoost.strength(gap: gap) > 0 else { return }
        let name = tasks.first { $0.ref == ref }?.subject ?? "the running task"
        let base = ranked.first { $0.target == continuity.target }?.score ?? 0
        let boosted = AdjacencyBoost.live(base: base, candidate: continuity.target,
                                          name: name, running: continuity.target,
                                          gap: gap)
        guard boosted.boost > 0 else { return }
        ranked.removeAll { $0.target == continuity.target }
        ranked.append(Candidate(target: continuity.target, score: boosted.certainty))
        ranked.sort { $0.score > $1.score }
        lastLiveBoost = boosted
    }

    /// SessionTracker calls this when a surface has held focus beyond the
    /// prime-dwell threshold. Consumes lastOpenedBackendTask ("immediately following").
    package func noteDwell(_ signal: ActivitySignal, at now: Date = Date()) {
        if let url = signal.tabURL, recognizer.taskRef(inURL: url) != nil {
            return
        }
        for text in [signal.windowTitle, signal.app].compactMap({ $0 })
        where recognizer.taskRef(inTitle: text) != nil {
            return   // an OP page itself never becomes a primed working surface
        }
        guard let task = lastOpenedBackendTask else { return }
        lastOpenedBackendTask = nil
        let surface = Surface(signal: signal)
        if primedSurfaces[surface] != task {
            pendingPrime = (surface, task, now)
        }
    }

    // MARK: - Session stickies

    /// The sticky covering this signal today, if any. Prunes expired entries
    /// as a side effect (they are dead weight once the day rolls over).
    package func stickyMatch(for signal: ActivitySignal, now: Date) -> SessionSticky? {
        sessionStickies.removeAll { !Calendar.current.isDate(now, inSameDayAs: $0.day) }
        // The pre-correction snapshot shares its sticky's lifetime: prune any
        // whose sticky is gone (day rollover above, or a forget).
        if !displacedByCorrection.isEmpty {
            displacedByCorrection = displacedByCorrection.filter { key, _ in
                sessionStickies.contains { $0.key == key }
            }
        }
        let key = Self.stickyKey(for: signal)
        return sessionStickies.last { $0.key == key }
    }

    /// Non-mutating twin of `stickyMatch` for the READ-ONLY explain paths.
    /// The review drawer, retro pass and timeline card all re-explain old
    /// slices AT THEIR OWN MOMENT (`now` = the slice's start) — and the
    /// pruning variant treated that historical `now` as "today", so merely
    /// LOOKING at yesterday's slice deleted today's live stickies from the
    /// store (found investigating Martin's 2026-07-10 why-panel report).
    /// Reads must never write: this filters without removing; only
    /// `attribute()` and the correction paths prune.
    func stickyLookup(for signal: ActivitySignal, now: Date) -> SessionSticky? {
        let key = Self.stickyKey(for: signal)
        return sessionStickies.last {
            $0.key == key && Calendar.current.isDate(now, inSameDayAs: $0.day)
        }
    }

    /// Capture what the engine believed at the moment a correction lands, so
    /// the Evidence Card can keep the story straight afterwards. Only the
    /// FIRST displacement per sticky key is kept — re-correcting must not
    /// overwrite the machine's original belief with the intermediate
    /// correction. Nothing is captured when the engine already agreed with
    /// the pick, or believed nothing: there is no story to straighten.
    /// Called BEFORE `recordSticky`, while the displaced belief still answers.
    @discardableResult
    private func recordDisplaced(_ signal: ActivitySignal, by target: Target,
                                 tasks: [WorkTask], now: Date)
        -> (target: Target, source: AttributionExplanation.Source)? {
        // Prune BEFORE consulting the store: a day-old snapshot must not
        // survive midnight just because this correction is the first touch
        // of the day (explain() below would prune too late - the guard
        // would already have kept the stale entry, and the fresh sticky
        // written after us would then shield it indefinitely).
        _ = stickyMatch(for: signal, now: now)
        let key = Self.stickyKey(for: signal)
        let before = explain(signal, tasks: tasks, now: now)
        guard let chosen = before.chosen, chosen != target, before.source != .none,
              before.chosenScore > 0.01 else { return nil }
        // A zero-evidence ranked "belief" is noise, not a displaced story -
        // don't enshrine "Do not track 0%" as history on a cold start.
        if displacedByCorrection[key] == nil {
            displacedByCorrection[key] = .init(source: before.source, chosen: chosen,
                                               score: before.chosenScore)
        }
        return (chosen, before.source)
    }

    private func recordSticky(_ signal: ActivitySignal, target: Target, now: Date) {
        let key = Self.stickyKey(for: signal)
        sessionStickies.removeAll { $0.key == key }
        sessionStickies.append(SessionSticky(
            key: key, target: target, day: Calendar.current.startOfDay(for: now)))
    }

    /// The most stable identity available for the context: an email keys on
    /// its normalised subject (a draft's window title mutates while you type,
    /// the subject doesn't), then its correspondent set; anything else keys
    /// on the focus surface.
    static func stickyKey(for signal: ActivitySignal) -> SessionSticky.Key {
        if let ctx = EmailContext.from(signal) {
            if let subj = normalisedSubject(ctx.subject), !subj.isEmpty {
                return .emailSubject(subj)
            }
            if !ctx.correspondents.isEmpty {
                return .correspondents(Set(ctx.correspondents))
            }
        }
        return .surface(Surface(signal: signal))
    }

    /// Lowercase, trimmed, reply/forward prefixes stripped (repeatedly, so
    /// "Re: Fwd: X" and "X" collapse to the same thread key).
    static func normalisedSubject(_ subject: String?) -> String? {
        guard var t = subject?.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var stripped = true
        while stripped {
            stripped = false
            for prefix in ["re:", "fwd:", "fw:", "aw:"] where t.hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
            }
        }
        return t
    }

    /// The learned email rule covering this signal, if any (nil for non-email
    /// surfaces or when no rule matches). Pure — explain()/forgettable() call it
    /// too, so the provenance bump lives in `recordFire`, driven only by
    /// `attribute()` (the real decision).
    package func emailRuleMatch(_ signal: ActivitySignal) -> EmailRule? {
        guard !emailRules.isEmpty, let ctx = EmailContext.from(signal) else { return nil }
        return EmailMatcher.match(ctx, rules: emailRules, order: emailMatchOrder)
    }

    /// Provenance: this rule just WON an attribution ("fired 8×" on the card).
    private func recordFire(_ rule: EmailRule, now: Date) {
        guard let i = emailRules.firstIndex(where: { $0.sameRule(as: rule) }) else { return }
        let isFirstFire = emailRules[i].fireCount == 0
        emailRules[i].fireCount += 1
        emailRules[i].lastFired = now
        if isFirstFire { onFirstFire?(emailRules[i]) }
    }

    /// The winning site rule covering this signal, if any (nil for non-URL
    /// surfaces, mail hosts, or when nothing matches). Pure — explain()/
    /// forgettable() call it too, so the provenance bump lives in
    /// `recordSiteFire`, driven only by `attribute()` (the real decision).
    package func siteRuleMatch(_ signal: ActivitySignal) -> SiteRule? {
        guard !siteRules.isEmpty,
              let context = SiteRecipes.context(for: signal,
                                                disabled: disabledSiteRecipes)
        else { return nil }
        return SiteMatcher.match(context, rules: siteRules)
    }

    /// `recordFire`'s site twin.
    private func recordSiteFire(_ rule: SiteRule, now: Date) {
        guard let i = siteRules.firstIndex(where: { $0.sameRule(as: rule) }) else { return }
        let isFirstFire = siteRules[i].fireCount == 0
        siteRules[i].fireCount += 1
        siteRules[i].lastFired = now
        if isFirstFire { onFirstSiteFire?(siteRules[i]) }
    }

    /// Learn a site rule at an EXPLICIT grain — site rules are only ever
    /// born from the Evidence Card, the grain footers or the ledger (spec
    /// §5: no silent rule writes; there is no conservative auto-detect path
    /// here, unlike `learnEmailRule`'s legacy default). Replaces any
    /// existing UNPINNED rule with the same recipe+field+value (a pinned
    /// rule is never silently replaced). `value` is stored lowercased.
    package func learnSiteRule(recipeID: String?, field: String, value: String,
                              to task: TaskRef, pinned: Bool = false,
                              origin: EmailRule.Origin = .card, now: Date = Date()) {
        let stored = value.lowercased()
        siteRules.removeAll {
            $0.recipeID == recipeID && $0.field == field && !$0.pinned
                && $0.value.caseInsensitiveCompare(stored) == .orderedSame
        }
        siteRules.append(SiteRule(recipeID: recipeID, field: field, value: stored,
                                  target: task, pinned: pinned,
                                  createdAt: now, origin: origin))
    }

    /// Shared webmail domains carry no task meaning (everyone is @gmail.com), so a
    /// correction there learns the specific CORRESPONDENT, not the domain.
    static let sharedWebmailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "yahoo.com", "ymail.com", "icloud.com", "me.com", "aol.com", "proton.me",
        "protonmail.com", "gmx.com", "mail.com",
    ]

    /// Learn an email rule: either the conservative auto-detected grain (an
    /// org domain generalises to the whole company; a shared-webmail
    /// correspondent stays per-person — the default when `level`/`value` are
    /// nil), or the EXPLICIT grain a caller has already resolved (the
    /// Evidence Card's Remember/Always, the popover's post-pick grain footer,
    /// the Rules Ledger's "+ rule"). Replaces any existing UNPINNED rule with
    /// the same level+value (a pinned rule is never silently replaced).
    /// `confirm`/`assign` no longer call this silently (2026-07-03
    /// context-rules spec §5.4 — a plain correction proposes via the card /
    /// footer instead of writing a durable rule behind the user's back); the
    /// conservative auto-detect path stays available for direct callers.
    package func learnEmailRule(_ signal: ActivitySignal, to task: TaskRef,
                               level: EmailMatchLevel? = nil, value: String? = nil,
                               pinned: Bool = false, origin: EmailRule.Origin = .correction,
                               now: Date = Date()) {
        let resolvedLevel: EmailMatchLevel
        let resolvedValue: String
        if let level, let value {
            resolvedLevel = level
            resolvedValue = value
        } else {
            guard let ctx = EmailContext.from(signal), let cp = ctx.correspondents.first else { return }
            if let domain = EmailSignal.domain(of: cp), !Self.sharedWebmailDomains.contains(domain) {
                resolvedLevel = .correspondentDomain; resolvedValue = domain
            } else {
                resolvedLevel = .correspondent; resolvedValue = cp
            }
        }
        emailRules.removeAll {
            $0.level == resolvedLevel && $0.value.caseInsensitiveCompare(resolvedValue) == .orderedSame && !$0.pinned
        }
        emailRules.append(EmailRule(level: resolvedLevel, value: resolvedValue, target: task, pinned: pinned,
                                    createdAt: now, origin: origin))
    }

    /// Explicit user confirmation (popover click + return, or any direct pick).
    /// Sticky + soft-prime fire unconditionally; a durable email rule is no
    /// longer written here (2026-07-03 spec §5.4) — the Evidence Card / post-
    /// pick grain footer propose one instead, so declining it never loses
    /// today's fix. `tasks` lets the pre-correction snapshot capture a
    /// ranked belief's real score ([] degrades gracefully: rule/prime/URL
    /// sources still snapshot correctly).
    package func confirm(_ signal: ActivitySignal, task: TaskRef,
                        tasks: [WorkTask] = [], now: Date = Date()) {
        let displaced = recordDisplaced(signal, by: .task(task), tasks: tasks, now: now)
        recordSticky(signal, target: .task(task), now: now)
        primeSurface(signal, to: task)
        // The whole correction — reinforce +2, and SUBTRACT from the displaced
        // learned belief when (and only when) it was engine-ranked — is ONE
        // operator call (reviewer B9: the mistaken association used to keep its
        // counts and keep winning on sibling surfaces, so the user had to
        // correct each one individually). A displaced pin/prime/sticky isn't a
        // count problem, so its target is not passed to the operator.
        learning.correct(signal, to: .task(task), weight: 2,
                         displacingRanked: rankedDisplaced(displaced),
                         disabledRecipes: disabledSiteRecipes)
    }

    /// The displaced belief to subtract against, or nil: a correction only
    /// discounts a belief the ENGINE ranked (`.ranked`); a human's earlier
    /// word, a pin or a prime is not evidence to subtract against. The
    /// Attributor's single decision point for the operator's discount arm, so
    /// confirm and assign can never disagree on it.
    private func rankedDisplaced(
        _ displaced: (target: Target, source: AttributionExplanation.Source)?) -> Target? {
        (displaced?.source == .ranked) ? displaced?.target : nil
    }

    /// Remember this surface → task as a soft prime, clearing any stale pending
    /// prime for the same surface. The prime side of a correction; the count
    /// side goes through `LearningStore.correct` / `learn`.
    private func primeSurface(_ signal: ActivitySignal, to task: TaskRef) {
        let surface = Surface(signal: signal)
        primedSurfaces[surface] = task
        if pendingPrime?.surface == surface { pendingPrime = nil }
    }

    /// Weighted soft prime (caps 0.95). The why-panel Boost drives it heavier.
    /// A pure reinforce with NO discount arm — the +4 boost gesture deliberately
    /// does not subtract from a displaced ranked belief the way a +2 confirm
    /// does (attribution-learning spec §Open decisions 3, "boost symmetry": an
    /// owner call, left as-is here).
    package func learnSurface(_ signal: ActivitySignal, to task: TaskRef, weight: Double) {
        primeSurface(signal, to: task)
        learning.learn(signal, target: .task(task), weight: weight,
                       disabledRecipes: disabledSiteRecipes)
    }

    /// Review-window or prompt assignment. Always a SOFT prime (caps at
    /// 0.95) — explicit 100 % pinning goes through `pin`. `.doNotTrack`
    /// arrives here only from the timeline's deliberate "Don't track this"
    /// (`markSessionDoNotTrack`); the review drawer's Clear never teaches,
    /// so it never calls this (Target.teachesAttributor, 2026-07-10).
    /// A durable email rule is no longer written here either (2026-07-03 spec
    /// §5.4) — see `confirm` (including its `tasks` note).
    package func assign(_ signal: ActivitySignal, target: Target,
                       tasks: [WorkTask] = [], now: Date = Date()) {
        let displaced = recordDisplaced(signal, by: target, tasks: tasks, now: now)
        recordSticky(signal, target: target, now: now)
        let surface = Surface(signal: signal)
        if case .task(let t) = target {
            primedSurfaces[surface] = t
        } else {
            primedSurfaces[surface] = nil
        }
        if pendingPrime?.surface == surface { pendingPrime = nil }
        // One operator call: reinforce +2, subtract from the displaced belief
        // only when it was engine-ranked (B9). Same correction as `confirm`.
        learning.correct(signal, to: target, weight: 2,
                         displacingRanked: rankedDisplaced(displaced),
                         disabledRecipes: disabledSiteRecipes)
    }

    /// Add or update a pin (by id). New pins go last → most recent for ties.
    package func upsert(_ pin: Pin) {
        if let i = pins.firstIndex(where: { $0.id == pin.id }) {
            pins.remove(at: i)
        }
        pins.append(pin)
    }

    /// Lift a pin by id (the popover badge's ✕).
    package func unpin(id: UUID) {
        pins.removeAll { $0.id == id }
    }

    /// The winning pin covering this signal: most specific wins — manual
    /// priority first, then leaf count, then most-recently-added (array order).
    package func matchingPin(for signal: ActivitySignal) -> Pin? {
        let candidates = pins.enumerated().filter { $0.element.matches(signal) }
        return candidates.max { a, b in
            let (pa, pb) = (a.element.priority ?? 0, b.element.priority ?? 0)
            if pa != pb { return pa < pb }
            // Specificity only breaks ties between LIKE kinds — prefix.count and
            // leafCount aren't commensurable. Across kinds, fall through to
            // recency rather than pretending one is "more specific".
            if a.element.rule.sameKind(as: b.element.rule),
               a.element.rule.specificity != b.element.rule.specificity {
                return a.element.rule.specificity < b.element.rule.specificity
            }
            return a.offset < b.offset   // later in the array = more recent
        }?.element
    }

    /// Does this task belong to the URL-hinted project? Matches the stable
    /// project id exactly, or the slugified project title (OP slugs are
    /// usually the kebab-cased title).
    package static func projectMatches(task: WorkTask, hint: String) -> Bool {
        if let id = task.projectID, id == hint { return true }
        guard let title = task.project else { return false }
        return Self.slugified(title) == hint.lowercased()
    }

    /// Lowercase, non-alphanumerics → "-", collapsed and trimmed — OP's
    /// default identifier shape for a title.
    package static func slugified(_ title: String) -> String {
        var out = ""
        var lastDash = true
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    private func scored(_ signal: ActivitySignal, tasks: [WorkTask], now: Date) -> [Candidate] {
        scoredComponents(signal, tasks: tasks, now: now)
            .map { Candidate(target: $0.target, score: $0.score) }
    }

    /// The ranked candidates with their score split into the learned and the
    /// prior contribution — the data behind both `scored()` and `explain()`.
    private func scoredComponents(_ signal: ActivitySignal, tasks: [WorkTask],
                                  now: Date) -> [AttributionExplanation.Line] {
        // A transiently EMPTY task list (startup, backend refresh, re-auth)
        // must not auto-stop the clock: softmax over the lone doNotTrack
        // candidate returns 1.0 for ANY signal (reviewer B6). No candidates,
        // no confidence.
        guard !tasks.isEmpty else {
            return [.init(target: .doNotTrack, score: 0, learned: 0, prior: 0)]
        }
        let targets = tasks.map { Target.task($0.ref) } + [.doNotTrack]
        let learned = learning.isEmpty ? [:] : learning.scores(for: signal, among: targets,
                                                               disabledRecipes: disabledSiteRecipes)
        let priors = tasks.map { ranker.score($0, at: now, learning: learning,
                                              calendarMatch: currentCalendarMatch) }
        let maxPrior = max(priors.max() ?? 1, 0.001)
        // On a backend PROJECT page without a task id, trust the ranking
        // outright (spec: "most appropriate task in that project"); other
        // backend pages (My time tracking, admin, ...) must not hijack
        // attribution.
        let pageURL = signal.tabURL.flatMap(URL.init(string:))
        let onProjectPage = pageURL.map(recognizer.isProjectPage) == true
        // Scope the project-page boost to THAT project's tasks when the URL
        // names one (OP slug): "most appropriate task in that project", not
        // "any task anywhere". A slug matching no cached project keeps the
        // old everyone-boosted behaviour (we may simply not know it yet).
        let hint = onProjectPage ? pageURL.flatMap { recognizer.projectHint(in: $0) } : nil
        let hintMatchesSomeTask = hint.map { h in
            tasks.contains { Self.projectMatches(task: $0, hint: h) }
        } ?? false
        var out: [AttributionExplanation.Line] = []
        for (task, prior) in zip(tasks, priors) {
            let inHintedProject = hint.map { Self.projectMatches(task: task, hint: $0) } ?? false
            let priorWeight: Double = onProjectPage
                ? ((hintMatchesSomeTask && !inHintedProject) ? 0.2 : 0.65)
                : 0.2
            let learnedPart = 0.7 * (learned[.task(task.ref)] ?? 0)
            let priorPart = priorWeight * prior / maxPrior
            // The calendar term's share of priorPart, surfaced separately so
            // the Evidence Card can say "boosted because <event> is on now"
            // without ever claiming a boost that didn't happen.
            let calendarRaw: Double = {
                guard let m = currentCalendarMatch, m.task == task.ref else { return 0 }
                return CalendarWeight.weight * (m.tentative ? CalendarWeight.tentativeFactor : 1.0)
            }()
            let calendarPart = priorWeight * calendarRaw / maxPrior
            // Ranked cap AND a floor at 0: `priorPart` can go negative (the
            // others'-task −10 ranking penalty flows through here), but a
            // penalty is a sort key, not a confidence — no candidate may
            // journal a negative certainty (spec §floor / P2).
            out.append(.init(target: .task(task.ref),
                             score: max(0, min(Self.rankedCeiling, learnedPart + priorPart)),
                             learned: learnedPart, prior: priorPart, calendarPart: calendarPart))
        }
        let dntLearned = 0.7 * (learned[.doNotTrack] ?? 0)
        out.append(.init(target: .doNotTrack, score: dntLearned, learned: dntLearned, prior: 0))
        return out.sorted { $0.score > $1.score }
    }

    /// Why this signal WOULD attribute the way it does against the CURRENT
    /// stores. Mirrors `attribute()`'s source order exactly — but it is a
    /// re-derivation, not a record: for a journalled slice, rules learned
    /// since the decision can make this name a task that never fired there
    /// (see `AttributionExplanation.contradicts(recorded:)` — the caller
    /// holding a recorded outcome must reconcile against it). Read-only:
    /// never bumps fire counts, never prunes stickies.
    package func explain(_ signal: ActivitySignal, tasks: [WorkTask],
                        now: Date) -> AttributionExplanation {
        let feats = LearningStore.features(from: signal, disabledRecipes: disabledSiteRecipes)
            .map { "\($0.kind.rawValue)=\($0.value)" }
        if let pin = matchingPin(for: signal) {
            return .init(source: .pin, chosen: .task(pin.task), chosenScore: 1.0,
                         lines: [], features: feats, matchedPin: pin)
        }
        if let sticky = stickyLookup(for: signal, now: now) {
            return .init(source: .sessionSticky, chosen: sticky.target,
                         chosenScore: Self.inferredCeiling,
                         lines: scoredComponents(signal, tasks: tasks, now: now),
                         features: feats,
                         priorToCorrection: displacedByCorrection[sticky.key])
        }
        if let url = signal.tabURL, recognizer.taskRef(inURL: url) != nil {
            return .init(source: .opTaskURL, chosen: bestURLTarget(signal), chosenScore: Self.inferredCeiling,
                         lines: [], features: feats)
        }
        for text in [signal.windowTitle, signal.app].compactMap({ $0 }) {
            if let ref = recognizer.taskRef(inTitle: text) {
                return .init(source: .opTaskTitle, chosen: .task(ref), chosenScore: Self.inferredCeiling,
                             lines: [], features: feats)
            }
        }
        if let rule = emailRuleMatch(signal) {
            return .init(source: .emailRule, chosen: .task(rule.target), chosenScore: Self.inferredCeiling,
                         lines: scoredComponents(signal, tasks: tasks, now: now), features: feats,
                         matchedEmailRule: rule)
        }
        if let rule = siteRuleMatch(signal) {
            return .init(source: .siteRule, chosen: .task(rule.target), chosenScore: Self.inferredCeiling,
                         lines: scoredComponents(signal, tasks: tasks, now: now), features: feats,
                         matchedSiteRule: rule)
        }
        let lines = scoredComponents(signal, tasks: tasks, now: now)
        let surface = Surface(signal: signal)
        if let pending = pendingPrime, pending.surface == surface,
           now.timeIntervalSince(pending.at) <= Self.pendingPrimeTTL {
            return .init(source: .pendingPrime, chosen: .task(pending.task),
                         chosenScore: Self.pendingPrimeScore,
                         lines: lines, features: feats, matchedSurface: surface)
        }
        if let primed = primedSurfaces[surface] {
            return .init(source: .primedSurface, chosen: .task(primed),
                         chosenScore: Self.inferredCeiling,
                         lines: lines, features: feats, matchedSurface: surface)
        }
        return .init(source: lines.isEmpty ? .none : .ranked, chosen: lines.first?.target,
                     chosenScore: lines.first?.score ?? 0, lines: lines, features: feats,
                     ambiguousSurface: hostIsUnknown(signal))
    }

    private func bestURLTarget(_ signal: ActivitySignal) -> Target? {
        guard let url = signal.tabURL,
              let ref = recognizer.taskRef(inURL: url) else { return nil }
        return .task(ref)
    }

    // MARK: - Un-learn (the Evidence Card's [✕ forget])

    /// The one LEARNED thing that drove an attribution — the four stores the
    /// 2026-07-03 diagnosis names. Pins and OP-URL recognition are absent by
    /// design: they aren't learned (pins are lifted via the pin editor), and a
    /// pinned EmailRule counts as a pin for this purpose.
    package enum Unlearn: Equatable, Sendable {
        case emailRule(EmailRule)
        case siteRule(SiteRule)
        case primedSurface(Surface)
        case sessionSticky(SessionSticky.Key)
        /// Learned association weight. Weights can't be deleted, only
        /// suppressed (the counts on the signal's features are erased) — the
        /// UI says "suppress" there, honestly.
        case rankedAssociation(Target)
    }

    /// What [✕ forget] would remove for this signal, or nil when nothing
    /// learned fired (pin / OP-URL / pending prime / pure-prior ranking).
    /// Mirrors `attribute()`'s ladder exactly, so the item returned is the one
    /// that actually decided.
    package func forgettable(for signal: ActivitySignal, now: Date) -> Unlearn? {
        if matchingPin(for: signal) != nil { return nil }
        // Non-mutating lookup, like explain(): a read must never prune.
        if let sticky = stickyLookup(for: signal, now: now) { return .sessionSticky(sticky.key) }
        if let url = signal.tabURL, recognizer.taskRef(inURL: url) != nil { return nil }
        for text in [signal.windowTitle, signal.app].compactMap({ $0 })
        where recognizer.taskRef(inTitle: text) != nil { return nil }
        if let rule = emailRuleMatch(signal) { return rule.pinned ? nil : .emailRule(rule) }
        if let rule = siteRuleMatch(signal) { return rule.pinned ? nil : .siteRule(rule) }
        let surface = Surface(signal: signal)
        if let pending = pendingPrime, pending.surface == surface { return nil }  // transient
        if primedSurfaces[surface] != nil { return .primedSurface(surface) }
        // Ranked: forgettable only when learned weight is actually pulling on
        // this signal — a pure-prior winner has nothing to un-learn. The
        // dominant association (largest positive counts on the signal's
        // features) is the thing the ranker is being dragged toward.
        if let dominant = learning.dominantAssociation(for: signal,
                                                       disabledRecipes: disabledSiteRecipes) {
            return .rankedAssociation(dominant)
        }
        return nil
    }

    /// Remove exactly what an Unlearn names. `signal` supplies the features a
    /// rankedAssociation suppression erases. Persist + reevaluate afterwards
    /// (the caller's job, as with every other mutation here).
    package func forget(_ u: Unlearn, signal: ActivitySignal) {
        switch u {
        case .emailRule(let rule):
            emailRules.removeAll { $0.sameRule(as: rule) }
        case .siteRule(let rule):
            siteRules.removeAll { $0.sameRule(as: rule) }
        case .primedSurface(let surface):
            primedSurfaces[surface] = nil
            if pendingPrime?.surface == surface { pendingPrime = nil }
        case .sessionSticky(let key):
            sessionStickies.removeAll { $0.key == key }
            displacedByCorrection[key] = nil   // history dies with its correction
        case .rankedAssociation(let target):
            learning.forget(target: target,
                            features: LearningStore.features(from: signal,
                                                             disabledRecipes: disabledSiteRecipes))
        }
    }

    /// Preview WITHOUT mutating: `explain()` as if `u` were removed — the
    /// card's live "would then fall back to …" line. State is snapshotted,
    /// the removal applied, the explanation taken, and everything restored.
    package func explainWithout(_ u: Unlearn, _ signal: ActivitySignal,
                               tasks: [WorkTask], now: Date) -> AttributionExplanation {
        let savedRules = emailRules
        let savedSiteRules = siteRules
        let savedPrimes = primedSurfaces
        let savedStickies = sessionStickies
        let savedLearning = learning
        let savedPending = pendingPrime
        let savedDisplaced = displacedByCorrection
        defer {
            emailRules = savedRules
            siteRules = savedSiteRules
            primedSurfaces = savedPrimes
            sessionStickies = savedStickies
            learning = savedLearning
            pendingPrime = savedPending
            displacedByCorrection = savedDisplaced
        }
        forget(u, signal: signal)
        return explain(signal, tasks: tasks, now: now)
    }

    /// What the fallback preview's OWN [✕ forget] would remove, i.e. what's
    /// forgettable after `u` is (hypothetically) gone — never mutates. Drives
    /// the Evidence Card's "forget that fallback too" affordance so the user
    /// can strip an upsetting old rule out of the escape path WITHOUT first
    /// forgetting the thing that's currently (correctly) firing.
    package func forgettableWithout(_ u: Unlearn, _ signal: ActivitySignal,
                                   now: Date) -> Unlearn? {
        let savedRules = emailRules
        let savedSiteRules = siteRules
        let savedPrimes = primedSurfaces
        let savedStickies = sessionStickies
        let savedLearning = learning
        let savedPending = pendingPrime
        let savedDisplaced = displacedByCorrection
        defer {
            emailRules = savedRules
            siteRules = savedSiteRules
            primedSurfaces = savedPrimes
            sessionStickies = savedStickies
            learning = savedLearning
            pendingPrime = savedPending
            displacedByCorrection = savedDisplaced
        }
        forget(u, signal: signal)
        return forgettable(for: signal, now: now)
    }
}

extension Attributor {
    /// Persistence/test hook: swap in a loaded LearningStore.
    package func replaceLearning(_ store: LearningStore) {
        learning = store
    }

    /// Undo hook (mirrors `replaceLearning`): wholesale sticky restore, so a
    /// snapshot-style inverse can put today's session decisions back exactly
    /// instead of approximating them with a fresh re-assert. Day-rollover
    /// pruning still applies on the next read, so restoring a snapshot can
    /// never resurrect yesterday's stickies.
    package func replaceSessionStickies(_ stickies: [SessionSticky]) {
        sessionStickies = stickies
    }
}
