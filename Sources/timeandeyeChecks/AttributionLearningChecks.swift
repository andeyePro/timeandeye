import Foundation
import timeandeyeCore

// MARK: - The attribution LEARNING count model, pinned as PROPERTIES
// (docs/superpowers/specs/2026-07-13-attribution-learning.md). The count model
// (`LearningStore`) is the self-adapting naive-Bayes association store: every
// user gesture moves counts, and a learned score enters the certainty calculus
// at the ranked tier and no higher. Today's learning checks are all
// example-based; this suite is the moat's FIRST invariant coverage — seven
// properties (L1-L7) over generated inputs.
//
// House style (matches CertaintyCalculusChecks / PostingMachineChecks): a
// seeded, deterministic SplitMix64 drives small inline generators — no system
// RNG (a flake is a false failure) and no property-testing dependency. Where a
// producer path is a controller write not reachable from a Core check (the
// retro/contradiction auto-passes, L2), the tightest Core-level proxy is pinned
// and labelled as such in a comment.

/// Deterministic SplitMix64. Seeded, reproducible; file-private so it never
/// collides with the identically-named RNGs in the other property suites.
private struct SeededRNG {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// A value in `0..<n`.
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func bool() -> Bool { next() & 1 == 0 }
}

private let genApps = ["ghostty", "chrome", "obsidian", "xcode", "slack",
                       "mailapp", "safari", "zed"]
private let genToks = ["build", "review", "invoice", "spec", "notes", "design",
                       "report", "sync", "draft", "tests", "planner", "ledger"]
private let genHosts = ["op.example.com", "github.com", "mail.example.net", "docs.example.org"]

/// A generated activity signal with overlapping-but-varied features, at a
/// chosen hour offset from `base` (so hour-of-day can be controlled or held
/// novel). One app, 1-3 title tokens, sometimes a URL.
private func genSignal(_ r: inout SeededRNG, hourOffset: Int, base: Date) -> ActivitySignal {
    let app = genApps[r.below(genApps.count)]
    let n = 1 + r.below(3)
    var toks: [String] = []
    for _ in 0..<n { toks.append(genToks[r.below(genToks.count)]) }
    let title = toks.joined(separator: " ")
    let url: String? = r.bool()
        ? "https://\(genHosts[r.below(genHosts.count)])/\(genToks[r.below(genToks.count)])"
        : nil
    return ActivitySignal(app: app, windowTitle: title, tabURL: url,
                          timestamp: base.addingTimeInterval(Double(hourOffset) * 3600))
}

func attributionLearningChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let host = "op.example.com"
    let cal = Calendar(identifier: .gregorian)          // the calendar features() uses
    let pool: [Target] = [.task(.op(1)), .task(.op(2)), .task(.op(3)), .task(.op(4))]
    let tasks = [WorkTask(ref: .op(1), subject: "build", status: "Now"),
                 WorkTask(ref: .op(2), subject: "review", status: "Next")]

    // MARK: L1 — correction direction. After a correction to T displacing
    // ranked D, T's score does not fall and D's does not rise, for that signal.
    // The count-model correction operator is `correct(to:weight:displacingRanked:)`
    // (= learn(T,+w) then learn(D,-1) when a ranked belief is displaced);
    // production drives the same ±(2,-1) split through Attributor.confirm/assign
    // (B9) via that one operator. Generated over realistic-magnitude
    // histories (a handful of confirmations) — the regime a user actually
    // produces; the B5 "weak match on a huge total" corner is documented,
    // intended behaviour and out of this invariant's scope.
    c.check("L1: a correction raises the corrected target and lowers the displaced one (property)") {
        for seed in UInt64(1)...UInt64(40) {
            var r = SeededRNG(seed)
            let sig = genSignal(&r, hourOffset: r.below(6), base: now)
            let right = pool[r.below(pool.count)]
            var wrong = pool[r.below(pool.count)]
            while wrong == right { wrong = pool[r.below(pool.count)] }

            var store = LearningStore()
            // D (wrong) is the ranked belief: taught strictly more than the
            // corrected-to target so it currently leads that signal.
            let dTeaches = 2 + r.below(3)          // 2..4 confirmations
            for _ in 0..<dTeaches { store.learn(sig, target: wrong, weight: 2) }
            for _ in 0..<r.below(2) { store.learn(sig, target: right, weight: 2) }

            let before = store.scores(for: sig, among: pool)
            // Precondition: D actually leads (it is the belief being displaced).
            let leader = before.max { $0.value < $1.value }?.key
            guard leader == wrong else { continue }

            store.correct(sig, to: right, weight: 2, displacingRanked: wrong)
            let after = store.scores(for: sig, among: pool)

            try expect((after[right] ?? 0) >= (before[right] ?? 0) - 1e-9,
                       "seed \(seed): corrected target must not fall " +
                       "(\(before[right] ?? 0) -> \(after[right] ?? 0))")
            try expect((after[wrong] ?? 0) <= (before[wrong] ?? 0) + 1e-9,
                       "seed \(seed): displaced belief must not rise " +
                       "(\(before[wrong] ?? 0) -> \(after[wrong] ?? 0))")
        }
    }

    // MARK: L2 — no self-reinforcement. The auto-applied retro and
    // contradiction passes re-point the JOURNAL but must never teach the count
    // model. FULL form ("run applyRetroPlan/applyRefiles over a journal, store
    // byte-identical") is NOT Core-reachable: those journal writes live in
    // AppController, off the checks target. PROXY pinned here, tightest
    // available: (a) the passes' own Core decision logic — ContradictionRefile
    // .plan/.apply and RetroAcceptance.plan — plus (b) the read paths they
    // re-score with (Attributor.explain/attribute, LearningStore.scores) leave
    // the store unchanged; (c) a positive control confirms a USER gesture
    // (confirm) DOES change it. Compared by value (`LearningStore: Equatable`),
    // not encoded bytes: Swift randomises dictionary hash order per process run,
    // so byte-equality would flake; value equality is order-independent.
    c.check("L2: the retro/contradiction re-score passes never teach the count model (Core proxy)") {
        for seed in UInt64(1)...UInt64(16) {
            var r = SeededRNG(seed)
            let a = Attributor(instanceHost: host)
            var store = LearningStore()
            // A realistic populated store to run the read paths against.
            for _ in 0..<(4 + r.below(6)) {
                let s = genSignal(&r, hourOffset: r.below(6), base: now)
                store.learn(s, target: pool[r.below(pool.count)], weight: 2)
            }
            a.replaceLearning(store)
            let snapshot = a.learning              // value copy — compared by content

            // Build a journal-like set of sessions + review rows.
            var sessions: [Session] = []
            var segments: [ReviewSegment] = []
            for _ in 0..<(3 + r.below(4)) {
                let s = genSignal(&r, hourOffset: r.below(6), base: now)
                let start = s.timestamp
                sessions.append(Session(task: .op(1 + r.below(4)), start: start,
                                        end: start.addingTimeInterval(300),
                                        certainty: Double(r.below(100)) / 100.0))
                segments.append(ReviewSegment(app: s.app, windowTitle: s.windowTitle,
                                              tabURL: s.tabURL, start: start,
                                              end: start.addingTimeInterval(120)))
            }

            // The read paths the auto-passes re-score through.
            for seg in segments {
                _ = a.explain(seg.signal, tasks: tasks, now: now)
                _ = a.attribute(seg.signal, tasks: tasks, now: now)
                _ = a.learning.scores(for: seg.signal, among: pool)
            }
            // The passes' actual Core decision logic (neither takes nor returns
            // a LearningStore — there is no store-write seam in them at all).
            let refile = ContradictionRefile.plan(
                sessions: sessions, bar: 0.8, suggestFloor: 0.5, dismissed: []) { sess in
                    let e = a.explain(ReviewSegment(app: sess.task.fallbackLabel, start: sess.start,
                                                    end: sess.end).signal, tasks: tasks, now: now)
                    guard let chosen = e.chosen else { return nil }
                    return (chosen, e.chosenScore)
                }
            for finding in refile.refiles + refile.suggestions {
                if let sess = sessions.first(where: { $0.id == finding.sessionID }) {
                    _ = ContradictionRefile.apply(finding, to: sess)
                }
            }
            _ = RetroAcceptance.plan(pending: segments, sessions: sessions, bar: 0.8) { sig in
                let e = a.explain(sig, tasks: tasks, now: now)
                guard let chosen = e.chosen else { return nil }
                return (chosen, e.chosenScore)
            }

            try expect(a.learning == snapshot,
                       "seed \(seed): auto re-score passes must leave the count model unchanged")

            // Positive control: a USER gesture teaches (so the check above is
            // pinning silence, not an inert store).
            a.confirm(genSignal(&r, hourOffset: r.below(6), base: now), task: .op(1),
                      tasks: tasks, now: now)
            try expect(a.learning != snapshot,
                       "seed \(seed): a user confirm MUST change the store")
        }
    }

    // MARK: L3 — tier-independence. Confirming a low-certainty vs a
    // high-certainty decision produces identical count deltas: certainty is not
    // an input to the teach primitive (confirm always writes +2). Pinned by
    // confirming the SAME winning S->T from the SAME base store under two
    // candidate contexts that genuinely differ in the decision's certainty — a
    // fresh high-prior decoy in the wide context raises maxPrior and so lowers
    // T's normalised prior share (its certainty), without ever winning (it is
    // untaught) and without changing what is taught. T stays the winner in both,
    // so nothing is displaced/subtracted and the write is a clean +2. Counts are
    // private, so the delta is compared by byte-equality of the resulting stores
    // — the tightest observable pin (`scores`/`hourAffinity` are relative/ratio
    // reads and cannot expose an absolute +2). NB: a global `now` shift would
    // decay every candidate equally and leave relative priors — hence certainty
    // — unchanged, so certainty is moved via the candidate set, not the clock.
    c.check("L3: the count delta of a confirm is independent of the decision's certainty") {
        for seed in UInt64(1)...UInt64(16) {
            var r = SeededRNG(seed)
            let sig = genSignal(&r, hourOffset: r.below(6), base: now)
            let T = TaskRef.op(1)
            let D = TaskRef.op(2)
            var base = LearningStore()
            for _ in 0..<(2 + r.below(3)) { base.learn(sig, target: .task(T), weight: 2) }

            let ctxNarrow = [WorkTask(ref: T, subject: "t", status: "Next"),
                             WorkTask(ref: D, subject: "d", status: "Next")]
            // The decoy: fresh + "Now" status, so it dominates the prior and
            // rescales T's prior share, but is untaught so it can never win.
            let ctxWide = ctxNarrow + [WorkTask(ref: .op(3), subject: "e", status: "Now",
                                                lastConfirmedAt: now)]

            let a1 = Attributor(instanceHost: host); a1.replaceLearning(base)
            let a2 = Attributor(instanceHost: host); a2.replaceLearning(base)
            let e1 = a1.explain(sig, tasks: ctxNarrow, now: now)
            let e2 = a2.explain(sig, tasks: ctxWide, now: now)
            try expect(e1.chosen == .task(T) && e2.chosen == .task(T),
                       "seed \(seed): T wins in both contexts (nothing else is displaced)")
            try expect(abs(e1.chosenScore - e2.chosenScore) > 1e-6,
                       "seed \(seed): premise — the two decisions must differ in certainty " +
                       "(\(e1.chosenScore) vs \(e2.chosenScore))")

            a1.confirm(sig, task: T, tasks: ctxNarrow, now: now)
            a2.confirm(sig, task: T, tasks: ctxWide, now: now)
            // Value equality (`LearningStore: Equatable`), order-independent.
            try expect(a1.learning == a2.learning,
                       "seed \(seed): identical count delta despite differing certainty")
        }
    }

    // MARK: L4 — cold start. An empty store contributes no learned part
    // (priors-only attribution); a populated store facing an untaught signal
    // scores near-uniform, so the biggest `totals` can't run away with the
    // decision. A signal that strong-matches NOTHING has every candidate's raw
    // equal (constant unmatched penalty, experience prior gated off), so the
    // softmax is EXACTLY uniform — the sharpest form of "near-uniform".
    c.check("L4: an empty store is priors-only; an untaught signal scores exactly uniform") {
        let empty = LearningStore()
        try expect(empty.isEmpty, "a fresh store is empty (the flag the Attributor gates [:] on)")
        try expect(empty.scores(for: tasks[0].ref == .op(1)
                                    ? ActivitySignal(app: "x", timestamp: now)
                                    : ActivitySignal(app: "x", timestamp: now),
                                among: []).isEmpty,
                   "scores over no candidates is empty")
        // The Attributor-level empty->priors-only contract: learned part is 0.
        let coldA = Attributor(instanceHost: host)          // no learning
        let cold = coldA.explain(ActivitySignal(app: "ghostty", windowTitle: "anything", timestamp: now),
                                 tasks: tasks, now: now)
        try expect(!cold.lines.isEmpty, "candidates are scored")
        try expect(cold.lines.allSatisfy { abs($0.learned) < 1e-9 },
                   "an empty store adds no learned part — the decision is pure priors")

        for seed in UInt64(1)...UInt64(30) {
            var r = SeededRNG(seed)
            var store = LearningStore()
            // Populate, always at hours 0..5 with the normal feature pools.
            for _ in 0..<(5 + r.below(6)) {
                store.learn(genSignal(&r, hourOffset: r.below(6), base: now),
                            target: pool[r.below(pool.count)], weight: 2)
            }
            // A wholly novel signal: novel app/token vocabulary AND an hour (12)
            // never taught, so it strong-matches nothing and the hour feature
            // is unmatched too.
            let novel = ActivitySignal(app: "novelapp-\(seed)",
                                       windowTitle: "zzq\(seed) qzz\(seed)",
                                       timestamp: now.addingTimeInterval(12 * 3600))
            let scores = store.scores(for: novel, among: pool)
            let vals = scores.values
            try expect((vals.max() ?? 0) - (vals.min() ?? 0) < 1e-9,
                       "seed \(seed): an untaught signal must score uniform, not lean to biggest totals")
            try expectClose(vals.reduce(0, +), 1.0, "distribution sums to 1")
        }
    }

    // MARK: L5 — generalization. A correction on signal X raises the corrected
    // target for a different signal Y that shares at least one feature, and
    // leaves a signal Z that shares none unmoved. X, Y share exactly one
    // titleToken; Z is feature-disjoint from X (different app, tokens, hour), so
    // Z sits at the cold-start uniform before and after — genuinely unmoved.
    c.check("L5: a correction generalizes to a feature-sharing signal, not to a disjoint one") {
        for seed in UInt64(1)...UInt64(30) {
            let tok = "gen\(seed)"                            // >=3 chars, shared by X and Y
            let X = ActivitySignal(app: "appx", windowTitle: "\(tok) alpha",
                                   timestamp: now.addingTimeInterval(1 * 3600))
            let Y = ActivitySignal(app: "appy", windowTitle: "\(tok) bravo",
                                   timestamp: now.addingTimeInterval(2 * 3600))
            let Z = ActivitySignal(app: "appz", windowTitle: "charlie delta",
                                   timestamp: now.addingTimeInterval(3 * 3600))
            let T: Target = .task(.op(1))

            var store = LearningStore()
            let beforeY = store.scores(for: Y, among: pool)
            let beforeZ = store.scores(for: Z, among: pool)
            store.learn(X, target: T, weight: 2)             // the only teach

            let afterY = store.scores(for: Y, among: pool)
            let afterZ = store.scores(for: Z, among: pool)
            try expect((afterY[T] ?? 0) > (beforeY[T] ?? 0) + 1e-9,
                       "seed \(seed): Y sharing a feature must inherit the corrected target " +
                       "(\(beforeY[T] ?? 0) -> \(afterY[T] ?? 0))")
            try expect(afterZ == beforeZ,
                       "seed \(seed): Z sharing no feature must be unmoved")
        }
    }

    // MARK: L6 — read-floor. Stored counts/totals are unfloored and can go
    // negative under repeated corrections; the READ value never is. Drive a
    // target's counts and total negative, then assert every scored value is
    // >= 0 and finite, the distribution still sums to 1, and hourAffinity floors.
    c.check("L6: no score input is ever negative, whatever the stored counts (property)") {
        for seed in UInt64(1)...UInt64(30) {
            var r = SeededRNG(seed)
            let sig = genSignal(&r, hourOffset: r.below(6), base: now)
            let T: Target = .task(.op(1))
            var store = LearningStore()
            let k = 3 + r.below(8)                            // over-correct into the negative
            for _ in 0..<k { store.learn(sig, target: T, weight: -1) }

            let scores = store.scores(for: sig, among: pool)
            for (t, v) in scores {
                try expect(v >= 0 && v.isFinite, "seed \(seed): \(t) read \(v) — must be >=0, finite")
            }
            try expectClose(scores.values.reduce(0, +), 1.0, "no NaN blow-up; sums to 1")
            let hr = cal.component(.hour, from: sig.timestamp)
            try expect(store.hourAffinity(for: T, hour: hr) >= 0,
                       "seed \(seed): hourAffinity floors a negative count to 0")
        }
    }

    // MARK: L7 — no accidental decay. Scoring depends only on counts, never on
    // wall time. `scores()` takes no `now`/age parameter today; this pins the
    // observable consequence so that ADDING one (e.g. an age-relative decay
    // keyed on the signal's timestamp) would break this check: a signal shifted
    // ten years earlier but at the SAME hour-of-day scores identically. (Built
    // with the same gregorian calendar features() uses, so the hour component is
    // held equal DST-safe.) Repeated evaluation is also referentially stable.
    c.check("L7: scoring is time-independent — a decade-old same-hour signal scores identically") {
        for seed in UInt64(1)...UInt64(30) {
            var r = SeededRNG(seed)
            var store = LearningStore()
            for _ in 0..<(4 + r.below(6)) {
                store.learn(genSignal(&r, hourOffset: r.below(6), base: now),
                            target: pool[r.below(pool.count)], weight: 2)
            }
            let sig = genSignal(&r, hourOffset: r.below(6), base: now)

            let s1 = store.scores(for: sig, among: pool)
            let s2 = store.scores(for: sig, among: pool)
            try expect(s1 == s2, "seed \(seed): scoring the same (store, signal) is deterministic")

            // Same signal a decade earlier, same hour-of-day.
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                           from: sig.timestamp)
            comps.year! -= 10
            let past = ActivitySignal(app: sig.app, windowTitle: sig.windowTitle,
                                      tabURL: sig.tabURL, timestamp: cal.date(from: comps)!,
                                      correspondents: sig.correspondents,
                                      emailSubject: sig.emailSubject)
            try expect(store.scores(for: past, among: pool) == s1,
                       "seed \(seed): absolute wall-time must not affect the score (no decay)")
        }
    }

    // MARK: Operator identity — the ONE correction operator reproduces the
    // deltas the live path used to hand-roll, EXACTLY. `correct` composes
    // `learn`; this pins that composition so a future edit to the operator that
    // changed the numbers (a stray extra teach, a dropped subtract, a wrong
    // weight) fails here instead of silently diverging production from the
    // count model. Both arms: with a ranked displacement it is +w to T then -1
    // to D; without one (the +4 boost gesture's semantics) it is a bare +w.
    c.check("operator identity: correct reproduces the hand-rolled +w / conditional -1 exactly") {
        for seed in UInt64(1)...UInt64(30) {
            var r = SeededRNG(seed)
            let sig = genSignal(&r, hourOffset: r.below(6), base: now)
            let T = pool[r.below(pool.count)]
            var D = pool[r.below(pool.count)]
            while D == T { D = pool[r.below(pool.count)] }
            let w = Double(2 + r.below(3))                    // 2..4

            // Ranked displacement: identical to the old learn(T,+w)+learn(D,-1).
            var viaOp = LearningStore()
            viaOp.correct(sig, to: T, weight: w, displacingRanked: D)
            var byHand = LearningStore()
            byHand.learn(sig, target: T, weight: w)
            byHand.learn(sig, target: D, weight: -1)
            try expect(viaOp == byHand,
                       "seed \(seed): operator with a ranked displacement must equal +w to T, -1 to D")

            // No displacement (boost): identical to a bare reinforce, no subtract.
            var viaOpBoost = LearningStore()
            viaOpBoost.correct(sig, to: T, weight: w)
            var byHandBoost = LearningStore()
            byHandBoost.learn(sig, target: T, weight: w)
            try expect(viaOpBoost == byHandBoost,
                       "seed \(seed): operator without a displacement must equal a bare +w reinforce")
        }
    }

    // MARK: L8 — specificity. A title token shared across many targets is
    // weak evidence: even a heavily-taught target matching ONLY the shared
    // token must not outvote a lightly-taught target matching a token that is
    // its alone (2026-08-13 over-learning diagnosis, fix 2 — the "Obsidian/
    // brain2 tokens carry a correction onto every sibling window" mechanism).
    // Matched terms blend toward the unmatched constant as specificity falls;
    // single-target features keep specificity 1.0 and byte-identical scoring.
    c.check("L8: a generic token shared across targets cannot outvote a specific one") {
        let t0 = now
        let sig = { (app: String, title: String) in
            ActivitySignal(app: app, windowTitle: title, timestamp: t0)
        }
        var store = LearningStore()
        // "vault" is shared vocabulary: op(1) taught on it heavily, op(2) and
        // op(3) once each (so three targets hold positive "vault" counts).
        for _ in 0..<4 { store.learn(sig("appa", "vault alpha"), target: .task(.op(1)), weight: 2) }
        store.learn(sig("appb", "vault beta"), target: .task(.op(2)), weight: 2)
        store.learn(sig("appc", "vault gamma"), target: .task(.op(3)), weight: 2)
        // "ambiproj" belongs to op(4) alone, taught once.
        store.learn(sig("appd", "ambiproj delta"), target: .task(.op(4)), weight: 2)

        // A window carrying BOTH tokens: the specific owner must win over the
        // vault-heavy target (pre-fix, op(1)'s accumulated generic counts +
        // experience prior took this at a large margin).
        let probe = sig("appe", "vault ambiproj")
        let scores = store.scores(for: probe, among: pool)
        try expect((scores[.task(.op(4))] ?? 0) > (scores[.task(.op(1))] ?? 0) + 1e-9,
                   "specific-token owner must beat the generic-token accumulator " +
                   "(op4 \(scores[.task(.op(4))] ?? 0) vs op1 \(scores[.task(.op(1))] ?? 0))")
        let top = scores.max { $0.value < $1.value }?.key
        try expectEq(top, Target.task(.op(4)), "the specific owner wins outright")
    }

    // MARK: Fix 6 (2026-08-13) — correcting a PRIMED surface drains the old
    // target's counts exactly like displacing a ranked belief: the prime is
    // the residue of a past correction, and leaving its target's counts
    // intact made a bad correction unkillable (+2 per gesture in, discount
    // never firing once the prime existed). Byte-compared against the
    // operator's ranked-displacement form, the tightest observable pin.
    c.check("correcting a primed surface discounts the displaced target (fix 6)") {
        let sig = ActivitySignal(app: "obsidian", windowTitle: "vaultnote alpha", timestamp: now)
        let old = TaskRef.op(1), new = TaskRef.op(2)
        var seeded = LearningStore()
        for _ in 0..<3 { seeded.learn(sig, target: .task(old), weight: 2) }

        let a = Attributor(instanceHost: host)
        a.replaceLearning(seeded)
        a.primedSurfaces[Surface(signal: sig)] = old   // the relaunch-restored prime state
        let ctx = [WorkTask(ref: old, subject: "old", status: "Now"),
                   WorkTask(ref: new, subject: "new", status: "Now")]
        a.assign(sig, target: .task(new), tasks: ctx, now: now)

        var expected = seeded
        expected.correct(sig, to: .task(new), weight: 2, displacingRanked: .task(old))
        try expect(a.learning == expected,
                   "assign over a primed surface must run the operator WITH the discount arm")
        // A displaced PIN must still never be subtracted against: sanity via
        // the ladder — pin the surface, correct, and expect a bare +2.
        let b = Attributor(instanceHost: host)
        b.replaceLearning(seeded)
        b.upsert(Pin(rule: .components(PinScope(kind: .app, prefix: ["obsidian"])),
                     task: old))
        b.assign(sig, target: .task(new), tasks: ctx, now: now)
        var bareReinforce = seeded
        bareReinforce.correct(sig, to: .task(new), weight: 2)
        try expect(b.learning == bareReinforce,
                   "a displaced pin (direct human word) still carries no discount")
    }
}
