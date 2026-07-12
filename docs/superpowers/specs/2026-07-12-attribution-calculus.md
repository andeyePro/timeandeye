# Attribution certainty – the calculus

One number rules the attribution engine: `certainty`, a `Double` in `[0, 1]`,
meaning *how confident the app is that this slice's current task assignment is
right*. It is computed locally, journalled locally, and never leaves the
device – backends receive time entries, not confidence. This spec is the
single definition of how that number is produced, folded, mutated, compared
and shown. Code that touches certainty conforms to this document; a deviation
is a bug in one of the two.

## The three tiers

Every certainty value belongs to a tier, and every producer has a tier
ceiling it may not exceed:

| Tier | Ceiling | Meaning | Producers |
|---|---|---|---|
| Human word | `1.0` | A person asserted this assignment | pin, manual start, review confirm, timeline reassign, Unknown-sweep repoint |
| Inferred | `0.95` (`inferredCeiling`) | A learned or structural rule matched | sticky follow, OP task URL/title, email rule, site rule, primed surface, idle-gap claim, adjacency-corroborated lift |
| Ranked | `0.9` (`rankedCeiling`) | Uncorroborated engine ranking | `scoredComponents()` softmax blend |

Two boundary rules give the tiers their teeth. A ranked candidate may cross
into the inferred tier only through live-adjacency corroboration (neighbouring
slices agreeing is rule-grade evidence, so the lift's ceiling is
`inferredCeiling`, not the ranked cap). And `1.0` is reserved for the human
tier: no inference, boost, or fold may produce it.

One deliberate exception: a relabel or confirm of the *live, still-running*
slice writes `inferredCeiling`, not `1.0` – the run stays under engine
control and may legitimately re-switch, so the human word there covers the
moment, not the slice. Human corrections to *journalled* slices are the
`1.0` tier.

The floor is `0`. No producer may journal a negative certainty (the
others'-task ranking penalty is a sort key, not a confidence, and is clamped
before it becomes one).

## The ownership rule

Certainty describes the *current* assignment, so:

- **Task change ⇒ replace.** Whoever re-points a slice writes their own belief
  about the new task: the contradiction refile writes its finding's score, a
  human re-pointing (timeline reassign, Unknown-sweep) writes `1.0`. Carrying
  a number derived for the old task onto the new one is dishonest and
  forbidden.
- **Same-task confidence event ⇒ monotone max.** An event that re-affirms the
  existing assignment (retro clearance, adjacency corroboration at flush time)
  may only raise certainty, never lower it.
- **Nothing else mutates it.** Display never writes back; undo restores the
  exact prior value from its snapshot.

A corollary users feel: any human correction makes the slice post-eligible at
once (certainty `1.0` clears every bar). Approving *where* time goes is
approving it as tracked truth; the posting gate exists to hold back the
engine's guesses, not the user's word.

## Folds

A slice's spans each carry a certainty; the journalled session gets the
**duration-weighted mean** of its spans, floored at `inferredCeiling` when a
pin governed the run. Every other many-to-one fold (merge, prune) uses the
same duration-weighted mean – confidence blends by time, it is not the max of
its parts and not the min.

Provenance folds differently, by design: `SessionProvenance` names the
duration-dominant *decider* (the story), while certainty blends the whole run
(the number). The named decider therefore need not "own" the exact journalled
value; the Evidence Card shows both without pretending otherwise.

## The thresholds

| Constant | Value | Home | Gates |
|---|---|---|---|
| `switchBar` | `0.6` | TrackerConfig (fixed) | live switch commits; timeline span opacity references the same constant |
| `certaintyAutoPushThreshold` | `0.8` default, user slider `0.5…1.01` (`> 1.0` = never) | Settings | posting, review-queue admission, retro-lift bar, contradiction bar, blue-suggestion agreement, confirm-viewed bar |
| `idleResumeBar` | `0.9` | TrackerConfig | auto-switch on idle resume |
| `rankedCeiling` | `0.9` | Attributor | ranked producer cap |
| `inferredCeiling` | `0.95` | Attributor | rule/prime/adjacency cap, pin floor at flush |

Ordering invariant: the constant chain `0 ≤ switchBar < idleResumeBar ≤
rankedCeiling < inferredCeiling < 1.0` always holds. The user's push bar
ranges over `0.5…1.01` independently: it normally sits above `switchBar`
(the default 0.8 does), the `> 1.0` position is the "never auto-push"
sentinel, and slider positions at or below `switchBar` are legal but simply
mean every committed switch is already post-eligible.

There is exactly one review bar and it is the push bar: a slice below it
queues for review, at or above it is push-eligible. `reviewBelow` exists as
tracker plumbing but always carries the push bar's value; it must never grow
its own number again. The contradiction pass additionally keeps a lower
`suggestFloor` (0.5): a contradicting re-derivation scoring in
`[suggestFloor, bar)` surfaces as a suggestion only – a documented lane, not
a drift. The eligibility gate for retro-style passes (review
walk, Unknown sweep, retro lift) is one shared predicate – unpushed, below
the bar, overlapping the segment – so the three paths cannot drift.

## Display

Journalled surfaces (timeline chips, Evidence Card, exports of counts) show
the **stored** certainty; the review queue and slice details show a **fresh**
explanation computed against today's rules, which is why a rule you taught a
minute ago changes the drawer but not the history. Percentages round
half-up from the same stored value everywhere; adjacency boost deltas are
displayed in points (a `0.19 → 0.42` lift is "+23 pts", never "+23%").

## The pinned invariants

`CertaintyCalculusChecks` pins these as properties, not examples:

- **P1 tier ceilings** – every producer path lands at or under its tier's
  ceiling; only human-word paths produce `1.0`.
- **P2 floor** – no journalled certainty is negative, whatever the prior
  penalties.
- **P3 human word** – pin, manual start, confirm, reassign, sweep-repoint all
  yield exactly `1.0`.
- **P4 ownership** – a task-changing mutation replaces certainty; a same-task
  confidence event never lowers it.
- **P5 fold** – the flush fold equals the duration-weighted mean (property
  over randomised span sets), with the pin floor.
- **P6 one gate** – the retro/walk/sweep eligibility predicate is a single
  shared function and excludes pushed slices.
- **P7 ordering** – the threshold ordering above holds at both slider
  extremes and at the sentinel.
