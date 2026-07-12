import Foundation

package struct Feature: Hashable, Codable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case app, titleToken, urlHost, urlPath, hourOfDay
        /// Email counterparty address / its domain (2026-07-03). Sensor-observed
        /// (the capture reads them off the user's own screen), so compliant with
        /// the invariant below. Additive: existing learning.json rows decode
        /// unchanged. Inert while capture is off (signals carry nil
        /// correspondents); live the moment it returns.
        case correspondent, correspondentDomain
        /// A site-recipe identity field, value encoded
        /// "<recipeID>.<field>=<value>" ("github.repo=example-repo") — the
        /// correspondent playbook replayed (2026-07-09 site-recipes spec
        /// §5): additive, inert until a recipe matches, sensor-observed by
        /// construction (parsed from the URL/title the sensors captured).
        /// Content fields are never emitted (title tokens already cover
        /// them; a whole issue title as one feature would never repeat).
        case recipeField
        /// A kind this build doesn't know — rows written by a NEWER build
        /// decode here instead of throwing away the whole learning.json.
        /// Never emitted by `features(from:)`, so it can never match.
        case unknown

        /// Tolerant decode: an unknown rawValue (a future kind) maps to
        /// `.unknown` rather than failing the store's whole decode — the
        /// additive-migration guarantee the correspondent kinds promised,
        /// made structural.
        package init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }
    package var kind: Kind
    package var value: String
    package init(_ kind: Kind, _ value: String) {
        self.kind = kind
        self.value = value
    }
}

/// Naive-Bayes-style association store. Counts (feature, target) co-occurrences
/// from confirmations/corrections and scores signals against candidate targets.
/// Pure value type; persist with JSONFileStore.
///
/// COMPLIANCE INVARIANT (Xero T&Cs, Dec 2025: API data must never train,
/// fine-tune, adapt or enhance any AI/ML/predictive model): features derive
/// EXCLUSIVELY from sensor-observed `ActivitySignal` fields (what is on the
/// user's own screen) — backend-sourced text (task subjects, project names,
/// contacts fetched via any API) must NEVER be added as a feature. Target
/// keys hold TaskRefs (opaque ids used as class labels, i.e. references, not
/// trained-on content). Frozen by the "backend text never becomes a learned
/// feature" check.
package struct LearningStore: Codable, Equatable, Sendable {
    private var counts: [Feature: [Target: Double]] = [:]
    private var totals: [Target: Double] = [:]

    package init() {}

    package var isEmpty: Bool { totals.isEmpty }

    package static func features(from signal: ActivitySignal,
                                calendar: Calendar = Calendar(identifier: .gregorian),
                                disabledRecipes: Set<String> = []) -> [Feature] {
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
        // WHO the mail is with — the strongest task signal an email surface
        // carries, and the reason the why-panel used to show only title junk
        // (2026-07-03 diagnosis: the learner had no correspondent feature at
        // all). EmailContext already lowercases and strips self.
        if let ctx = EmailContext.from(signal) {
            out += ctx.correspondents.map { Feature(.correspondent, $0) }
            out += ctx.correspondentDomains.map { Feature(.correspondentDomain, $0) }
        }
        // WHAT the recipe'd page names — the repo/document/organisation the
        // urlPath grain (host + first segment only) can never reach
        // (site-recipes spec §5). Identity fields only: content fields never
        // become features. Fields derive from the signal's own URL/title, so
        // the compliance invariant above holds on go.xero.com pages too.
        if let site = SiteRecipes.extract(signal, disabled: disabledRecipes),
           let recipe = site.recipe {
            for field in recipe.fields where !field.isContent {
                if let value = site.values[field.name] {
                    out.append(Feature(.recipeField,
                                       "\(recipe.id).\(field.name)=\(value.lowercased())"))
                }
            }
        }
        out.append(Feature(.hourOfDay, String(calendar.component(.hour, from: signal.timestamp))))
        return out
    }

    package mutating func learn(_ signal: ActivitySignal, target: Target, weight: Double = 1,
                               disabledRecipes: Set<String> = []) {
        for f in Self.features(from: signal, disabledRecipes: disabledRecipes) {
            counts[f, default: [:]][target, default: 0] += weight
        }
        totals[target, default: 0] += weight
    }

    /// A correction teaches harder than a confirmation: subtract from the wrong
    /// target, add double to the right one.
    package mutating func correct(_ signal: ActivitySignal, from old: Target, to new: Target,
                                 disabledRecipes: Set<String> = []) {
        learn(signal, target: old, weight: -1, disabledRecipes: disabledRecipes)
        learn(signal, target: new, weight: 2, disabledRecipes: disabledRecipes)
    }

    /// Targeted un-learn (the Evidence Card's [✕ forget] for a ranked source):
    /// ERASE this target's accumulated counts on exactly these features, however
    /// large the mountain (a fixed negative weight can't dislodge months of
    /// confirmations — the 2026-07-03 "University Teaching" diagnosis).
    /// `totals` is deliberately untouched: we can't know how much of it arrived
    /// through these features, and leaving it makes the smoothing term
    /// (0.1/(total+1)) HARSHER for the erased features — exactly the suppression
    /// wanted. Learning on other features/targets is unaffected.
    package mutating func forget(target: Target, features: [Feature]) {
        for f in features {
            counts[f]?[target] = nil
            if counts[f]?.isEmpty == true { counts[f] = nil }
        }
    }

    /// Softmax-normalised scores (sum to 1) over `candidates` for this signal.
    package func scores(for signal: ActivitySignal, among candidates: [Target],
                       disabledRecipes: Set<String> = []) -> [Target: Double] {
        guard !candidates.isEmpty else { return [:] }
        let feats = Self.features(from: signal, disabledRecipes: disabledRecipes)
        var raw: [Target: Double] = [:]
        for t in candidates {
            let total = max(totals[t] ?? 0, 0)
            var logp = 0.0
            var strongMatches = 0
            for f in feats {
                let c = max(counts[f]?[t] ?? 0, 0)
                // GENERIC features (hourOfDay) are heavily down-weighted: an
                // hour coincidence must never flip attribution on its own —
                // one evening of Steam at 22:00 would otherwise make EVERY
                // 22:xx window score doNotTrack and stop the clock.
                let kindWeight = f.kind == .hourOfDay ? 0.15 : 1.0
                // Matched features use the learned likelihood; an UNMATCHED
                // feature costs a CONSTANT (its untaught-task value), not
                // log(0.1/(total+1)) — the old per-feature penalty GREW with
                // total, so a heavily-taught task lost to a never-taught one
                // on any partial match and attribution got worse with use
                // (reviewer B5). A weak match (tiny c on a huge total) can
                // still score below the constant: 1-in-1000 is genuine
                // negative evidence.
                if c > 0 {
                    if f.kind != .hourOfDay { strongMatches += 1 }
                    logp += kindWeight * log((c + 0.1) / (total + 1))
                } else {
                    logp += kindWeight * log(0.1)
                }
            }
            // The experience prior applies ONLY on a STRONG match: with
            // constant unmatched penalties, an unconditional log(total+1)
            // made any well-taught target beat untaught ones on signals it
            // knows NOTHING about. Zero strong matches = an untaught
            // target's score (± the tiny generic terms).
            if strongMatches > 0 { logp += log(total + 1) }
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

    /// The target the learned counts pull this signal toward hardest — the
    /// largest positive count total on the signal's features, nil when nothing
    /// positive is learned on them. Drives `Attributor.forgettable`'s
    /// rankedAssociation case (what a [✕ suppress] would counter-teach).
    package func dominantAssociation(for signal: ActivitySignal,
                                    disabledRecipes: Set<String> = []) -> Target? {
        var sums: [Target: Double] = [:]
        for f in Self.features(from: signal, disabledRecipes: disabledRecipes) {
            for (target, count) in counts[f] ?? [:] where count > 0 {
                sums[target, default: 0] += count
            }
        }
        return sums.max { a, b in a.value < b.value }?.key
    }

    /// Fraction of a target's confirmed weight that fell in this hour
    /// (time-of-day prior for the ranker).
    package func hourAffinity(for target: Target, hour: Int) -> Double {
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
    package func learnedValues(for target: Target,
                              kinds: Set<Feature.Kind> = [.titleToken, .urlHost, .app]) -> [String] {
        var out: Set<String> = []
        for (feature, targets) in counts where kinds.contains(feature.kind) {
            if (targets[target] ?? 0) > 0 { out.insert(feature.value) }
        }
        return out.sorted()
    }
}
