# Approvals drawer – stop the review pile building and building

Status: DESIGN (no code in this commit). Spec date 2026-07-06. Seeds a /vs
run once Martin has answered the open questions.

Trigger (Martin, from real use): "I don't even know how I approve a time
entry. Is that in the evil drawer that currently contains 1,040 items? …
I have just been ignoring that set. We need better ways of dealing with
it, so it doesn't just build and build." This is a potential
adoption-killer: a passive tracker whose review surface grows monotonically
trains every user to ignore it, and an ignored review surface silently
degrades attribution quality (nothing gets corrected) and invoicing
confidence (low-certainty time never posts). This spec treats the drawer as
a UX-psychology problem – the mechanics below exist to break a behavioural
loop, not to add features.

## 0. Open questions for Martin (answer before /vs build starts)

1. **Threshold defaults** – today spans below 0.6 certainty queue for
   review (`SessionTracker.Config.uncertainBelow`) and sessions at/above
   0.8 auto-push to OP (`Settings.certaintyAutoPushThreshold`). Recommend
   keeping both numbers but making the review threshold a visible setting
   next to the push threshold, with the summary prompt (§4) showing the
   consequence ("at 0.6, 74% of last week needed no review"). Confirm the
   defaults, or pick new ones.
2. **Aging policy on by default?** – recommend ON, fading items older
   than 4 weeks to an archive state (§6; never deleted, never silently
   posted). The counter-argument: a consultant who invoices quarterly may
   want 13 weeks. The setting is a duration, so the real question is only
   the default. Confirm on/off and N.
3. **Per-entry approval forever, or trust mode?** – posting to OP today is
   automatic at ≥ 0.8 certainty and impossible below it. Should andeye
   offer a trust mode where, after k consecutive weekly reviews in which
   Martin changed nothing (recommend k = 4), the weekly prompt switches
   from "approve the confident ones" to "posted the confident ones –
   undo?" (opt-out digest instead of opt-in tap)? Recommend yes as an
   explicit setting, default off. Confirm, or rule that posting below the
   auto-push threshold always requires a human tap.
4. **Retro-acceptance certainty bar** – when a later rule/pin/correction
   makes the attributor confident about queued drawer items (§2), should
   they clear at the review threshold (0.6, aggressive – matches "would
   not have queued today") or the push threshold (0.8, conservative)?
   Recommend 0.8: retro-clearing is a bulk act, so it should meet the same
   bar as unattended posting. Confirm.
5. **Does retro-accepted time post to OP?** – a retro-cleared segment's
   underlying session was journalled at low certainty and sits below the
   push threshold. Recommend: retro-acceptance re-scores and updates the
   session certainty too, so it becomes push-eligible through the normal
   sync path (visible in the digest before the next sync tick). The
   timid alternative – clear the drawer row but leave the session
   unpushed – recreates the same invisible second pile. Confirm.
6. **Badge framing** – replace the raw count with time-shaped framing
   ("3 days unreviewed", §7). Confirm the unit (calendar days spanned vs
   summed tracked hours – recommend calendar days spanned; hours can look
   absurdly small and undercut urgency in the other direction).

## 1. What the code says today (investigation) – why the drawer grows

Two piles exist, and only one has a UI:

- **The drawer (review queue).** Every focus span whose certainty falls
  below `uncertainBelow` (0.6) is coalesced into a `ReviewSegment`
  (Sources/andeyeTTCore/SessionTracker.swift, `endCurrentSpan` →
  `queueReview`) and journalled. `pendingReview()` returns every segment
  with `assigned == nil`, unbounded, oldest first
  (Sources/andeyeTTCore/JournalStore.swift). The ONLY exits are manual:
  multi-select assign in ReviewView, the copy-paste AI classification
  flow, or undo. No expiry, no re-scoring, no auto-clear. Ignoring it is
  absorbing – 1,040 items is the steady state, not a bug.
- **The invisible pile (unpushed sessions).** Sessions are journalled
  regardless of certainty; those at/above `certaintyAutoPushThreshold`
  (0.8) auto-push to OP on sync (Sources/andeyeTTCore/SyncEngine.swift
  `pushEligible`), those below it sit forever as "awaiting push" – counted
  only in the debug-ish `journalSummary` string, surfaced nowhere
  actionable. This is why Martin cannot find where to "approve a time
  entry": approval as a user-facing act does not exist. High-certainty
  time approves itself invisibly; low-certainty time is unapprovable.
- **Corrections only teach the future.** `assignReview`
  (Sources/andeyeTTMac/AppController.swift) marks segments assigned and
  soft-primes the attributor – but never re-scores the rest of the queue,
  and never touches the low-certainty sessions covering the same minutes.
  A pin that would clear 300 queued rows clears zero of them. (Side-bug to
  fix in passing: a multi-select assign teaches from only the FIRST
  selected segment's signal – `pendingReview.first(where:)`.)
- **The badge is a raw count.** PopoverView shows
  `Label("\(controller.pendingReview.count)", systemImage: "tray.full")`.
  At 1,040 that number is a wall, not an invitation.

The loop this produces: below-threshold minute → drawer (+1) → pile too
big to face → no corrections → attributor doesn't improve → more minutes
fall below threshold → pile grows faster. Classic learned helplessness:
the size of the backlog is itself the reason the backlog grows.

## 2. Principles (each cited once, then applied)

- **Reduce decision load** (Hick's law – choice time grows with option
  count): never present 1,040 decisions; present ~5 group-level decisions.
- **Make progress visible** (goal-gradient effect): a shrinking,
  time-framed indicator; each action visibly moves it.
- **Never punish absence**: the pile must be able to SHRINK with zero user
  action (retro-acceptance §3, aging §6). A system that only ever charges
  interest on absence trains avoidance.
- **User-controlled cadence**: review is a ritual the user schedules
  (weekly prompt §4) or an act with a purpose (invoicing §5) – never an
  ambient nag.
- **Zeigarnik / inbox-zero**: open loops occupy attention only while zero
  feels reachable; past a threshold the mind writes the whole set off.
  Design for "reachable zero this session", every session.
- **Trust loop with the certainty score**: every correction should
  visibly raise future certainty (fewer items queue) and retroactively
  clear past items – the user must SEE the machine learning, or
  correcting feels like bailing the sea.

## 3. Retroactive auto-acceptance – corrections clear the past

When anything raises the attributor's confidence – a pin, a context rule,
an Evidence Card "Always", a review assign, a timeline reassign – re-score
the pending queue:

- Re-run each pending `ReviewSegment`'s signal through
  `attributor.explain()`/rank. Segments whose best target now scores ≥ the
  retro bar (open question 4) auto-assign to that target through the
  existing `journal.assign` path, and their overlapping sessions'
  certainty is updated (open question 5).
- Debounced: re-score on a background tick after mutations settle (a
  correction burst = one pass), and cap per-pass work so a 10k-row queue
  cannot beachball the main thread.
- **Digest, never silence**: each pass that clears anything appends one
  journalled digest entry – "Cleared 212 items to task X via rule Y –
  undo". Undo restores `assigned = nil` and the prior session certainty.
  The digest is a journal row (survives relaunch), not just an `UndoStack`
  entry (session-bounded). Digest history lives in the drawer's new
  "Recently cleared" section, newest first, 30-day retention.
- This makes correcting feel like power: assign one Chrome row, watch 80
  siblings vanish with a named receipt.

## 4. Bulk actions + the weekly review ritual

Drawer restructure (ReviewView):

- Group rows by attributor's best guess – task, then day – instead of a
  flat day list. Each group header carries the group's summed duration,
  mean certainty, and one-gesture actions: **Accept all as <task>**,
  **Do not track all**, **Reassign all…**. Accepting a group teaches from
  every segment in it (fixing the first-segment-only bug).
- An **"Accept all above <threshold>"** control at the top: one tap
  approves every pending item whose current best score clears the bar –
  the manual twin of §3's automatic pass, same digest + undo.

Weekly prompt (cadence configurable: weekly default, or off):

- Fires as a gentle prompt (existing `onPrompt` seam), SUMMARY first:
  "Last week: 31 h across 9 tasks. 26 h already high-certainty." Then ONE
  primary action – **Approve the confident ones** – plus "Review the rest
  (5 h, 6 groups)" and "Later". The confident tap runs the §3 pass at the
  push bar and posts through normal sync; the remainder is small enough
  that zero is reachable in one sitting (Zeigarnik payoff).
- After k unchanged weeks, trust mode (open question 3) may flip the
  prompt to an opt-out digest.

## 5. Invoicing-driven path

A consultant's real deadline is the invoice, not the ritual. Add a
date-range review mode (entry point: SpentView / export): "Invoice 1–30
June" filters the drawer AND the unpushed-session pile to that range,
shows the same group summary, and approves exactly what the invoice
needs. Everything outside the range is untouched and un-nagged – ignoring
non-billable noise is a legitimate strategy, not a failure state.

## 6. Aging policy – items fade, never nag forever

Optional (open question 2): pending items older than N weeks (default 4)
move `assigned = nil` → `archived` – a new state, excluded from the badge,
the groups, and the weekly summary, visible under a collapsed "Archived"
section with the same bulk actions. Archived time is NEVER silently
posted and never deleted (Sources/andeyeTTCore/JournalPrune.swift
consolidation applies to it like any old data). Framing in UI copy:
"andeye stopped asking about these" – absence was not punished, and the
door stays open.

## 7. Badge framing – never a raw four-digit count

Replace the count badge with time-shaped framing: "3 days unreviewed"
(calendar days spanned by pending items, open question 6). Colour steps
at cadence-relative ages (fresh / due / overdue) rather than magnitude.
Rationale: "1,040" measures the machine's appetite; "3 days" measures the
user's actual exposure, stays small when the user is current, and cannot
grow into a wall. The exact count remains available inside the drawer
header for the curious.

## 8. Acceptance criteria (a /vs build can verify)

All in `andeyeTTChecks` style (plain executable, real scenarios):

1. A span below the review threshold queues; adding a pin that scores
   that surface ≥ the retro bar clears it within one re-score pass, writes
   a digest entry, and undo restores it – nothing is lost.
2. Retro-clearing (with open question 5 = yes) lifts the overlapping
   session's certainty so `sessions(needingPushAtOrAbove:)` includes it;
   with the answer no, sessions are untouched.
3. Group accept assigns every segment in the group and teaches the
   attributor from each (regression check on the first-segment-only bug).
4. "Accept all above threshold" clears exactly the items whose best score
   ≥ bar; borderline items (score = bar − ε) remain.
5. Weekly summary maths: n hours / m tasks / x% high-certainty computed
   from a seeded journal match hand-computed values; the one-tap approve
   posts exactly the high-certainty subset.
6. Invoice-range approve touches only sessions/segments overlapping the
   range; outside items keep their state.
7. Aging pass archives only items older than N weeks, never posts them,
   and archived items are excluded from badge framing.
8. Badge framing: seeded queues spanning 0/1/3/10 days produce the
   expected strings; the raw count never appears in the badge string.
9. Digest entries survive a relaunch (journal-backed) and expire at 30
   days.

## 9. v1 scope vs later

v1 (one /vs run): §3 retro-acceptance + digest/undo, §4 grouped drawer +
accept-all-above-threshold, §7 badge framing, the first-segment teaching
fix, checks 1–4 and 8–9. This alone reverses the growth loop: corrections
start clearing the past, and the wall becomes a number of days.

Later: §4 weekly prompt (needs prompt-cadence settings UI), §5 invoice
mode (pairs naturally with the billable-flag spec of the same date), §6
aging, trust mode (open question 3), iOS parity via `andeyeTTPhone`.
