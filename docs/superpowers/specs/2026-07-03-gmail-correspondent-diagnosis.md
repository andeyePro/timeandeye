# Gmail correspondent attribution — diagnosis (2026-07-03)

Status: DIAGNOSIS ONLY — no code changed. Evidence cites file:line on branch
`fable2` (HEAD 086e6bc) and commit shas.

## Executive summary

- Email capture is switched off. Since the 2026-06-30 revert (5439a83), no
  tracked signal ever carries correspondents or a subject — the entire
  email-rule system (rules, ladder, sender pins, email stickies) is dead code
  at runtime. Everything Martin taught it can only key on app / window title /
  URL.
- To the tracker, all of Gmail is ONE page. Gmail puts the message identity in
  the URL fragment (`#inbox/<thread>`), which the surface identity drops — so
  every Gmail tab collapses to `mail.google.com/mail/u/0`. One correction on
  any email re-points ALL of Gmail.
- "University Teaching" keeps winning because a past correction primed
  that single all-of-Gmail surface to it at 95%, and every confirmation since
  has stacked learned weight onto Gmail-generic features (app=google chrome,
  urlHost=mail.google.com, titleToken=gmail…). Corrections only ever ADD weight
  to the new task; nothing ever subtracts from the wrong one.
- The why-panel shows title junk and no addresses because its "learns on" list
  is exactly the learner's feature set — and the learner has no correspondent
  feature at all. The only address in a Gmail window title is Martin's own
  account, which is why his address is the only one he ever sees.
- There is no user-facing way to remove any of the four stores that drive the
  bad outcome (learned counts, primed surfaces, email rules, today's sticky).
  Only pins have a removal affordance, and only while the pinned surface is
  frontmost.

## Root cause(s), with evidence

### RC1 — capture is off: signals never carry email context

`ActivitySignal` has optional `correspondents` / `emailSubject` fields
(Sources/andeyeTTCore/Models.swift:79-95). The only production writer was the
sensor poll, added in 26522a2 (2026-06-30, "capture correspondents on
email-surface focus") and reverted the same day in 5439a83 because it froze
tracking. Today the poll emits signals with both fields nil, with an explicit
note (Sources/andeyeTTMac/Sensors.swift:107-113):

```
// NOTE: email correspondents are NOT fetched here — a synchronous
// Chrome AppleScript/JS call on this poll thread stalled the sampler
// and froze tracking (2026-06-30).
```

The only remaining code that produces correspondents is the dev diagnostic
button (Settings ▸ Diagnostics ▸ "Probe email sender" →
`AppController.probeEmailSender()`, Sources/andeyeTTMac/AppController.swift:1780,
calling `EmailSignalProbe.probeFrontBrowser` / `frontBrowserParties`,
Sources/andeyeTTMac/EmailSignalProbe.swift:35, 99). Its output goes to the
clipboard — it never touches a tracked signal.

Knock-on: `EmailContext.from(signal)` returns nil for every live signal
(Sources/andeyeTTCore/EmailMatch.swift:57-63, guard on non-empty
correspondents/subject). Therefore, for every real signal since 2026-06-30:

- `emailRuleMatch` never fires (Sources/andeyeTTCore/Attributor.swift:272-275)
  — the `.emailRule` ladder source is unreachable.
- `learnEmailRule` never learns (Attributor.swift:288-299) — corrections on
  Gmail teach nothing email-shaped.
- The session-sticky key falls through to the coarse focus surface instead of
  the email subject/correspondents (Attributor.swift:241-251).
- Pin fields `sender`/`subject` evaluate to `[]` / `""`
  (Sources/andeyeTTCore/PinRule.swift:21-25) — a `from contains "university.example"`
  pin can never match, silently.

So attribution for Gmail falls through to exactly the sources Martin is
seeing: primed surface and learned title/app/URL features.

### RC2 — Surface identity: all of Gmail is one surface

`Surface(signal:)` keys on URL host+path, fragment discarded
(Sources/andeyeTTCore/Models.swift:155-164). Gmail URLs are
`https://mail.google.com/mail/u/0/#inbox/<threadid>` — `URL.path` is
`/mail/u/0`, so EVERY Gmail page (inbox, any message, compose) is
`Surface(app: "Google Chrome", detail: "mail.google.com/mail/u/0")`.

Consequences:

- One correction primes the whole of Gmail: every teach path calls
  `attributor.assign`/`confirm`, which set
  `primedSurfaces[thatOneSurface] = task` (Attributor.swift:309-329). Call
  sites: popover "Change to" (AppController.swift:964), why-panel Teach
  (AppController.swift:1299), timeline reassign via dominant span
  (AppController.swift:1559-1563, 1621), split pieces
  (AppController.swift:1730), don't-track (AppController.swift:1571). A primed
  surface then wins at 0.95 for every subsequent Gmail visit
  (Attributor.swift:195-198).
- Because RC1 kills the email sticky key, categorising ONE email makes a
  `.surface` sticky for the whole of Gmail for the rest of the day at 0.95
  (Attributor.swift:158-164, 241-251) — one morning categorisation drags every
  later Gmail visit that day.

### RC3 — learning only accumulates; corrections never subtract

`LearningStore.correct()` (subtract from wrong, add to right —
Sources/andeyeTTCore/LearningStore.swift:64-67) exists but is NEVER called in
production (only in checks). Every teach path uses `learn(weight: 2)` (assign/
confirm) or 4-6 (Boost/pin fallback). So the counts "University
Teaching" accumulated on Gmail-generic features — `app=google chrome`,
`urlHost=mail.google.com`, `urlPath=mail.google.com/mail`,
`titleToken=gmail/inbox/mail`, plus `hourOfDay` — are permanent. Correcting a
Gmail slice to Task B adds weight to B but leaves GUT's mountain intact, and
the 0.95 primed-surface / sticky overrides sit above the ranked scores anyway,
so whichever task most recently won the single Gmail surface takes everything.

Note `urlPath` is host + FIRST path component only (LearningStore.swift:47-48)
— for Gmail that is always `mail.google.com/mail`. Like the Surface, the
learned URL features cannot distinguish one email from another.

## Why "University Teaching" specifically keeps winning

Mechanism, in order of force:

1. At some point Martin confirmed/corrected a Gmail window to GUT. That single
   act set `primedSurfaces["Google Chrome" / "mail.google.com/mail/u/0"] = GUT`
   (persisted in `primed.json`, AppController.swift:152, 201) and added
   weight-2+ learned counts to the Gmail-generic features above.
2. Every Gmail visit since matches that one surface → `.primedSurface` at 0.95
   (or `.ranked` with GUT top, since GUT holds the largest counts on the
   features every Gmail page shares).
3. Corrections don't durably dislodge it: (a) timeline reassignment teaches
   only the session's DOMINANT span (AppController.swift:1552-1563) — if the
   dominant window in the corrected slice wasn't the Gmail tab, the Gmail prime
   never moves; (b) even when the prime is re-pointed, the next correction
   back to GUT (a genuine GUT email does exist — the tasks are real) swings
   ALL of Gmail back again, whack-a-mole; (c) the learned counts for GUT are
   never decremented (RC3), so the ranked fallback always proposes GUT.
4. Same-day: one explicit categorisation to GUT stickies the whole of Gmail
   until midnight (RC2 sticky collapse).

A pin cannot be ruled out from code alone (pins are runtime state in
`pins.json`); if a pin whose rule covers Chrome/mail.google.com → GUT exists,
it would be absolute (1.0, Attributor.swift:148-154). Check on-device: the
popover pin badge while a Gmail tab is frontmost. There is no pin list UI to
inspect otherwise (see removal gap).

## Why the components list shows junk and no addresses

The why-panel (TimelineView.swift:1204-1229) prints
`learns on: <features>` where features =
`LearningStore.features(from: signal)` (Attributor.swift:399,
LearningStore.swift:35-53). That feature set is:

- `app` (lowercased app name)
- `titleToken` — EVERY ≥3-char alphanumeric token of the window title. A
  Chrome title like "High memory usage - Gmail" tokenises to `high`, `memory`,
  `usage`, `gmail` — hence the junk. A title like
  "Inbox (23) - martin@example.com - Gmail" tokenises to `inbox`, `martin`,
  `example`, `com`, `gmail` — hence Martin's OWN address (fragmented) is the
  only address he ever sees: it is in Gmail's window title; correspondents
  never are.
- `urlHost`, `urlPath`, `hourOfDay`.

There is NO feature kind for correspondents or subject — even while capture
was live on 2026-06-30, addresses never became learned features (deliberate:
only sensor-observed screen fields are featurised, per the compliance
invariant at LearningStore.swift:19-26 — though correspondents ARE
sensor-observed and could legitimately be added).

Additionally `AttributionExplanation` (Attributor.swift:56-92) has no email
evidence field at all, and journalled `FocusSpan.signal`s all have nil
correspondents (RC1), so the panel has nothing email-shaped to show even if it
wanted to. The `.emailRule` why-label string exists (TimelineView.swift:1239)
but is unreachable live.

## What "remove this outcome" must delete

Stored state that can drive Gmail → GUT, and its removability today:

| Store | File (Application Support) | Written by | User-facing removal today |
|---|---|---|---|
| Learned counts (`LearningStore`) | `learning.json` | every confirm/assign/boost (weight 2-6) | NONE. No view, no decrement (`correct()` unused), no reset |
| Primed surfaces | `primed.json` | every confirm/assign | NONE explicit. Only implicit overwrite by a NEW correction while the same (whole-of-Gmail) surface is dominant |
| Email rules | `emailrules.json` | `learnEmailRule` — live only on 2026-06-30, so may hold STALE rules from that day | NONE. Settings only reorders ladder LEVELS (SettingsView.swift:261-278); no rule list. Currently inert (RC1) but resurrects the moment capture is re-enabled |
| Pins | `pins.json` | explicit pin editor | Partial: ✕ unpins only the pin matching the CURRENT frontmost surface (AppController.swift:929-936). No pin list; a pin for a surface you're not on is unfindable |
| Session sticky | in-memory only | every confirm/assign (recordSticky) | NONE except relaunch or midnight (Attributor.swift:131, 224-235) |

"Un-learn Gmail → GUT" must therefore touch, atomically:

1. `primedSurfaces` — delete entries whose surface covers Gmail and target GUT.
2. `learning.json` — zero (or heavily decay) GUT's counts on the signal's
   features (`counts[f][target]`), not just add weight elsewhere. Hook exists:
   `Attributor.replaceLearning` (Attributor.swift:446-449); a
   `LearningStore.forget(target:features:)` needs writing.
3. `emailRules` — delete rules targeting GUT (there may be stale 06-30 ones).
4. Today's `sessionStickies` for the matching key.
5. Any matching pin.
6. Then `tracker.reevaluate()` + `persistAssociations()` (the pattern at
   AppController.swift:1299-1303).

## Constraints for the fix (the freeze history)

What actually froze (5439a83, 2026-06-30): the capture ran
`EmailSignalProbe.frontBrowserParties()` — a synchronous
`NSAppleScript.executeAndReturnError` round-trip into Chrome ("execute active
tab … javascript", EmailSignalProbe.swift:153-161) — inside `poll()`, which
runs on a `Timer.scheduledTimer` on the main run loop (Sensors.swift:61-67).
In Gmail every message switch is a URL change, so every surface change fired
the blocking call: the sampler stalled, focus changes were missed, and time
lumped onto the last task with frozen gaps.

The parked TODO (TODO.md:90-95) notes the base poll already runs the tab-URL
AppleScript + AX title read synchronously on the main actor every 2 s — same
hazard class, lower probability. Constraints for any re-enable:

- NEVER block `poll()` — capture must be fire-and-forget from the poll's
  perspective.
- `NSAppleScript` is main-thread-bound; "just background-queue it" is not
  safe as-is. Options: `osascript` subprocess with a hard timeout; or an
  `NSAppleScript` run on the main actor but scheduled as a separate async task
  with a deadline, rate-limited to one in-flight capture; or the AX targeted
  read (no Apple Events at all).
- Event-fed enrichment: emit the plain focus signal immediately (tracking
  never waits), then, when the capture returns (or times out), emit a
  follow-up enriched event that the tracker applies retroactively to the open
  span. `FocusSpan.signal` is already Codable with the email fields, so
  enriched spans journal cleanly; old rows decode (Models.swift:81 comment).
- Capture only on surface-change onto a `hasRecipe` email host, debounced;
  non-email focuses must pay only the host check (this was already the design
  in 26522a2 — the failure was synchrony, not selectivity).
- Handle the "Allow JavaScript from Apple Events" off state loudly, not
  silently: today `parties.error != nil` degrades to nil correspondents with
  no user-visible trace. Surface it once in Settings/diagnostics.
- On-device soak before trust (the 06-30 lesson: 191 green checks did not
  catch a main-thread stall).

## Recommended fix shape

Ordered; each independently shippable.

1. **Un-learn + evidence surfacing (S-M, 1-2 sessions).** Why-panel gains: the
   raw stored state behind the decision (the matching prime/sticky/rule/pin,
   named), an email-evidence block whenever `EmailContext` exists, and an
   "un-learn this" button doing the 6-step deletion above. Settings gains an
   email-rule list (view/delete/pin) and a pin list. This is fixable before —
   and independent of — capture, and it unblocks Martin's pain today.
2. **Async, event-fed capture re-enable (M, 2-3 sessions + soak).** Per the
   constraints above: immediate plain signal, deadline-bounded enrichment
   event, one in-flight capture, rate-limited, loud permission failure.
   Restores the whole already-built email subsystem (rules, ladder, sender/
   subject pins, subject-keyed stickies) that is currently dead.
3. **Fix the Gmail surface collapse (S, but touches learned keys).** Make
   surface identity recipe-aware: for a recognised email system, key the
   surface (and sticky) on the normalised subject / thread fragment rather
   than host+path; generically, include the URL fragment's first segment for
   fragment-routed SPAs. Without this, even with capture live, primes remain
   whole-of-Gmail. Existing primes in `primed.json` keep their old keys —
   harmless (they just stop matching) but consider a one-shot prune.
4. **Correspondent features in the learner (S).** Add `correspondent` /
   `correspondentDomain` feature kinds (sensor-observed, so compliant with the
   LearningStore invariant) so the ranked fallback and the why-panel both see
   addresses. Consider wiring `learning.correct()` into reassignment so
   corrections subtract (RC3).
5. **Generalise beyond Gmail (M-L).** Groundwork exists: `EmailSystem.detect`
   covers outlook/proton/yahoo/fastmail with recipe slots
   (EmailSystem.swift:18-44); recipes are data (selectors) intended for a
   shippable, updatable pack (TODO.md:246-255); `BackendPageRecognizer`
   (Attributor.swift:100-105) is the pluggable-recognizer pattern to mirror;
   and the host-as-signal policy (TODO.md:378-387, commit 6907245) supplies
   the non-email web-app story: URL host as a ladder level, sticky-on-unknown
   instead of yanking to the top guess. A "page recipe" should become a
   per-host plugin yielding (surface identity, evidence fields), with email
   systems as its first instances.

## History appendix (what was tried, in order)

- 2026-06-29: probe channel + Gmail recipe found (`.gD` sender, `.g2`
  recipients; blanket `[email]` queries polluted by ~100 inbox rows) —
  TODO.md:267-280.
- 30d8365 → 26522a2 (2026-06-30): Core auto-learner engine (EmailRule, ladder,
  `.emailRule` source), then live capture on email-surface focus.
- 5439a83 (2026-06-30, same day): capture REVERTED — synchronous AppleScript
  on the 2 s poll froze tracking; engine left in, inert. fd7a70f logged it
  (CHANGELOG.md:343-347).
- 5e9155d / c184325 (2026-07-01): pin grammar `from/sender/subject/any` +
  ladder reorder UI — both built atop the email fields that no live signal
  carries.
- 2de6163 (2026-07-02): session stickies — which, for Gmail, collapse to the
  one-surface key because of RC1+RC2.
- 086e6bc (2026-07-03): Martin's report; this diagnosis.
