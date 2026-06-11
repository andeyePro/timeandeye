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

    public init(instanceHost: String, learning: LearningStore = LearningStore(),
                ranker: TaskRanker = TaskRanker()) {
        self.instanceHost = instanceHost
        self.learning = learning
        self.ranker = ranker
    }

    public func attribute(_ signal: ActivitySignal, tasks: [WorkTask], now: Date) -> Attribution {
        if let url = signal.tabURL, let id = OPURLParser.taskID(in: url, instanceHost: instanceHost) {
            lastOpenedOPTask = .op(id)
            let c = Candidate(target: .task(.op(id)), score: 0.99)
            return Attribution(best: c, ranked: [c])
        }
        // No URL (e.g. OP as a Chrome PWA): the WP id may be in the window
        // title — or in the app name, which PWAs set to the page title.
        for text in [signal.windowTitle, signal.app].compactMap({ $0 }) {
            if let id = OPURLParser.taskID(inTitle: text) {
                lastOpenedOPTask = .op(id)
                let c = Candidate(target: .task(.op(id)), score: 0.97)
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

    /// Review-window or prompt assignment, including "Do not track".
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
