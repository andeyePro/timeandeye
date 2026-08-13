# Correction over-learning — diagnosis and fix set (2026-08-13)

Martin's #1 priority (13 Aug): windows mis-attributed "based on a past
correction" (an Obsidian "Ambi4-fromMartin - brain2" window tracked as
andeye insurance at 87%), forget changing the evidence card but not the
slice, and no visibility into which correction caused what. Read-only
code trace by a dispatched agent, 2026-08-13; line numbers as of commit
01b9754. This spec is the map for the fix programme in TODO.md
("Martin's 13 Aug replies", #1 item).

## (i) Teach-path inventory: every gesture that writes persistent learning state

All paths converge on three Core operators in `Sources/timeandeyeCore/Attributor.swift`:

- `confirm()` (714–728) and `assign()` (767–783): session sticky +
  `primedSurfaces[surface] = task` (a 0.95-tier standing rule, no expiry) +
  `LearningStore.correct` weight **+2** (with −1 discount of the displaced
  belief *only* if it was engine-ranked — `rankedDisplaced`, 735–738)
- `learnSurface()` (754–758): prime + `learn` at caller's weight, **no discount**
- `LearningStore.learn/correct` (`LearningStore.swift:112–151`) teaches
  **every feature of the one signal passed**: `app`, all title tokens ≥3
  chars, urlHost/urlPath, correspondents, recipe fields, hourOfDay×0.15
  (`features(from:)` 69–110)

| Gesture | Entry point | What is taught | Weight |
|---|---|---|---|
| Popover pick (fresh start) | `AppController.userPicked` 1779 → `SessionTracker.confirm` 414 → `Attributor.confirm` | current focus signal only: sticky + prime + all features | +2 |
| Popover "Reassign" running session | `changeCurrentTask` 1901 → `attributor.assign` 1943 (+ calendar rule 1946) | current focus signal only | +2 |
| Review drawer multi-assign / stack / **AI paste** / walk-confirm | `assignReview` 2080 → `teachingSignals` (`Models.swift:508`) → `attributor.assign` per surface (2130–2133) | **EVERY distinct surface** in the selection — prime + features each | +2 each |
| Timeline whole-slice reassign (block) | `reassignTimelineSessions` 4732 → `teachAssociation` 4777 | **dominant (longest) span per session** — one signal per reassigned session | +2 |
| Timeline editor task change | `applyTimelineEdit` 4540 → `teachAssociation` 4596 | dominant span of that session | +2 |
| Window-strip "Wrong? file as" / span-select Allocate / Spent "move app" | `splitAndReassign` 4969 / `allocateSpan` 5000 / `reassignSpentApp` 4790 → `replaceSession` 4954 → `teachAssociation` per **moved piece** | dominant span of each moved piece | +2 |
| "Don't track this" | `markSessionDoNotTrack` 4673 → `assign(.doNotTrack)` 4680 | dominant span → doNotTrack | +2 |
| Why-panel teach / Boost | `teachSurface` 3894 (confirm, +2) / `boostSurface` 3903 (`learnSurface`, **+4, no discount**) | that one span's signal | +2 / +4 |
| Card Remember/Always, grain footers, ledger | `commitGrain` 3596 → `learnEmailRule`/`learnSiteRule` | durable EmailRule/SiteRule (0.95 rung) | rule |
| New local task creation | `addLocalTask` 853 → `confirm` | current surface primed to the new task | +2 |
| Pending prime (no gesture) | `noteDwell` 488 after opening an OP task page | transient hypothesis, 0.7, 15-min TTL | — |
| Contradiction refile / retro pass | `applyRefiles` 2700 | **never teaches** (guarded, checked by L2) | — |
| iOS repair | `PhoneController.reassign` 322 | never teaches | — |

Persistence: `persistAssociations` 1800–1811 → `learning.json`,
`primed.json`, `pins.json`, `emailrules`, `siterules`, calendar rules.
`primed.json` is loaded at start (529–530). **Primes never expire and are
keyed on exact `Surface`** (`Models.swift:229–259`: app + windowTitle
verbatim for non-URL windows — the Obsidian title embeds the app version
"Obsidian 1.13.4", so an app update silently orphans old primes).

## (ii) Verdict on the block-reassign hypothesis

**Refuted in its literal form, confirmed in effect — via three real mechanisms.**

Literal claim ("every window in the block is taught"): false for the
timeline paths. `teachAssociation` (4658–4667) teaches only
`dominantSpan(of: session)` — one signal per reassigned session/piece,
never the flits.

But the observed behaviour is produced anyway:

1. **Feature generalisation (the big one).** The one dominant-span teach
   writes +2 onto `app=obsidian`, `titleToken=brain2`,
   `titleToken=obsidian`, `hourOfDay` — features shared by *every* brain2
   Obsidian window. `scores()` (`LearningStore.swift:198–253`) then
   softmaxes: a heavily-taught target with 3 matching features plus the
   `log(total+1)` experience prior (234) takes a near-1.0 softmax share on
   any sibling window. Teaching the block's dominant Obsidian note to
   "andeye insurance" drags **all** Obsidian/brain2 windows toward it.
   Check L5 proves generalisation is by design; there is no per-feature
   specificity discount (a token like "obsidian" is treated identically to
   "ambi4").
2. **Per-session dominance inside a multi-session block.** A displayed
   block can be several journal sessions; each teaches its own dominant
   span. A short session dominated by a flit teaches that flit's surface
   at full +2 **and primes it** to the block's task — exactly "remembered
   surface: Obsidian · Ambi4-fromMartin → andeye insurance". Same for
   every piece of `allocateSpan`/`splitAndReassign`.
3. **Bulk review assign teaches literally every surface.** `assignReview`
   2126–2133 primes and teaches **each distinct surface** in the selection
   — a sweep of a big block's queued segments (or an AI paste,
   `ingestAIResponse` 5109→5121, or `confirmViewedSlices` 2266) does
   precisely what Martin hypothesised, flit rows (≥20 s,
   `minSegmentSeconds`) included.

Asymmetry that makes it sticky: reinforcement is +2/+4 per gesture; the
discount arm is −1 and fires only when the displaced belief was `.ranked`
(`Attributor.swift:735–738`). Once a prime exists for a surface, later
corrections of it displace a `.primedSurface` source → **no discount ever
hits the wrong task's counts**; `learn`'s floor-at-0 (126) can't go
negative anyway.

## (iii) Root cause of the Obsidian case

- The 87% is the **ranked tier** (`scoredComponents` 843–906):
  `0.7 × softmax-share + 0.2 × prior/maxPrior`. With insurance's softmax
  share ≈0.96 (taught obsidian/brain2 tokens + experience prior) that's
  0.67 + ~0.2 ≈ **0.87**. The "correct candidate at 64%" is arithmetically
  **impossible in the same pass** (learned shares sum to 1: winner at 0.87
  leaves the runner-up ≤ ~0.23 base) — 64% is only reachable as an
  **adjacency-boosted** figure (`AdjacencyBoost.apply`,
  `ReviewDetail.swift:263–317`: 0.23 + 0.6×(0.95−0.23) ≈ 0.66) or from a
  different scoring moment. So the wrong candidate won on accumulated
  generic-feature counts; the right one had only continuity evidence.
- The card line "= andeye insurance 87% – learned associations + priors
  (follows Brain2 (0.74 → 0.80 (+6 pts)))" is a **composite of two
  different decisions**: `TimelineView.swift:1767–1772` pairs the
  *slice's* task+certainty with the *window span's own* provenance
  (`spans[i].provenance ?? session.provenance`). 0.87 and 0.74→0.80 cannot
  come from one `attribute()` call (proof above); the span was decided
  "follows Brain2, 0.80" (adjacency), then its minute was dominated by
  insurance spans (`flushSessions` 1009–1160 bills per dominant minute;
  `provenanceDurations` 1133–1156 folds provenance separately from
  certainty). The flit window's time billed to insurance without any
  decision ever choosing insurance *for that window*.
- Why no prime saved it at decision time: either the prime → ambi4 was
  written only later (his correction — "today's rules would say … not
  what decided this slice" is exactly `AttributionExplanation.contradicts`,
  `Attributor.swift:177–179`), or an earlier prime was keyed on a title
  containing an older Obsidian version string and stopped matching after
  an update (`Surface.init`, `Models.swift:257` — the raw title, version
  included, is the key).

## (iv) Why forget doesn't change the slice

`AppController.forget` (3544–3570) mutates the learning stores, persists,
and calls `tracker.reevaluate()` — which only re-tags the **live open
spans** (`SessionTracker.reevaluate` 364–384). **Nothing re-derives or
rewrites the journalled session row**; the card's standing line reads
`recorded` straight from the journal (`EvidenceCardView.swift:191–196`),
so it can't move. Two compounding misses:

1. No refile: the only paths that change a recorded slice are the user's
   own reassign gestures and the contradiction pass (`runContradictionPass`
   2623, debounced via `scheduleRetroPass` in `persistAssociations` 1810 —
   and it only auto-moves when `refileMode == .auto`, engine-decided,
   unpushed, ≥ bar; otherwise it just *suggests*).
2. Forget targets the wrong object: `forgettable()` (995–1016) mirrors
   **today's** ladder, so for this window it returns `.primedSurface` —
   the *current, correct* prime → ambi4 — while the thing that actually
   decided the slice (the ranked counts toward insurance) sits shadowed
   beneath it. Forgetting deletes the good correction and leaves the bad
   counts untouched.

## (v) Minimal fix set

1. **Duration-gate + weight the timeline/review teaches.** In
   `teachAssociation` (`AppController.swift:4658`) skip or down-weight
   teaching when the session/piece is short (e.g. < 2–5 min), and in
   `assignReview` (2126) weight each surface's teach by its segments'
   covered duration instead of flat +2 per distinct surface. This directly
   kills "a bulk recategorisation teaches every flit at confirmation
   strength". Checks: `ApprovalsDrawerChecks`, `AttributionLearningChecks`
   (L1/L3/operator identity), `CertaintyCalculusChecks`.
2. **Add a specificity/discriminativeness guard to generic features.** In
   `LearningStore.scores`/`learn`, down-weight title tokens (and `app`)
   that co-occur across many targets the way `hourOfDay` already is (the
   `kindWeight` seam at 213 is the right place — e.g. an IDF-style weight
   per feature), so "obsidian"/"brain2" can't outvote "ambi4" vs
   "insurance". Checks: `AttributionLearningChecks` L4/L5/L7,
   `AttributionChecks`.
3. **Make forget refile (or offer to).** In `AppController.forget` (3544),
   after mutating, re-run `explain` for the recorded slice and either
   update the journal row when the slice was engine-decided and unpushed
   (reuse `applyRefiles`' lane rules) or surface the existing refile
   suggestion immediately — plus have `forgettable(for:)` accept the
   *recorded* provenance so the card's ✕ removes the store that actually
   decided the slice (`.rankedAssociation(insurance)`), not today's
   shadowing prime. Checks: `EvidenceCardChecks`, `ContradictionRefileChecks`.
4. **Stop the card pairing slice certainty with span provenance.**
   `TimelineView.swift:1767–1772`: pass the span's own target/certainty
   when `spans[i].provenance` is used, or fall back to session provenance
   *with* session certainty — never mix. Checks: `EvidenceCardChecks`,
   `ProvenanceChecks`.
5. **Normalise the Surface key for title-keyed windows** (strip trailing
   app-name/version suffixes, e.g. " - Obsidian 1.13.4") in `Surface.init`
   (`Models.swift:238`), with a one-shot migration of `primed.json` keys —
   prevents silent prime orphaning on app updates. Checks: `ModelsChecks`,
   `SessionStickyChecks`, plus a new decode/migration check.
6. (Cheap, high value) **Symmetric discount:** in `Attributor.confirm/assign`,
   also discount when the displaced belief was `.primedSurface`/
   ranked-learned mass for the same signal — currently a correction of a
   primed surface leaves the old task's counts fully intact (735–738).
   Flagged as an owner call in the attribution-learning spec ("boost
   symmetry"), so surface it to Martin when built rather than assuming.
   Checks: `AttributionLearningChecks` L1.

The correction LEDGER Martin asked for (journal every teach with its
gesture + surface + weight; card names the exact correction behind a
learned association; ledger view lists corrections and what each has
since decided) builds ON TOP of this inventory — the teach paths above
are the exact set of write points the ledger must instrument.

Linux subset covers fixes 2/4-card-logic/5/6; fixes 1 and 3 touch
`timeandeyeMac`'s AppController and need the Mac suite (bridge:
`bash .vibe/mac-test.sh`, baseline TOTAL 933/0).
