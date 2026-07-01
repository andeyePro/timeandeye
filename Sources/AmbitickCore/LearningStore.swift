import Foundation

public struct Feature: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case app, titleToken, urlHost, urlPath, hourOfDay
    }
    public var kind: Kind
    public var value: String
    public init(_ kind: Kind, _ value: String) {
        self.kind = kind
        self.value = value
    }
}

/// Naive-Bayes-style association store. Counts (feature, target) co-occurrences
/// from confirmations/corrections and scores signals against candidate targets.
/// Pure value type; persist with JSONFileStore.
public struct LearningStore: Codable, Equatable, Sendable {
    private var counts: [Feature: [Target: Double]] = [:]
    private var totals: [Target: Double] = [:]

    public init() {}

    public var isEmpty: Bool { totals.isEmpty }

    public static func features(from signal: ActivitySignal,
                                calendar: Calendar = Calendar(identifier: .gregorian)) -> [Feature] {
        var out = [Feature(.app, signal.app.lowercased())]
        if let title = signal.windowTitle {
            let tokens = title.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 }
            out += Set(tokens).sorted().map { Feature(.titleToken, $0) }
        }
        if let raw = signal.tabURL, let url = URL(string: raw), let host = url.host {
            out.append(Feature(.urlHost, host))
            if let first = url.pathComponents.dropFirst().first {
                out.append(Feature(.urlPath, host + "/" + first))
            }
        }
        out.append(Feature(.hourOfDay, String(calendar.component(.hour, from: signal.timestamp))))
        return out
    }

    public mutating func learn(_ signal: ActivitySignal, target: Target, weight: Double = 1) {
        for f in Self.features(from: signal) {
            counts[f, default: [:]][target, default: 0] += weight
        }
        totals[target, default: 0] += weight
    }

    /// A correction teaches harder than a confirmation: subtract from the wrong
    /// target, add double to the right one.
    public mutating func correct(_ signal: ActivitySignal, from old: Target, to new: Target) {
        learn(signal, target: old, weight: -1)
        learn(signal, target: new, weight: 2)
    }

    /// Softmax-normalised scores (sum to 1) over `candidates` for this signal.
    public func scores(for signal: ActivitySignal, among candidates: [Target]) -> [Target: Double] {
        guard !candidates.isEmpty else { return [:] }
        let feats = Self.features(from: signal)
        var raw: [Target: Double] = [:]
        for t in candidates {
            let total = max(totals[t] ?? 0, 0)
            var logp = log(total + 1)
            for f in feats {
                let c = max(counts[f]?[t] ?? 0, 0)
                logp += log((c + 0.1) / (total + 1))
            }
            raw[t] = logp
        }
        let maxV = raw.values.max()!
        var expd: [Target: Double] = [:]
        var sum = 0.0
        for (t, v) in raw {
            let e = exp(v - maxV)
            expd[t] = e
            sum += e
        }
        return expd.mapValues { $0 / sum }
    }

    /// Fraction of a target's confirmed weight that fell in this hour
    /// (time-of-day prior for the ranker).
    public func hourAffinity(for target: Target, hour: Int) -> Double {
        let c = max(counts[Feature(.hourOfDay, String(hour))]?[target] ?? 0, 0)
        let total = max(totals[target] ?? 0, 0)
        return total > 0 ? c / total : 0
    }

    /// The learned feature *values* (of the given kinds) positively associated
    /// with `target` — the window-title tokens / hosts / apps you've confirmed
    /// while on this task. Powers learning-backed task search: a task you always
    /// do in a "voting" window has learned titleToken "voting", so typing
    /// "voting" can find it even when its OP subject never says the word. Only
    /// strictly-positive associations count, so a value corrected away drops out.
    public func learnedValues(for target: Target,
                              kinds: Set<Feature.Kind> = [.titleToken, .urlHost, .app]) -> [String] {
        var out: Set<String> = []
        for (feature, targets) in counts where kinds.contains(feature.kind) {
            if (targets[target] ?? 0) > 0 { out.insert(feature.value) }
        }
        return out.sorted()
    }
}
