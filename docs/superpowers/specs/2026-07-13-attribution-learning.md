# Attribution learning – the model

The app learns which task a slice belongs to from the corrections a user
makes. This is the product's core: the correction a user makes today should
make tomorrow's guess right without them ever opening a settings screen. This
spec is the single definition of what the learner stores, how a correction
moves it, what a learned score means, and the invariants that keep it honest.
It sits above the certainty calculus: a learned score enters that calculus at
the *ranked* tier and no higher.

## Two substrates

Learning lives in two places, and they are not the same kind of thing:

- **The count model** (`LearningStore`) – a naive-Bayes association store:
  `counts[feature][target]` and `totals[target]`. It self-adapts: every
  teach moves counts. This is the statistical learner.
- **The rule ladder** – email-correspondent, site, and calendar rules. These
  are deterministic, replace-on-conflict overrides a user sets explicitly;
  they do not accumulate evidence. A rule is a stated fact, not a learned
  tendency.

This spec is about the count model. The ladder's only obligation here is that
it sits *above* the count model in the attribution ladder and its scores are
inferred-tier, not ranked.

## Features

A signal is shredded into independent features, all of them observed from the
device only (never a word of backend content – the Xero-compliance freeze):
`app`, `titleToken` (each word of three or more characters), `urlHost`,
`urlPath` (host plus first path segment), `correspondent`,
`correspondentDomain`, `recipeField` (identity fields only), and
`hourOfDay`. Independence across features is the naive-Bayes assumption and is
deliberate – it is what lets a correction on one signal generalize to a
different signal that shares a feature.

## The score

For a candidate target, over the signal's features:

```
matched feature   (count c > 0):  kindWeight · log((c + 0.1) / (total + 1))
unmatched feature (count = 0):    kindWeight · log(0.1)
kindWeight = 0.15 for hourOfDay, else 1.0
if any non-hour feature matched:  + log(total + 1)        (experience prior)
score(target) = softmax over targets              (sums to 1)
```

Then the certainty calculus takes it: `ranked = max(0, min(rankedCeiling,
0.7·softmax + priorWeight · prior/maxPrior))`. The `0.1` smoothing, the
constant `log(0.1)` unmatched penalty, the `0.15` hour down-weight, and the
`log(total+1)` experience prior each carry a rationale (reviewer letters
B5/B6/B9 and the "one evening of Steam at 22:00" note) recorded at their
definitions; this spec does not relitigate them, it pins their effects.

## The correction operator

Every teach is one operator with one definition. A correction to task T,
displacing task D:

- **Reinforce** T: `+2` to each of the signal's features (a boost gesture is
  `+4`).
- **Discount** D: `−1` to each shared feature, *only when D's belief was
  engine-ranked* – a human's earlier word or a pin is not evidence to
  subtract against.
- **Nothing else teaches.** An auto-applied inference (retro clear,
  contradiction refile) re-points the journal but must never teach the count
  model – the learner may not train on its own unconfirmed guesses. This
  no-self-reinforcement rule is the single most important property here and
  is structurally enforced today; it must stay so.

Two consequences the operator must own honestly:

- **A correction is directional, not instant.** `+2/−1` moves the corrected
  target up and the wrong one down, but one correction does not erase months
  of confirmations on the *same* signal – it takes repeated corrections, or
  the explicit forget gesture, to overturn entrenched weight. This is
  intended (a single misclick should not wipe a well-learned association),
  and the UI's forget affordance is the fast path.
- **Teaching is tier-independent.** Confirming a shaky 0.5 guess teaches
  exactly as strongly as an explicit pick. Certainty gates the *journal*
  lanes; it never scales the *count* deltas.

## Persistence

Counts and totals are floored at *read* (`max(·, 0)`) – that read-time floor
is the contract, so a stored negative is inert, never a score input. The
store round-trips through JSON and tolerates unknown feature kinds on decode
(the version-migration path). Counts are unbounded.

## The invariants

`AttributionLearningChecks` pins these as properties over generated inputs
(today's learning checks are all example-based; this is the moat's first
invariant coverage):

- **L1 correction direction** – after a correction to T displacing ranked D,
  T's score for that signal does not fall and D's does not rise.
- **L2 no self-reinforcement** – running the retro and contradiction passes
  over any journal leaves the count model byte-identical; only user gestures
  teach.
- **L3 tier-independence** – the count delta of a confirm does not depend on
  the confirmed decision's certainty.
- **L4 cold start** – `scores` on an empty store is empty (priors-only
  attribution); on a populated store an untaught signal is near-uniform (no
  runaway from the biggest `totals`).
- **L5 generalization** – a correction on signal X raises the corrected
  target for a different signal Y that shares at least one feature, and does
  not move a signal that shares none.
- **L6 read-floor** – no score input is ever negative, whatever the stored
  counts.
- **L7 no accidental decay** – scores depend only on counts, not on wall time
  (this pins the *current* no-decay behaviour so that if decay is ever added
  it is a deliberate, reviewed change, not a silent one).

## Open decisions (owner's call – not changed here)

These are product judgments about the moat, deliberately left for the owner
rather than settled by a coherence pass:

1. **Recency / decay.** The count model never ages: a user who stops working
   a client keeps every association at full strength, and the inflated
   `totals` keep re-surfacing that dead task through the experience prior.
   `TaskRanker` decays task recency on a seven-day half-life; the association
   learner does not decay at all. Options: a time-based half-life on counts,
   a correction-triggered discount of the *displaced* history, or leave it
   and lean on the forget gesture. Recommendation: a slow time-based
   half-life (long enough that a steady client is unaffected, fast enough
   that a dropped one fades over weeks), because it is the option that needs
   no user action – which is the whole product promise.
2. **Forget completeness.** The forget gesture erases a target's counts but
   deliberately leaves its `totals` (to keep smoothing stable), so a
   suppressed task can still surface via the experience prior. Decide whether
   forget should also clear the total.
3. **Write-floor and boost symmetry.** Whether corrections should floor
   counts at write (faster re-learning after heavy correction) and whether a
   `+4` boost should discount a displaced ranked belief the way a `+2`
   confirm does. Both are small behaviour changes to the correction operator.
4. **Teach/score weight symmetry on hourOfDay.** The hour feature is scored
   at `0.15` but taught and discounted at full weight; decide whether the
   teach side should match the score down-weight.
