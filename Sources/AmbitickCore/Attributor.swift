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

/// Turns one ActivitySignal into a ranked list of targets.
/// Source strength order (spec): OP task URL > primed surface > pending prime
/// > learned associations + priors.
public final class Attributor {
    /// Mutable so the app can apply a changed OP URL without a relaunch.
    public var instanceHost: String
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
        if let url = signal.tabURL, let id = OPURLParser.taskID(in: url, instanceHost: instanceHost) {
            lastOpenedOPTask = .op(id)
            let c = Candidate(target: .task(.op(id)), score: Self.inferredCeiling)
            return Attribution(best: c, ranked: [c])
        }
        // No URL (e.g. OP as a Chrome PWA): the WP id may be in the window
        // title — or in the app name, which PWAs set to the page title.
        for text in [signal.windowTitle, signal.app].compactMap({ $0 }) {
            if let id = OPURLParser.taskID(inTitle: text) {
                lastOpenedOPTask = .op(id)
                let c = Candidate(target: .task(.op(id)), score: Self.inferredCeiling)
                return Attribution(best: c, ranked: [c])
            }
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
        if let url = signal.tabURL, OPURLParser.taskID(in: url, instanceHost: instanceHost) != nil {
            return
        }
        for text in [signal.windowTitle, signal.app].compactMap({ $0 })
        where OPURLParser.taskID(inTitle: text) != nil {
            return   // an OP page itself never becomes a primed working surface
        }
        guard let task = lastOpenedOPTask else { return }
        lastOpenedOPTask = nil
        let surface = Surface(signal: signal)
        if primedSurfaces[surface] != task {
            pendingPrime = (surface, task)
        }
    }

    /// Explicit user confirmation (popover click + return, or any direct pick).
    public func confirm(_ signal: ActivitySignal, task: TaskRef) {
        let surface = Surface(signal: signal)
        primedSurfaces[surface] = task
        if pendingPrime?.surface == surface { pendingPrime = nil }
        learning.learn(signal, target: .task(task), weight: 2)
    }

    /// Review-window or prompt assignment, including "Do not track". Always a
    /// SOFT prime (caps at 0.95) — explicit 100 % pinning goes through `pin`.
    public func assign(_ signal: ActivitySignal, target: Target) {
        let surface = Surface(signal: signal)
        if case .task(let t) = target {
            primedSurfaces[surface] = t
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
        let targets = tasks.map { Target.task($0.ref) } + [.doNotTrack]
        let learned = learning.isEmpty ? [:] : learning.scores(for: signal, among: targets)
        let priors = tasks.map { ranker.score($0, at: now, learning: learning) }
        let maxPrior = max(priors.max() ?? 1, 0.001)
        // On an OP PROJECT page without a task id, trust the ranking outright
        // (spec: "most appropriate task in that project"); other OP pages
        // (My time tracking, admin, ...) must not hijack attribution.
        let opURL = signal.tabURL.flatMap(URL.init(string:))
        let onOPProjectPage = opURL?.host == instanceHost
            && opURL?.path.contains("/projects/") == true
        let priorWeight = onOPProjectPage ? 0.65 : 0.2
        var out: [Candidate] = []
        for (task, prior) in zip(tasks, priors) {
            let l = learned[.task(task.ref)] ?? 0
            out.append(Candidate(target: .task(task.ref),
                                 score: min(0.9, 0.7 * l + priorWeight * prior / maxPrior)))
        }
        out.append(Candidate(target: .doNotTrack, score: 0.7 * (learned[.doNotTrack] ?? 0)))
        return out.sorted { $0.score > $1.score }
    }
}

extension Attributor {
    /// Persistence/test hook: swap in a loaded LearningStore.
    public func replaceLearning(_ store: LearningStore) {
        learning = store
    }
}
