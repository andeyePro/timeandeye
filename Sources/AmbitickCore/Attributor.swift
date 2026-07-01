import Foundation

public struct Candidate: Equatable, Sendable {
    public var target: Target
    public var score: Double
    public init(target: Target, score: Double) {
        self.target = target
        self.score = score
    }
}

public struct Attribution: Equatable, Sendable {
    public var best: Candidate?
    public var ranked: [Candidate]
    public var certainty: Double { best?.score ?? 0 }
    public init(best: Candidate?, ranked: [Candidate]) {
        self.best = best
        self.ranked = ranked
    }
}

/// A human-readable account of WHY a signal attributed to a target — the
/// timeline "why was this tracked as X?" view. Mirrors `attribute()` exactly so
/// the explanation can never disagree with the real decision.
public struct AttributionExplanation: Equatable, Sendable {
    public enum Source: String, Sendable, Equatable {
        case pin                 // an explicit user pin (100%)
        case opTaskURL           // a work-package URL in the tab
        case opTaskTitle         // a work-package id in the window title / app
        case emailRule           // a learned email correspondent/domain/subject → task rule
        case pendingPrime        // a just-opened OP task priming the next surface
        case primedSurface       // a remembered surface→task (a past correction)
        case ranked              // learned associations + status/recency priors
        case none
    }
    /// One candidate task and how its score broke down (learned vs prior).
    public struct Line: Equatable, Sendable {
        public var target: Target
        public var score: Double
        public var learned: Double   // contribution from learned associations
        public var prior: Double     // contribution from status/recency/time-of-day
        public init(target: Target, score: Double, learned: Double, prior: Double) {
            self.target = target; self.score = score; self.learned = learned; self.prior = prior
        }
    }
    public var source: Source
    public var chosen: Target?
    public var chosenScore: Double
    /// Ranked alternatives with their score breakdown (empty for pin/OP sources,
    /// where the decision bypasses scoring).
    public var lines: [Line]
    /// The signal features the learner keys on (e.g. "app=chrome",
    /// "title=insurance") — what you'd correct to change the outcome.
    public var features: [String]
    public init(source: Source, chosen: Target?, chosenScore: Double,
                lines: [Line], features: [String]) {
        self.source = source; self.chosen = chosen; self.chosenScore = chosenScore
        self.lines = lines; self.features = features
    }
}

/// Turns one ActivitySignal into a ranked list of targets.
/// Source strength order (spec): OP task URL > primed surface > pending prime
/// > learned associations + priors.
public final class Attributor {
    /// Mutable so the app can apply a changed OP URL without a relaunch.
    public var instanceHost: String
    /// Override for non-OP backends; nil = the default OP recognizer built
    /// from `instanceHost`. Standalone: `NoPageRecognizer()`.
    public var customRecognizer: BackendPageRecognizer?
    private var recognizer: BackendPageRecognizer {
        customRecognizer ?? OPPageRecognizer(instanceHost: instanceHost)
    }
    public private(set) var learning: LearningStore
    private let ranker: TaskRanker

    private var lastOpenedOPTask: TaskRef?
    private var pendingPrime: (surface: Surface, task: TaskRef)?
    /// Public so the app can persist and restore it across launches —
    /// losing primed associations on relaunch dropped session certainty
    /// below the push threshold (found 2026-06-11).
    public var primedSurfaces: [Surface: TaskRef] = [:]
    /// Explicit user pins. EVERYTHING unpinned caps at 0.95; a pin is the only
    /// thing that returns 1.0, and it overrides the ranker, learning, soft
    /// primes and even a work-package URL. Each pin carries a rule (component
    /// prefix or boolean expression). Set only by the explicit pin editor,
    /// never by an ordinary correction (those stay soft primes). When several
    /// match, the most specific wins (manual `priority` first, then leaf count,
    /// then most-recently-added). See `Pin` / `PinRule`.
    public var pins: [Pin] = []
    /// Learned email correspondent→task rules (the auto-learner's deterministic
    /// ladder). Populated by corrections on email surfaces; matched most-specific
    /// first per `emailMatchOrder`. Caps at 0.95 like any inferred source.
    public var emailRules: [EmailRule] = []
    /// The user-editable specificity order the email ladder resolves through
    /// (mirrors the setting; defaults general→specific).
    public var emailMatchOrder: [EmailMatchLevel] = EmailMatchLevel.defaultOrder

    public init(instanceHost: String, learning: LearningStore = LearningStore(),
                ranker: TaskRanker = TaskRanker()) {
        self.instanceHost = instanceHost
        self.learning = learning
        self.ranker = ranker
    }

    /// Inferred certainty ceiling: everything that isn't an explicit pin tops
    /// out here. 1.0 is reserved for "the user told me outright" (a pin).
    public static let inferredCeiling = 0.95

    public func attribute(_ signal: ActivitySignal, tasks: [WorkTask], now: Date) -> Attribution {
        // An explicit pin is law: it wins over a work-package URL and the
        // ranker alike. Alternatives still rank beneath it for the switch-list.
        if let pin = matchingPin(for: signal) {
            var ranked = scored(signal, tasks: tasks, now: now)
            ranked.removeAll { $0.target == .task(pin.task) }
            let c = Candidate(target: .task(pin.task), score: 1.0)
            ranked.insert(c, at: 0)
            return Attribution(best: c, ranked: ranked)
        }
        if let url = signal.tabURL, let id = recognizer.taskID(inURL: url) {
            lastOpenedOPTask = .op(id)
            let c = Candidate(target: .task(.op(id)), score: Self.inferredCeiling)
            return Attribution(best: c, ranked: [c])
        }
        // No URL (e.g. OP as a Chrome PWA): the WP id may be in the window
        // title — or in the app name, which PWAs set to the page title.
        for text in [signal.windowTitle, signal.app].compactMap({ $0 }) {
            if let id = recognizer.taskID(inTitle: text) {
                lastOpenedOPTask = .op(id)
                let c = Candidate(target: .task(.op(id)), score: Self.inferredCeiling)
                return Attribution(best: c, ranked: [c])
            }
        }
        // A learned email rule (correspondent / domain / subject → task) outranks
        // the soft primes and the ranker — you've effectively taught "mail from X
        // is task Y". Still an inferred source, so it caps at 0.95, below a pin /
        // OP-URL.
        if let rule = emailRuleMatch(signal) {
            var ranked = scored(signal, tasks: tasks, now: now)
            ranked.removeAll { $0.target == .task(rule.target) }
            let c = Candidate(target: .task(rule.target), score: Self.inferredCeiling)
            ranked.insert(c, at: 0)
            return Attribution(best: c, ranked: ranked)
        }
        let surface = Surface(signal: signal)
        var ranked = scored(signal, tasks: tasks, now: now)
        if let pending = pendingPrime, pending.surface == surface {
            ranked.removeAll { $0.target == .task(pending.task) }
            ranked.insert(Candidate(target: .task(pending.task), score: 0.7), at: 0)
        } else if let primed = primedSurfaces[surface] {
            ranked.removeAll { $0.target == .task(primed) }
            ranked.insert(Candidate(target: .task(primed), score: 0.95), at: 0)
        }
        return Attribution(best: ranked.first, ranked: ranked)
    }

    /// SessionTracker calls this when a surface has held focus beyond the
    /// prime-dwell threshold. Consumes lastOpenedOPTask ("immediately following").
    public func noteDwell(_ signal: ActivitySignal) {
        if let url = signal.tabURL, recognizer.taskID(inURL: url) != nil {
            return
        }
        for text in [signal.windowTitle, signal.app].compactMap({ $0 })
        where recognizer.taskID(inTitle: text) != nil {
            return   // an OP page itself never becomes a primed working surface
        }
        guard let task = lastOpenedOPTask else { return }
        lastOpenedOPTask = nil
        let surface = Surface(signal: signal)
        if primedSurfaces[surface] != task {
            pendingPrime = (surface, task)
        }
    }

    /// The learned email rule covering this signal, if any (nil for non-email
    /// surfaces or when no rule matches).
    public func emailRuleMatch(_ signal: ActivitySignal) -> EmailRule? {
        guard !emailRules.isEmpty, let ctx = EmailContext.from(signal) else { return nil }
        return EmailMatcher.match(ctx, rules: emailRules, order: emailMatchOrder)
    }

    /// Shared webmail domains carry no task meaning (everyone is @gmail.com), so a
    /// correction there learns the specific CORRESPONDENT, not the domain.
    static let sharedWebmailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "yahoo.com", "ymail.com", "icloud.com", "me.com", "aol.com", "proton.me",
        "protonmail.com", "gmx.com", "mail.com",
    ]

    /// Conservatively learn an email rule from a correction: an org domain
    /// generalises to the whole company; a shared-webmail correspondent stays
    /// per-person. Replaces any existing rule with the same level+value.
    public func learnEmailRule(_ signal: ActivitySignal, to task: TaskRef) {
        guard let ctx = EmailContext.from(signal), let cp = ctx.correspondents.first else { return }
        let level: EmailMatchLevel
        let value: String
        if let domain = EmailSignal.domain(of: cp), !Self.sharedWebmailDomains.contains(domain) {
            level = .correspondentDomain; value = domain
        } else {
            level = .correspondent; value = cp
        }
        emailRules.removeAll { $0.level == level && $0.value.caseInsensitiveCompare(value) == .orderedSame && !$0.pinned }
        emailRules.append(EmailRule(level: level, value: value, target: task))
    }

    /// Explicit user confirmation (popover click + return, or any direct pick).
    public func confirm(_ signal: ActivitySignal, task: TaskRef) {
        learnSurface(signal, to: task, weight: 2)
        learnEmailRule(signal, to: task)
    }

    /// Weighted soft prime (caps 0.95). The why-panel Boost drives it heavier.
    public func learnSurface(_ signal: ActivitySignal, to task: TaskRef, weight: Double) {
        let surface = Surface(signal: signal)
        primedSurfaces[surface] = task
        if pendingPrime?.surface == surface { pendingPrime = nil }
        learning.learn(signal, target: .task(task), weight: weight)
    }

    /// Review-window or prompt assignment, including "Do not track". Always a
    /// SOFT prime (caps at 0.95) — explicit 100 % pinning goes through `pin`.
    public func assign(_ signal: ActivitySignal, target: Target) {
        let surface = Surface(signal: signal)
        if case .task(let t) = target {
            primedSurfaces[surface] = t
            learnEmailRule(signal, to: t)
        } else {
            primedSurfaces[surface] = nil
        }
        if pendingPrime?.surface == surface { pendingPrime = nil }
        learning.learn(signal, target: target, weight: 2)
    }

    /// Add or update a pin (by id). New pins go last → most recent for ties.
    public func upsert(_ pin: Pin) {
        if let i = pins.firstIndex(where: { $0.id == pin.id }) {
            pins.remove(at: i)
        }
        pins.append(pin)
    }

    /// Lift a pin by id (the popover badge's ✕).
    public func unpin(id: UUID) {
        pins.removeAll { $0.id == id }
    }

    /// The winning pin covering this signal: most specific wins — manual
    /// priority first, then leaf count, then most-recently-added (array order).
    public func matchingPin(for signal: ActivitySignal) -> Pin? {
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

    private func scored(_ signal: ActivitySignal, tasks: [WorkTask], now: Date) -> [Candidate] {
        scoredComponents(signal, tasks: tasks, now: now)
            .map { Candidate(target: $0.target, score: $0.score) }
    }

    /// The ranked candidates with their score split into the learned and the
    /// prior contribution — the data behind both `scored()` and `explain()`.
    private func scoredComponents(_ signal: ActivitySignal, tasks: [WorkTask],
                                  now: Date) -> [AttributionExplanation.Line] {
        let targets = tasks.map { Target.task($0.ref) } + [.doNotTrack]
        let learned = learning.isEmpty ? [:] : learning.scores(for: signal, among: targets)
        let priors = tasks.map { ranker.score($0, at: now, learning: learning) }
        let maxPrior = max(priors.max() ?? 1, 0.001)
        // On a backend PROJECT page without a task id, trust the ranking
        // outright (spec: "most appropriate task in that project"); other
        // backend pages (My time tracking, admin, ...) must not hijack
        // attribution.
        let onProjectPage = signal.tabURL.flatMap(URL.init(string:))
            .map(recognizer.isProjectPage) == true
        let priorWeight = onProjectPage ? 0.65 : 0.2
        var out: [AttributionExplanation.Line] = []
        for (task, prior) in zip(tasks, priors) {
            let learnedPart = 0.7 * (learned[.task(task.ref)] ?? 0)
            let priorPart = priorWeight * prior / maxPrior
            out.append(.init(target: .task(task.ref), score: min(0.9, learnedPart + priorPart),
                             learned: learnedPart, prior: priorPart))
        }
        let dntLearned = 0.7 * (learned[.doNotTrack] ?? 0)
        out.append(.init(target: .doNotTrack, score: dntLearned, learned: dntLearned, prior: 0))
        return out.sorted { $0.score > $1.score }
    }

    /// Why this signal attributes the way it does — drives the timeline's
    /// "why was this tracked as X?" panel. Mirrors `attribute()`'s source order
    /// exactly, so what it explains is what actually happened.
    public func explain(_ signal: ActivitySignal, tasks: [WorkTask],
                        now: Date) -> AttributionExplanation {
        let feats = LearningStore.features(from: signal).map { "\($0.kind.rawValue)=\($0.value)" }
        if let pin = matchingPin(for: signal) {
            return .init(source: .pin, chosen: .task(pin.task), chosenScore: 1.0,
                         lines: [], features: feats)
        }
        if let url = signal.tabURL, recognizer.taskID(inURL: url) != nil {
            return .init(source: .opTaskURL, chosen: bestURLTarget(signal), chosenScore: Self.inferredCeiling,
                         lines: [], features: feats)
        }
        for text in [signal.windowTitle, signal.app].compactMap({ $0 }) {
            if let id = recognizer.taskID(inTitle: text) {
                return .init(source: .opTaskTitle, chosen: .task(.op(id)), chosenScore: Self.inferredCeiling,
                             lines: [], features: feats)
            }
        }
        if let rule = emailRuleMatch(signal) {
            return .init(source: .emailRule, chosen: .task(rule.target), chosenScore: Self.inferredCeiling,
                         lines: scoredComponents(signal, tasks: tasks, now: now), features: feats)
        }
        let lines = scoredComponents(signal, tasks: tasks, now: now)
        let surface = Surface(signal: signal)
        if let pending = pendingPrime, pending.surface == surface {
            return .init(source: .pendingPrime, chosen: .task(pending.task), chosenScore: 0.7,
                         lines: lines, features: feats)
        }
        if let primed = primedSurfaces[surface] {
            return .init(source: .primedSurface, chosen: .task(primed), chosenScore: 0.95,
                         lines: lines, features: feats)
        }
        return .init(source: lines.isEmpty ? .none : .ranked, chosen: lines.first?.target,
                     chosenScore: lines.first?.score ?? 0, lines: lines, features: feats)
    }

    private func bestURLTarget(_ signal: ActivitySignal) -> Target? {
        guard let url = signal.tabURL,
              let id = recognizer.taskID(inURL: url) else { return nil }
        return .task(.op(id))
    }
}

extension Attributor {
    /// Persistence/test hook: swap in a loaded LearningStore.
    public func replaceLearning(_ store: LearningStore) {
        learning = store
    }
}
