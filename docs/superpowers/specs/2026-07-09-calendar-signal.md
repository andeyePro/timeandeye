# Calendar signal – realtime "what I'm supposed to be doing" + review-queue aid

Status: DESIGN (no code in this commit). Spec date 2026-07-09. Seeds a /vs
run once Martin has answered the open questions.

Update (same day, post-v1): Martin answered §0. Q1 confirmed as recommended;
Q2 confirmed (half weight) plus an explicit guard that a pin / high-certainty
app match beats even a CONFIRMED calendar event (checked as
CalendarPrecedence). Q3 superseded §6's mismatch-triggered flash with
TIME-based alerts: a quiet pulse from a configurable lead (default 5 min)
until the event starts, one violent flash at start, both default-ON, the
whole Settings subsection hidden while the signal is off; the popover
mismatch banner stays. See `CalendarAlerts` in CalendarMatch.swift and the
CalendarAlerts check suite for the shipped alert semantics.

Trigger (Martin, verbatim, 2026-07-09): "I think calendar integration is a
really obvious thing we should have done before, beyond the evil drawer it
means you should know in realtime what I'm supposed to be doing, so should
be able to better propose current time. The menu bar logo could even flash
if you're supposed to be doing something according to your calendar."
Earlier the same day he also wanted calendar as an aid for allocating OLD
review-queue items. Two asks, one signal: read-only EventKit access unlocks
both a live prior (what's on now) and a historical prior (what was on then).

## 0. Open questions for Martin (answer before /vs build starts)

1. **Which calendars feed the signal?** EventKit exposes every calendar the
   Mac's Calendar app knows about (personal, work, subscribed holidays,
   birthdays, shared). Recommend: on first grant, andeye watches every
   calendar of type `.calDAV`/`.local`/`.exchange` (the ones a person
   actually owns or is invited into) and excludes `.birthday` and
   `.subscription` calendars by default (holidays/birthdays are never "what
   you're supposed to be doing"); a Settings checklist lets you opt any
   calendar in or out afterwards. Confirm, or name calendars to
   include/exclude by hand instead of relying on the type heuristic.
2. **Tentative invites – count or ignore?** An invite you haven't
   accepted/declined might still be where you are. Recommend: tentative
   events count for the live prior and the flash at HALF weight (below,
   §3), never full weight – "maybe" shouldn't shout as loud as "yes".
   Confirm, or drop tentative entirely.
3. **Flash on/off by default, and how loud?** Recommend: ON by default,
   but capped to a slow, quiet pulse (§5 quantifies the cadence) – a menu
   bar glyph, not a notification. A Settings toggle turns it off entirely.
   Confirm the default, or ship it default-OFF for the first release so you
   opt in once you've seen it.
4. **Review-queue chip: how far back?** §6 shows a hint chip on drawer
   stacks that overlap a past calendar event. Recommend matching against
   events up to 90 days old (EventKit has no meaningful limit, but distant
   events are decreasingly useful and DB size grows). Confirm the window,
   or "no limit" (simplest, revisit if it's ever slow).

## 1. What the code says today (investigation)

- **Attribution has one score composition, reused everywhere.**
  `Attributor.attribute()` (Sources/andeyeTTCore/Attributor.swift) tries a
  strict ladder of early-exit sources first – pin (1.0) → session sticky
  (0.95) → OP task URL/title (0.95) → email rule (0.95) → pending
  prime/primed surface (0.7/0.95) – and only falls through to
  `scoredComponents()` (the ranked catch-all) when NONE of those fire.
  `scoredComponents()` blends a **learned** part (0.7 × learned
  association weight) and a **prior** part (project-page-scoped weight ×
  `TaskRanker.score()`, itself status + 2×recency + time-of-day), capped
  at 0.9. This is exactly where a calendar signal belongs: a THIRD prior
  component, added only to the ranked path, so it can never win over a
  pin, a sticky, a URL match or an email rule – it can only break ties and
  nudge the ambiguous cases the ranker already owns. The `min(0.9, …)`
  cap already there does the bounding for free.
- **`TaskRanker.score()` (Sources/andeyeTTCore/TaskRanker.swift)** is the
  one place status/recency/time-of-day combine into a single number, and
  it already feeds BOTH the Attributor's ranked path AND
  `recentThenRanked()` – the ordering behind the popover's pick list
  (`AppController.fullPickList()`). One new term here does double duty:
  it raises the live-matched task's attribution score AND moves it up the
  pick list. This is the mechanism behind "better propose current time" – no separate proposal engine needed.
- **`EmailMatch.swift`** is the precedent for a user-editable,
  general→specific matching ladder learned from corrections: `EmailRule`
  (level, value, target, pinned, createdAt, origin, fireCount, lastFired)
  + `EmailMatcher.match()` (most specific level wins; a pinned rule beats
  a learned one at the same level). `RulesLedger.swift` +
  `RulesLedgerView.swift` (Sources/andeyeTTCore, andeyeTTUI) are the
  existing audit surface: grouped-by-task, provenance line, fire count,
  forget with confirm+undo, plain-text export – all EmailRule-typed
  today, no generic protocol. Calendar rules need the identical shape
  (a keyword/attendee/calendar-name → task ladder) but are a distinct
  event vocabulary, so this spec adds a parallel `CalendarRule` type
  rather than forcing EmailRule to abstract over two domains it wasn't
  designed for.
- **`Sensors.swift`'s `SensorHub`** funnels every observation through one
  `onEvent` callback on the main thread (a hard C10 guard: emitters MUST
  be main-actor). It already polls at 2 s for focus/mic and listens for
  workspace/distributed notifications (sleep, wake, lock, unlock) via
  `NotificationCenter`/`DistributedNotificationCenter`. A calendar bridge
  fits the same shape: a new emitter class, its own (much slower) timer,
  wired into the same `onEvent` trampoline via a new `SensorEvent` case.
  There is no existing EventKit usage anywhere in the repo – this is a
  green field addition, not a refactor.
- **TCC permission precedent**: `scripts/make-app.sh`'s Info.plist already
  carries `NSAppleEventsUsageDescription` and `NSMicrophoneUsageDescription`
  strings, and `SensorHub.requestPermissions()` requests Accessibility via
  `AXIsProcessTrustedWithOptions`. Calendar access follows the same shape:
  add `NSCalendarsUsageDescription` (macOS 14+ full-access string; the
  bundle already targets `LSMinimumSystemVersion` 14.0, so the modern
  `requestFullAccessToEvents` API is available with no fallback needed)
  and request it once, lazily, the first time the feature is turned on – never at every launch (mirrors how Accessibility/Automation prompts
  already behave: ask once, degrade silently if refused, never nag).
- **The menu-bar logo** (`AndeyeLogoImage.swift` + `AppController.renderLogo`)
  is one drawn `NSImage`: mark + reserved-width text column, tinted by
  `menuColour` (certainty gradient, `MenuTitle.colour`). Two existing
  animation primitives already run as fire-and-forget `Task` frame loops
  driving redraws – `playDrawOn()` (one-shot, app launch) and `playWink()`
  (brief, on every task switch). A flash is a third, independent one:
  same shape (a `Task` looping a small parameter through `renderLogo()`),
  a new parameter, distinct cadence (rare, slow – never on every switch,
  never on every second tick).
- **No screen-share / presentation detection exists anywhere in the
  codebase.** Searched for `CGDisplayIsCaptured`, `isSharing`, window-list
  scanning – nothing. Building real screen-share detection (scanning
  `CGWindowListCopyWindowInfo` for known conferencing apps' sharing
  indicator windows) is a real, separate feature with its own false-positive
  risk, not a two-line addition. §5 designs the flash to stay safe WITHOUT
  it: it lives only in the menu bar (never mirrored unless the whole
  screen is shared, which is the user's own choice already), is capped to
  a slow, subtle pulse, and has a hard settings kill switch.
- **`ReviewStack`/`ReviewSegment`** (Sources/andeyeTTCore/ReviewStack.swift,
  Models.swift) already carry `start`/`end`/`app`/`windowTitle`/`tabURL`
  per segment – exactly the fields needed to test "did a calendar event
  overlap this slice", no new storage required for the review-queue hint.
- **Privacy precedent**: email correspondents/subjects are captured
  (`EmailCaptureEngine`, Sensors.swift) and used for matching, but never
  written to `DebugLog` – the one `DebugLog.write` call near email capture
  logs only the AppleScript failure, never message content. Calendar
  titles/attendees get the identical treatment (§7).

## 2. Principles

- **Never outrank an explicit signal.** A pin, a sticky, a URL/title match,
  a learned email rule – every one of these already means "the user (or a
  strong deterministic fact) told me". Calendar is a prior, like
  status/recency/time-of-day – it only speaks when nothing stronger has.
- **Ambient, not alarming.** The whole feature is about REDUCING cognitive
  load ("you don't have to remember your calendar") – a flashy,
  attention-grabbing implementation would fight its own goal. Subtlety is
  a requirement, not a nice-to-have (mirrors the wink's existing
  "acknowledge, don't announce" tone).
- **Calendars lie less than tabs, but they do lie.** A meeting that ran
  over, got cancelled in the room but not in the calendar, or that you
  skipped, are all common. The design must degrade gracefully when the
  calendar is wrong – bounded score bumps and an easy dismiss/mute, never
  an unstoppable override.
- **One matching vocabulary, proven once already.** Reuse the exact shape
  (general→specific ladder, learned from corrections, pin beats learned,
  audit ledger with provenance) that already shipped for email – new
  domain, same trusted mechanism, half the design risk.
- **Local-first, content stays local.** Calendar text is exactly as
  sensitive as email content already handled by this codebase – the same
  "never logged, never synced upstream in the clear" bar applies.

## 3. Read-only EventKit capture

New type in `andeyeTTMac` (EventKit is a macOS-only framework – no iOS
work in this spec; `andeyeTTPhone` gets a manual "what's on now" glance at
most, noted as later):

```
final class CalendarBridge {
    var onEvent: ([CalendarEvent]) -> Void   // wired into SensorHub's onEvent trampoline
    func requestAccess(completion: @escaping (Bool) -> Void)   // EKEventStore.requestFullAccessToEvents
    func start()   // begins observing + first fetch
    func stop()
}
```

- **Store query**: `EKEventStore.events(matching:)` over a rolling window – today's local midnight − 1 day to + 2 days (covers overnight events
  and gives the pick-list "what's next" a lookahead without re-querying
  constantly). Re-fetch on: (a) `EKEventStoreChanged` notification – covers external edits/new invites; (b) `NSWorkspace.didWakeNotification` – the Mac may have missed changes while asleep; (c) a defensive 5-minute
  fallback timer, because notification delivery isn't 100% guaranteed
  after a long background period. This is deliberately NOT the 2 s poll
  cadence the focus sensor uses – calendars don't need sub-minute
  freshness, and fetching a whole event window every 2 s would be wasted
  work and (per the C10 main-thread guard) main-thread contention for no
  benefit.
- **All-day events**: excluded from the live-prior match (an all-day
  "Annual leave" or "Sprint N" banner isn't "what you're doing this
  minute") but ARE kept in the fetched window and DO qualify for the
  review-queue historical hint (§6) – a past all-day event overlapping a
  drawer stack ("Annual leave" over a queued Tuesday) is exactly the kind
  of context Martin asked calendar-as-aid to supply.
- **Declined events**: excluded everywhere. `EKEvent.hasAttendees` +
  checking the local user's own `EKParticipant.participantStatus ==
  .declined` filters these at fetch time – never propose or flash for a
  meeting you said no to.
- **Tentative events**: included at half weight everywhere (§0 Q2's
  recommendation) – a real signal, just a softer one.
- **Cancelled events**: `EKEvent` for a cancelled instance of a recurring
  series simply won't appear in the query result (EventKit's own
  semantics) – no extra filtering needed.
- **Busy/free (`availability`)**: events marked `.free` are excluded from
  the live prior and the flash (a calendar hold that isn't really
  "working", e.g. a lunch block marked free) but, like all-day events,
  still count for the review-queue hint.

## 4. Event → task matching – the same ladder shape as email

New parallel type in `andeyeTTCore` (Sources/andeyeTTCore/CalendarMatch.swift):

```
public enum CalendarMatchLevel: String, CaseIterable, Codable, Sendable {
    case calendarName     // "all events in this calendar" – broadest
    case attendee         // a specific person's email/name on the invite
    case titleKeyword     // a word/phrase in the event title – most specific

    public static let defaultOrder: [CalendarMatchLevel] =
        [.calendarName, .attendee, .titleKeyword]
}

public struct CalendarRule: Equatable, Codable, Sendable {
    public let level: CalendarMatchLevel
    public let value: String          // calendar name / attendee address / title substring
    public let target: TaskRef
    public let pinned: Bool
    public var createdAt: Date
    public var origin: EmailRule.Origin   // reuse: .correction / .card / .ledger / .migrated
    public var fireCount: Int
    public var lastFired: Date?
}

public enum CalendarMatcher {
    public static func match(_ event: CalendarEvent, rules: [CalendarRule],
                             order: [CalendarMatchLevel] = CalendarMatchLevel.defaultOrder) -> CalendarRule?
}
```

`CalendarEvent` (the Core-side plain struct the mac bridge maps `EKEvent`
into, keeping EventKit types out of Core exactly as `ActivitySignal` keeps
AppKit out): `title: String`, `calendarName: String`, `attendees: [String]`
(lowercased emails where available, else display names), `start`/`end:
Date`, `isAllDay: Bool`, `availability: .busy/.free/.tentative/.unknown`,
`status: .confirmed/.tentative` (the local user's own RSVP).

- **Matching mirrors `EmailMatcher.match()` exactly**: walk the order
  general→specific, most specific level with any match wins, a pinned
  rule beats a learned one at the same level, newest unpinned wins ties.
- **Learning**: a rule is learned the same way an email rule is – when a
  correction lands (`assignReview`/`assignStack`/timeline reassign) WHILE
  a calendar event is live and either matched nothing or matched a
  DIFFERENT task, the correction teaches a new `titleKeyword` rule from
  the event's title (the most specific, safest default grain – matches
  the email ladder's own bias toward learning at the narrowest grain
  first). Exactly like `EmailRule`, this only fires on a real teach path,
  never on `explain()`.
- **Explicit mapping UI**: today's Rules Ledger (`RulesLedgerView.swift`)
  is view/search/delete only – there is no "+ rule" manual-add anywhere
  yet, for email or otherwise. Martin's calendar-as-review-aid use case
  wants to map an event pattern to a task WITHOUT waiting for a
  correction to teach it. Add the manual add row to the SAME ledger
  window (a small form: level picker, value field, task picker, "Add"),
  gated behind a segmented control at the top of `RulesLedgerView`
  ("Email" / "Calendar") that switches which rule list and add-form show – reuses the existing list/group/delete/undo chrome unchanged, since
  `RulesLedgerGroup` becomes generic-enough over `[EmailRule]` or
  `[CalendarRule]` by duplicating the (small) grouping/export functions
  rather than forcing a shared protocol on two rule types that don't
  otherwise need one (least-code path; a shared protocol is a nice
  later refactor once there's a third rule domain to justify it).

## 5. The live prior – bounded score bump, never an override

Extend `TaskRanker.score()` with a third additive term, parallel to the
existing `todScore` (time-of-day):

```
var calendarScore = 0.0
if let matched, matched.task == task.ref {
    calendarScore = matched.tentative ? 0.5 : 1.0   // half weight for tentative (§0 Q2)
}
score = statusScore + 2 * recencyScore + todScore + 0.3 * calendarScore
```

- `0.3` keeps the calendar term's ceiling below recency's `2×` weight – a
  live meeting nudges the ranking, it doesn't dominate a task you're
  demonstrably, recently working on.
- Because this feeds `scoredComponents()`'s `prior` part (itself weighted
  0.2–0.65 and then `min(0.9, …)`-capped), the WORST case is: an ambiguous
  signal (nothing else matched) whose top candidate is now the
  calendar-matched task at up to 0.9 – still below the 0.95 inferred
  ceiling every real match (pin/sticky/URL/emailRule) already claims, and
  miles below a pin's 1.0. This is the "bounded, never overrides a pin"
  requirement, satisfied structurally by the existing cap rather than a
  new special case.
- `AttributionExplanation.Line` gains a `calendarPart: Double` field
  alongside `learned`/`prior`, so the Evidence Card's "why" breakdown can
  show "boosted because 'Weekly Standup' is on now" – explainability for
  free, matching the existing card's honesty bar (never claim a boost
  that didn't happen).
- The SAME `calendarScore` term flows into `recentThenRanked()` (used by
  `AppController.fullPickList()`), which is what makes the popover
  "propose current time" without a second mechanism.
- **The pick-list "now:" affordance**: `taskRow` in `PopoverView.swift`
  gains a small badge, styled like the existing house/billable glyphs – a clock glyph with the event title as its tooltip – shown on whichever
  task is the CURRENT live match (exposed as
  `AppController.currentCalendarMatch: (task: TaskRef, eventTitle: String,
  tentative: Bool)?`, recomputed whenever the bridge emits a fresh event
  window or a poll crosses an event's start/end boundary). This is
  cosmetic on top of the ranking boost, not a separate ranking path.

## 6. The off-calendar flash

`currentCalendarMatch` (§5) gives andeye "what you're supposed to be
doing"; comparing it to the actually-tracked target gives the mismatch:

- **Condition**: a live match exists (busy/tentative, non-all-day, not
  declined) AND the session tracker's current target differs from it AND
  the mismatch has held for a settle window (recommend 3 minutes – long
  enough that walking into a meeting room doesn't flash before you've
  even opened your laptop, short enough to still be "realtime").
- **Cadence**: a slow pulse – TWO brief tint-shifts about a second apart,
  once every 90 seconds while the mismatch persists, using the exact same
  `Task`-frame-loop shape as `playWink()` but on its own timer, not
  triggered by every render. This is quantitatively far rarer than the
  once-per-switch wink, by design – it's a standing reminder, not an
  event notification.
- **Colour**: a fixed amber/warning tint (distinct from the certainty
  gradient `menuColour` already carries – the flash briefly LERPS toward
  it and back, it never replaces the persistent tint), so it reads as "a
  different kind of signal" from the certainty colour at a glance.
- **Settings**: one toggle, "Flash when off-calendar" (§0 Q3 default),
  living next to the existing colour/percent toggles in Settings.
- **Click behaviour**: clicking the menu-bar item already opens the
  popover – no new gesture needed. The popover, when a mismatch is live,
  shows a one-line banner above the pick list: "Calendar says: Weekly
  Standup – [Switch]" where `[Switch]` is a single button that calls the
  exact same `userPicked()` path a manual pick would (teaches the ranker
  and the calendar rule ladder identically to any other correction – no
  parallel code path to keep in sync).
- **Safety valve without screen-share detection** (per §1's finding that
  no such sensor exists): the flash is capped to the menu bar only, at a
  quiet cadence, with a hard off switch – the three mitigations available
  without building a new detection feature. Real screen-share suppression
  is v-later (§9) if it turns out to matter in practice.

## 7. Review-queue aid – past events as an allocation hint

- For each `ReviewStack` shown in `ReviewView`, compute whether any fetched
  calendar event (§0 Q4's window, default 90 days) overlaps the stack's
  `first...last` span. Reuse `CalendarMatcher.match()` against that
  event exactly as the live prior does – if it resolves to a task, show a
  small hint chip in the stack row: "Weekly Standup → Client X (calendar)"
  with a one-click "Assign" that runs the SAME `assign()` path the
  existing pick buttons use (teaches the calendar rule ladder from the
  acceptance, same as any other correction).
- This is read-only lookup at render time (no new persistence) – the
  drawer already re-renders on `controller.pendingReview` changes, and a
  90-day event fetch is cheap compared to the journal work
  already happening there.
- All-day and free-marked events are INCLUDED here (§3) – "Annual leave"
  overlapping a queued day is a legitimate allocation hint ("this was
  never work, sweep to Do not track") even though it's excluded from the
  live prior.

## 8. Privacy posture

- Calendar event titles, attendee lists and calendar names are used ONLY
  for local matching (§4) and ONLY ever displayed inside andeye's own UI
  (the badge tooltip, the mismatch banner, the review-queue chip). They
  are never written to `DebugLog` (mirrors the existing email-capture
  precedent exactly – the one log line near email capture logs only the
  AppleScript error, never message content).
- A learned or manually-added `CalendarRule`'s `value` (a keyword,
  attendee address, or calendar name) DOES persist to disk – same as an
  `EmailRule`'s correspondent/domain already does. This is already the
  accepted bar (email addresses are more sensitive than a meeting title)
  so no new posture is being introduced, just extended to a second
  domain.
- Nothing calendar-derived is ever pushed to the OP/Xero backend or any
  sync transport beyond the user's own devices – it's a LOCAL prior on
  LOCAL attribution, exactly like every other prior in the ranker.
- `CalendarRule`'s ledger export (`RulesLedger.exportText`-equivalent)
  includes the same fields the email export already includes (grain,
  value, provenance, fire count) – no additional redaction needed since
  the export already only ever shows what the user themselves is looking
  at (a "Copy rules" clipboard action, not a shared log).

## 9. Acceptance criteria (a /vs build can verify, andeyeTTChecks style)

1. `CalendarMatcher.match()`: general→specific resolution order, pinned
   beats learned at the same level, newest unpinned wins ties – same
   scenarios as the existing `EmailMatch` checks, ported to the calendar
   vocabulary.
2. A live calendar match raises the matched task's `TaskRanker.score()` by
   exactly the quantified amount (§5); a NON-matched task's score is
   unaffected; a tentative match raises it at half weight.
3. The ranker boost never lets a ranked-path score reach the 0.95 inferred
   ceiling (regression check tied to the existing `min(0.9, …)` cap) – proves "never overrides a pin" structurally, not just by convention.
4. A pin, sticky, URL match, or email rule for the SAME signal wins over
   any calendar match regardless of calendar state (the ladder order is
   unchanged; calendar only ever reaches the ranked fallback).
5. An all-day, free-marked, or declined event never produces a live-prior
   boost or a flash condition; a tentative event does, at half weight;
   an all-day event DOES produce a review-queue hint.
6. Off-calendar mismatch detection: given a live match and a different
   current target held past the settle window, the mismatch flag is true;
   clearing either condition (target changes to match, or the event ends)
   clears it within one tick.
7. Review-queue hint: a stack whose span overlaps a matched past event
   produces the expected chip target; a stack with no overlapping event
   produces none; events older than the configured window are excluded.
8. A correction made while a calendar event is live teaches a
   `titleKeyword` `CalendarRule` at `origin: .correction`, fire count 0,
   exactly like an `EmailRule` learned the same way.
9. Ledger: `CalendarRule`s group/sort/export identically to `EmailRule`s
   (parallel test suite, same assertions against the calendar type).

Everything above is pure Core/TaskRanker/CalendarMatcher logic – no
EventKit, no AppKit, no live calendar needed to check it; `CalendarEvent`
is a plain seedable struct like `ActivitySignal` already is.

## 10. v1 scope vs later

**v1 (one /vs run, buildable in one session)**: `CalendarBridge` read-only
capture (§3) behind a lazy permission request; `CalendarMatchLevel`/
`CalendarRule`/`CalendarMatcher` (§4) with correction-taught learning;
the `TaskRanker` calendar term feeding both the live-prior score bump and
`fullPickList()` (§5); the pick-list "now:" badge; the off-calendar flash
with its settings toggle and popover mismatch banner (§6); the
review-queue hint chip (§7); checks 1–9.

**Later**: the Rules Ledger's segmented Email/Calendar view + manual "+
rule" add form (§4) – v1 can ship calendar-rule learning without a manual
UI, since corrections already teach it, same as email did before its own
ledger existed; real screen-share/presentation detection to suppress the
flash during a shared screen (§6) – not built anywhere in this codebase
today, and the current mitigations (menu-bar-only, quiet cadence, hard
off switch) cover the risk adequately for v1; iOS calendar glance in
`andeyeTTPhone` (EventKit is available on iOS too, but this spec is
Mac-sensor-first per the module map); recurring-event-aware "next event"
lookahead in the popover (a natural follow-on to the "now:" badge, but a
distinct feature – "what's next" vs "what's now").
