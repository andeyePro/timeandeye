# Context rules UX — see why, un-learn in one click, rule at the right grain

Status: DESIGN (no code in this commit). Spec date 2026-07-03.

## 1. Requirements (Martin's words, distilled)

Verbatim anchors:

> "I don't want to have to pin every single email, but at the same time I do
> need the ability to pin them by correspondent email address and domain. We
> need a really intuitive interface for this."

> "…ideally one that will work beyond Gmail and into other web pages where the
> app, URL and title aren't enough to give you what you need for accurate task
> allocation."

Plus two needs raised alongside: he must be able to **remove a painful learned
outcome** (an un-learn affordance), and he must be able to **see the evidence**
(correspondent / domain / subject) the app used.

Distilled requirements:

- **R1 — See why.** From the moment of noticing a wrong attribution, show WHY:
  the source that fired (pin / sticky / email rule / prime / ranker) AND the
  evidence it keyed on — correspondent address, domain, subject when present;
  app / title / URL always.
- **R2 — Un-learn in one action.** Whatever learned thing caused the wrong
  outcome (an EmailRule, a primed surface, a session sticky, learned
  association weight), one click removes it. No hunting.
- **R3 — Durable rule at the right grain.** Create "mail to/from this address →
  task", "this domain → task", "this subject → task", "this site-section →
  task" in one flow, without pinning every email. Pinned (100 %, standing law)
  and learned (0.95, revisable) must both be reachable from the same flow.
- **R4 — Generalise beyond email.** The same interaction must work on any web
  app where URL + title are insufficient (client portal, web CRM) via site
  "recipes" — per-site extractors that surface fields (client name, project
  code, ticket id) as rule dimensions. `EmailSystem.senderSelector` is already
  a recipe in embryo (a DOM selector as data, Gmail validated).
- **R5 — Fit the existing model.** Pin > sessionSticky > OP-URL > emailRule >
  primes > ranker stays. Inferred ceiling 0.95, pins alone 1.0. The email
  ladder (system → domain → correspondent → subject, user-reorderable) stays
  the resolution order.

Existing machinery this builds on (read first: `Attributor.swift`,
`EmailMatch.swift`, `PinRule.swift`, `PinScope.swift`, `TimelineView.swift`
detail panes, `PopoverView.swift` pin editor, `SettingsView.swift` ladder UI):

- `AttributionExplanation` already mirrors `attribute()` exactly — the "why"
  data exists; only its presentation (a monospaced text dump) and its
  actionability (none) are lacking.
- `EmailRule` already has a `pinned` flag; there is **no UI at all today** to
  list, edit or delete email rules — they are learned silently by
  `learnEmailRule` on every correction and only replaceable by another
  correction. That silence is the root of the "painful learned outcome"
  problem.
- The pin editor's blue/grey broad→narrow prefix strip is the app's one proven
  "pick a grain" interaction (← wider, → narrower, click a part, ↵ commits).

---

## 2. The three options

All three keep the attribution ladder untouched; they differ in WHERE the user
meets the evidence and HOW the grain choice is made.

### Option A — the Evidence Card ("Because…")

One structured card, shown wherever the user asks "why?", that (top to bottom)
names the decision, shows the evidence as labelled rows, offers the un-learn on
the exact rule that fired, and folds the fix + grain choice into the same card.
The card replaces the timeline's monospaced why-text and is reachable from the
popover via a one-line "why" caption under the header.

Timeline (window clicked in the detail strip):

```
┌──────────────────────────────────────────────────────────────────┐
│ Chrome – Re: Insurance Renewals 2026        14:02–14:09 · 7m     │
│ tracked as  Insurance Renewals   ·  95% certain                  │
│                                                                  │
│ BECAUSE  a learned rule fired:                                   │
│   ✉ harborlane.example → Insurance Renewals                     │
│     learned 12 Jun from your correction · fired 8×    [✕ forget] │
│                                                                  │
│ EVIDENCE (what andeye saw)                                       │
│   app            Google Chrome                                   │
│   site           mail.google.com  (Gmail)                        │
│   correspondent  r.naismith@harborlane.example                  │
│   domain         harborlane.example                              │
│   subject        Re: Insurance Renewals 2026                     │
│                                                                  │
│ WRONG TASK?  file as  [filter tasks…            ]                │
│   and remember for…                                              │
│   ( ) just this once                     (today, this thread)    │
│   (•) this domain     harborlane.example                         │
│   ( ) this address    r.naismith@harborlane.example             │
│   ( ) this subject    "Insurance Renewals 2026"                  │
│   ( ) all Gmail                                                  │
│                              [Remember]   [Remember always 📌]   │
└──────────────────────────────────────────────────────────────────┘
```

The `[✕ forget]` is R2: it deletes exactly the learned thing that fired
(EmailRule / primed surface / sticky / negative-weight the association for a
ranked source), and the card re-renders live showing what would fire instead
("would now fall back to: learned associations → andeye 62%"). Undo-able.

Popover (compact; the card opens in place under the header):

```
┌────────────────────────────────┐
│ Insurance Renewals             │
│ 7m · 95% · why? ✉ harborlane │  ← caption line, click to expand
│ ┌────────────────────────────┐ │
│ │ ✉ harborlane.example       │ │
│ │   → Insurance Renewals     │ │
│ │   fired 8× · [✕ forget]    │ │
│ │ from r.naismith@harborlan… │ │
│ │ subj Re: Insurance Renewa… │ │
│ │ wrong? [filter tasks…    ] │ │
│ │ (•) domain ( ) address     │ │
│ │ ( ) subject ( ) once       │ │
│ │ [Remember] [Always 📌]     │ │
│ └────────────────────────────┘ │
│ ── Switch to ────────────────  │
│ …task list…                    │
└────────────────────────────────┘
```

Interaction flows:

- **From the timeline**: click slice → click window chip → Evidence Card
  replaces today's monospaced pane. Fix + grain in place. Also: reassigning
  windows via the existing move-strip now shows the card's grain row inline
  ("remember for: (•) domain …") instead of learning silently.
- **From the popover**: the certainty caption grows a "why?" suffix showing
  the winning source glyph + value. Click → card expands inline (popover grows
  vertically; no modal). Fixing from here relabels the current session
  (Change-to semantics) and applies the chosen grain.
- **From the review queue**: assign bar gains the same grain row when the
  selected segments carry email context.

Existing weight controls: the "move windows to task" teaching stays and is the
card's "just this once" path (sticky + soft prime + learn weight 2, exactly
today's `confirm`/`assign`). The Boost-style heavier teaching disappears as a
separate control — choosing a grain IS the stronger teaching now (it writes a
deterministic EmailRule / site rule, no weights to fiddle).

Edge cases:

- **No correspondent captured** (no recipe for this site, or capture off):
  evidence rows show `correspondent — not captured` with a `[set up capture…]`
  affordance (→ recipes, Settings); the grain radio hides address/domain rows
  and offers title/URL-section grains instead (falls back to PinScope
  segments).
- **Shared webmail domain** (gmail.com et al., `Attributor.sharedWebmailDomains`):
  domain row renders `gmail.com — shared domain, matches everyone` greyed; the
  default radio selection moves to "this address" (mirrors `learnEmailRule`'s
  conservatism).
- **Multiple correspondents**: correspondent row becomes a disclosure listing
  all counterparties with checkboxes; "this address" applies to the checked
  ones (one rule each). Default = the first (the sender for inbound mail).
- **Rule and evidence disagree in level order**: the card always names the rule
  that ACTUALLY fired per the user's ladder order, so a reordered ladder never
  lies.

Implementation surface: `TimelineView.detailText` → new `EvidenceCardView`
(andeyeTTUI, shared by timeline + popover + review); `PopoverView.header` gains
the why-caption; `Attributor` gains `unlearn(_ explanation:)` +
`explain()` extended to carry the matched EmailRule and its metadata;
`EmailRule` gains `createdAt`/`fireCount`; `AppController` persistence bump.
`SettingsView` untouched except the recipe hook.

### Option B — the Grain Strip (one broad→narrow selector everywhere)

Generalise the pin editor's proven blue/grey prefix strip into THE grain
picker for every context, email included. A context's identity becomes one
broad→narrow segment chain; email fields are segments; recipe-extracted fields
are segments. Clicking a segment sets the grain; ← widens; → narrows; ↵
remembers (learned rule); ⇧↵ pins (100 %); esc = just this once.

Identity chains:

```
email:   Gmail ▸ harborlane.example ▸ r.naismith@ ▸ "Insurance Renewals"
CRM:     crm.foocorp.com ▸ clients ▸ Acme Ltd ▸ "Q3 rebrand"
                                    └ recipe-extracted, marked ◆
plain:   github.com ▸ andeyePro ▸ andeyeTT ▸ issues        (unchanged today)
```

Popover: picking a different task while an email/recipe surface is focused
slides the strip in under the task list (where the pin editor appears today):

```
┌────────────────────────────────────┐
│ Changed to  Northgate Insurance ✓     │
│ remember for…                      │
│  Gmail ▸ harborlane.example ▸ r.n… │
│  [grey]  [■■■■ blue ■■■■]  [grey]  │
│  ← wider · → narrower · click part │
│  ↵ remember · ⇧↵ always 📌 · esc   │
│    once                            │
└────────────────────────────────────┘
```

The segment a CURRENT rule matched carries a small underline + glyph; clicking
that glyph shows "rule: harborlane.example → Insurance Renewals · [✕ forget]".
So why-evidence and un-learn live inside the same strip: the strip IS the
evidence (each segment is one observed field, labelled on hover).

Timeline: the window detail pane keeps a compacted "why" line but its fix
action opens the same strip inline; the move-to-task strip commit shows the
strip pre-selected at the conservative default grain, ↵ confirms.

```
│ why: ✉ rule on [harborlane.example]̲ → Insurance · 8× · ✕     │
│ fix: move to [filter tasks…] then                            │
│  Gmail ▸ harborlane.example ▸ r.naismith@ ▸ "Insurance Re…" │
│         [■■■■■■■■■■■■■■■■■]                                  │
│  ↵ remember at blue grain · ⇧↵ always · esc once             │
```

Existing weight controls: same as A — grain commit writes a deterministic
rule; esc/once = today's soft teaching. The pin editor's Components mode and
this strip UNIFY (one component: a strip fed by identity segments; PinScope
prefix pins are the no-recipe case). Expression and AI modes remain the
hamburger's power tools and gain `from`/`subject` parity they already have.

Edge cases:

- **No correspondent captured**: the chain is `Gmail ▸ "subject…"` only, with a
  ghost segment `▸ (sender not captured — set up)` linking to recipes.
- **Shared webmail**: the domain segment renders with a caution tint and the
  default blue selection skips past it to the address segment; selecting it
  anyway warns inline ("matches ALL gmail.com mail").
- **Multiple correspondents**: the correspondent segment shows `r.naismith@ +2
  ▾`; clicking cycles / a hover popover picks which counterparty the segment
  represents before widening/narrowing.
- **Segment order vs ladder order**: strip order is display-only
  (general→specific per the settings ladder); reordering the ladder in
  Settings reorders strips app-wide.

Implementation surface: new `ContextIdentity` in andeyeTTCore merging
`PinScope.identity(of:)` + `EmailContext` + recipes into one segment list with
kinds; `PopoverView` pin editor's `componentsEditor` generalised and reused;
`TimelineView` detail pane gains the strip; commit path writes `EmailRule`
(learned/pinned) or `Pin` depending on segment kind. Settings ladder section
unchanged.

### Option C — Learn-Toast + Rules Ledger

Keep correction exactly as light as today (pick a task; move a window) and add
two things: (1) a transient, actionable **toast** every time a durable rule is
learned or fires for the first time, and (2) a **Context Rules ledger** — one
window listing every learned and pinned rule with per-row forget / re-grain /
promote-to-pin. The why-moment stays in the timeline pane (upgraded copy), but
management is centralised.

Toast (popover foot + optional system notification, 6 s, then gone):

```
┌────────────────────────────────────┐
│ ✓ Learned: harborlane.example      │
│   → Northgate Insurance               │
│   [address instead] [undo] [📌]    │
└────────────────────────────────────┘
```

Ledger (window, from Settings and the popover gear menu):

```
┌───────────────────────────────────────────────────────────────────┐
│ Context rules                    [search rules…      ]  [+ rule]  │
│                                                                   │
│ ▾ Northgate Insurance (3)                                            │
│    ✉ domain    harborlane.example     learned · 8× · 12 Jun    ✕ │
│    ✉ address   b.smith@gmail.com      learned · 2× · 28 Jun    ✕ │
│    📌 url      op.example.com/insur…   pinned  · —              ✕ │
│ ▾ andeye (2)                                                      │
│    📌 app      Ghostty ▸ andeye       pinned                   ✕ │
│    ✉ subject  "TestFlight"            learned · 1× · 30 Jun    ✕ │
│ ▸ Do not track (4)                                                │
│                                                                   │
│ Site recipes:  Gmail ✓ · Outlook — · foocorp CRM ✓   [manage…]   │
└───────────────────────────────────────────────────────────────────┘
```

Row click → inline editor: grain popup (address/domain/subject/system for ✉;
prefix strip for 📌), target task, pinned toggle, "last 5 matches" preview so
the user can see what the rule has been catching.

Interaction flows:

- **From the popover**: correction = pick a task (today's flow, zero new
  steps). The toast then surfaces what was learned; `[undo]` deletes the rule,
  `[address instead]` flips the grain, `[📌]` promotes to a pin. Missed the
  toast? The ledger holds everything.
- **From the timeline**: why-pane keeps today's structure but the source line
  becomes a link: "why: ✉ rule harborlane.example → Insurance (view rule)" →
  opens the ledger scrolled to that rule, where forget/re-grain live.
- **First-fire toast**: the first time a rule silently reallocates time, toast
  "✉ harborlane.example filed this to Insurance Renewals [undo] [rules…]" —
  catches bad rules at the first symptom, not after a painful week.

Existing weight controls: untouched. The ledger only manages deterministic
rules (EmailRule + Pin); ranked-learner weights stay invisible (a "reset
learning for this task" row action is the only exposure).

Edge cases:

- **No correspondent captured**: nothing was learned, so no toast; the ledger's
  recipe strip shows the site as un-recipe'd — the discoverable path to fixing
  capture.
- **Shared webmail**: `learnEmailRule` already learns the address; the toast
  says so explicitly ("gmail.com is shared — learned the address instead").
- **Multiple correspondents**: toast names the one learned; `[address
  instead]` opens a chooser listing all counterparties.
- **Toast fatigue**: only on NEW rules and first-fires, never on every match;
  a Settings toggle silences toasts entirely (ledger remains).

Implementation surface: new `RulesLedgerView` window (andeyeTTUI) + scene in
`RootScenes`; toast host in `PopoverView` (and optional `systemNotifications`
reuse); `AppController` exposes `emailRules`/`pins` as published lists with
delete/edit; timeline pane gets the "view rule" link only. Biggest new-surface
option, smallest change to existing flows.

---

## 3. Focus groups

Four personas, run as four parallel independent evaluator agents, each scoring
all three options 1–10 on: discoverability, speed-to-fix,
control-without-tedium, generalisation beyond Gmail, privacy comfort. Quotes
are verbatim from the evaluators' output.

### Scores

| persona / criterion              | A: Evidence Card | B: Grain Strip | C: Toast + Ledger |
|----------------------------------|:---:|:---:|:---:|
| **Martin** (power user, terse)   | 8 · 7 · 8 · 7 · 9 = **39** | 7 · 10 · 9 · 9 · 7 = **42** | 6 · 6 · 6 · 7 · 9 = **34** |
| **Priya** (designer, 5 clients, Gmail all day) | 8 · 7 · 9 · 6 · 8 = **38** | 5 · 7 · 7 · 9 · 7 = **35** | 8 · 9 · 8 · 5 · 6 = **36** |
| **Doug** (consultant, web CRM + Xero, no manuals) | 9 · 7 · 7 · 7 · 8 = **38** | 5 · 7 · 6 · 7 · 6 = **31** | 5 · 8 · 6 · 3 · 7 = **29** |
| **Sam** (privacy-sensitive engineer) | 8 · 9 · 8 · 6 · 7 = **38** | 5 · 8 · 8 · 9 · 5 = **35** | 7 · 6 · 7 · 7 · 9 = **36** |
| **Total**                        | **153** | **143** | **135** |

(criteria order: discoverability · speed-to-fix · control-without-tedium ·
generalisation · privacy)

First choices: Martin → B; Doug → A; Priya → C; Sam → C (privacy-weighted;
A won Sam's raw sum). A is the only option no persona ranked last.

### Key verbatim quotes

**Martin** (ranked B > A > C):

> "The strip already lives in my fingers — don't teach me a second grammar for
> the same question."

> [on A] "But the grain picker is radio buttons. Radios mean mouse, mean
> Tab-Space-Tab-Space, mean a form. I already have a grain picker in my
> fingers — the pin strip — and this invents a second grammar for the same
> question."

> [on B's weakness] "un-learn hides behind a small glyph on an underlined
> segment, and evidence is hover-only — I'd find it because I built it; a
> fresh me wouldn't." The fix path is "pick task, → →, ↵. Three keystrokes.
> That's the number that matters."

> Graft: "C's first-fire toast into B — a bad grain surfaces at the first
> symptom instead of a week of wrong time. (Runner-up graft: A's labelled
> evidence rows as the strip's expanded view, so evidence isn't hover-only.)"

**Priya** (ranked C > A > B):

> "Fixing it feels like archiving an email — one tap — and the toast tells me
> it just learned the right thing for that client forever. The ledger is my
> pre-invoice audit."

> [on A] "The card reads like a receipt … the 'wrong task?' radios are exactly
> my mental model: this domain = this client", and the shared-gmail default
> "alone probably saves me a mis-billed invoice."

> [on B] "When I'm annoyed that 40 minutes went to the wrong client, I don't
> want to feel like I'm operating a slider puzzle."

> [on C's flaws] toasts naming clients during screen-shares are "a genuine
> problem"; and on an un-recipe'd site "the fix doesn't stick where I made
> it."

> Graft: A's card — with the live "would now fall back to…" preview — as what
> opens from C's ledger rows and the timeline's "view rule" link. "And
> whatever wins: suppress toasts automatically while screen-sharing."

**Doug** (ranked A > B > C):

> "The Evidence Card ambushes me with the fix at the exact second I'm annoyed —
> and that's the only second of my attention this feature will ever get."

> [on recipes] "'correspondent — not captured [set up capture…]' right there
> in the box — that's the one and only moment I'd ever click a set-up link …
> if it's 'paste a DOM selector' I'm out, if it's 'click the bit of the page
> that says the client name' I'm in."

> [on B] "I'd click a segment, nothing visibly commits, I'd wonder if it took,
> and I'd close the popover — a fix I'm not sure landed is worse than no fix."

> [on C] "I will die of old age before I open that window … for me the app
> just stays silently wrong on the two sites where I earn my living."

> Graft: "take Option C's first-fire toast and bolt it onto A … opening
> straight into the Evidence Card, and I never see a rotten week."

**Sam** (ranked C > A > B):

> "The ledger is the difference between a tracker that *behaves* and a tracker
> I can *audit* — I don't want to trust the toast, I want to be able to check
> its receipts."

> [on A] "`[✕ forget]` deleting precisely the thing that fired — with a live
> re-render of what would fire instead — is real engineering honesty, not a
> placebo button. … Great window, no ledger."

> [on B] "a beautiful *rule editor* wearing an evidence costume. If a bad rule
> was learned last Tuesday and hasn't fired today, B gives me no surface to
> even discover it exists."

> [on C] "the toast means nothing durable is ever learned silently — my hard
> line"; the recipe strip is "quietly the most important row on the screen …
> the closest any option comes to per-site capture legibility."

> Graft: embed A's evidence block (labelled rows + fallback preview) in the
> ledger's row editor and the first-fire toast's expansion.

---

## 4. Synthesis — winner and grafts

**Winner: Option A, the Evidence Card**, as the chassis. Highest total (153),
first or second for every persona, never last, and it is the only option that
puts see-why (R1), un-learn (R2) and re-grain (R3) in the same place at the
moment of annoyance — which Doug correctly identifies as the only moment of
attention the feature will ever get.

Every persona's graft request points the same way, so the final design is A
with three transplants:

1. **From B — one grammar, not two** (Martin's veto). The card's grain chooser
   is NOT a radio group; it is the broad→narrow identity chain rendered as
   labelled ROWS — B's model in A's clothing. Each row is a full-width click
   target (Doug and Priya get readable buttons), and the keyboard is the pin
   editor's: ↑/↓ move the grain, ↵ remembers, ⇧↵ pins, esc = once. One
   `ContextIdentity` type feeds this card, the pin editor's Components strip,
   and recipe fields — B's unification survives underneath the friendlier
   skin.
2. **From C — the first-learn / first-fire toast** (requested independently by
   Martin, Doug and Priya). A durable rule's creation, and its first silent
   reallocation of time, each produce one transient actionable notice that
   opens straight into the Evidence Card. Nothing durable is ever learned
   silently (Sam's hard line) — this retires today's silent `learnEmailRule`
   side effect.
3. **From C — the Rules Ledger** as the audit surface (the reason Sam and
   Priya put C first). A plain list window of every learned + pinned rule;
   clicking a row opens the same Evidence Card as its editor (Priya's and
   Sam's graft). The ledger is polish, not the fix path — the card at the
   point of pain is the fix path.

Also adopted verbatim from the group: recipe setup must be "click the bit of
the page that says the client name", never "paste a DOM selector" (Doug);
toasts suppress automatically while screen-sharing (Priya).

---

## 5. Final design — Context Rules (complete, implementable)

### 5.1 Data model (andeyeTTCore)

**`ContextIdentity`** (new) — one broad→narrow segment chain for any surface,
unifying `PinScope.identity(of:)`, `EmailContext` and (later) recipe fields:

```swift
public struct ContextIdentity: Sendable, Equatable {
    public enum SegmentKind: Sendable, Equatable {
        case app, urlHost, urlPath          // today's PinScope segments
        case emailSystem                    // "Gmail"
        case correspondentDomain            // "harborlane.example"
        case correspondent                  // "r.naismith@harborlane.example"
        case subject                        // normalised subject
        case recipeField(String)            // ◆ extracted; assoc = field name ("client")
    }
    public struct Segment: Sendable, Equatable {
        public var kind: SegmentKind
        public var value: String            // the matchable value
        public var display: String          // pretty/truncated form for UI
        public var shared: Bool             // gmail.com et al. — caution tint
        public var available: Bool          // false = "not captured" ghost row
    }
    public var segments: [Segment]          // general → specific
}
```

Built by one `ContextIdentity.from(signal:order:recipes:)`. For email surfaces
the email segments are ordered per the user's `emailMatchOrder` ladder
(Settings), so reordering the ladder reorders every card and strip app-wide.
For non-email surfaces the chain is the PinScope identity; recipe fields
splice in after the host segment.

**`EmailRule`** gains provenance metadata (additive, codable with defaults so
`emailrules.json` migrates in place):

```swift
public var createdAt: Date       // default .distantPast on migration
public var origin: Origin        // .correction, .card, .ledger, .migrated
public var fireCount: Int        // bumped by Attributor on a winning match
public var lastFired: Date?
```

Longer term `EmailRule` generalises to `ContextRule` by adding a
`recipeField(site:field:)` level to the `EmailMatchLevel` successor, so
"client = Acme Ltd on crm.foocorp.com → task" is the same struct resolved by
the same most-specific-wins ladder. Out of MVP scope (§6).

**`Attributor` un-learn API** — one entry point that removes exactly what an
explanation says fired:

```swift
public enum Unlearn: Equatable {
    case emailRule(EmailRule)
    case primedSurface(Surface)
    case sessionSticky(SessionSticky.Key)
    case rankedAssociation(Target)
}
/// What [✕ forget] would remove for this signal, or nil. Pin / OP-URL
/// sources are not "learned": pins are lifted via the pin editor as today.
public func forgettable(for signal: ActivitySignal, now: Date) -> Unlearn?
/// Remove it. rankedAssociation counter-teaches (learning weight -2 on the
/// signal's features against that target) — weights can't be deleted, only
/// suppressed, and the UI says "suppress" there, honestly.
public func forget(_ u: Unlearn, signal: ActivitySignal)
/// Preview without mutating: explain() as if `u` were removed. Drives the
/// live "would then fall back to …" line.
public func explainWithout(_ u: Unlearn, _ signal: ActivitySignal,
                           tasks: [WorkTask], now: Date) -> AttributionExplanation
```

`explain()` is extended to carry the matched `EmailRule` (with metadata) and
matched `Pin`, so the card never re-derives them and can never disagree with
the decision (the existing invariant, kept).

**`SiteRecipe`** (later phase) — `EmailSystem`'s selectors generalised to
data: `{ hostSuffix, fields: [(name, selector)], enabled: Bool }`, shipped as
a bundled pack plus user-taught entries. Teaching is point-and-teach: from the
card's ghost row `[capture from this page…]`, the app injects a picker overlay
via the existing browser JS channel; the user clicks the on-page element that
shows the client/project name; the app derives a robust selector, echoes the
extracted value back for confirmation, and stores the recipe. AI-assist
fallback reuses the `AIAssist` clipboard pattern with a DOM snippet. Per-site
`enabled` is the privacy opt-in surface; Gmail ships enabled (existing
behaviour) but visibly listed.

### 5.2 The Evidence Card (andeyeTTUI — one view, three hosts)

`EvidenceCardView(controller:, signal:, host: .timeline | .popover | .ledger)`.

Full (timeline / ledger) layout:

```
┌──────────────────────────────────────────────────────────────────┐
│ Chrome – Re: Insurance Renewals 2026        14:02–14:09 · 7m     │
│ tracked as  Insurance Renewals  ·  95%                           │
│                                                                  │
│ BECAUSE  ✉ learned rule: harborlane.example → Insurance Renewals │
│          learned 12 Jun from your correction · fired 8×          │
│          [✕ forget]  → would then fall back to: andeye · 62%     │
│                                                                  │
│ WRONG?  file as [filter tasks…        ]  then remember for       │
│   ○ once        just today, this thread                          │
│   ○ Gmail       everything in Gmail                              │
│   ● domain      harborlane.example                    ← default  │
│   ○ address     r.naismith@harborlane.example                   │
│   ○ subject     "Insurance Renewals 2026"                        │
│                                                                  │
│   sees: app Chrome · site mail.google.com (Gmail) ·              │
│         from r.naismith@harborlane.example · subj "Re: Insu…"   │
│   candidates: andeye 62% · Northgate Insurance 31% · … ▾            │
│                              [Remember ↵]  [Always 📌 ⇧↵]        │
└──────────────────────────────────────────────────────────────────┘
```

Anatomy, top to bottom:

- **Header** — surface, slot, attribution, certainty (all already available).
- **BECAUSE** — the winning source in words (reuses `whyLabel`), plus, when a
  deterministic rule fired, the rule itself with provenance (created, origin,
  fireCount). `[✕ forget]` renders iff `forgettable()` ≠ nil; the fallback
  line renders `explainWithout()` live, BEFORE the click, so forgetting is
  never a leap of faith. Forget is one click, undoable (`UndoStack`), and
  re-renders the card against the new state. For a `rankedAssociation` source
  the button reads `[✕ suppress]` (honest: counter-taught, not deleted). For
  a pin source the line shows the pin badge and `[adjust pin…]` routes to the
  existing pin editor — pins keep their lifecycle.
- **WRONG?** — task filter (same fuzzy search as everywhere; ↵ picks top) +
  the **grain ladder**: the `ContextIdentity` segments as labelled rows,
  general → specific, ordered per the Settings ladder, radio-look but each
  row a full-width button. ↑/↓ move the grain selection, ↵ = Remember
  (learned rule, 0.95), ⇧↵ = Always (pinned, 1.0), esc = once (today's sticky
  + soft-prime path — `confirm`/`assign` unchanged). Default selection
  mirrors `learnEmailRule`'s conservatism: domain for an org domain, address
  for shared webmail, once when no email context. The `[Remember]`
  `[Always 📌]` buttons duplicate ↵/⇧↵ for mouse users (Doug: "I read the
  button I'm about to press").
- **sees:** — the flat labelled evidence line (never hover-only — Martin's
  and Sam's shared demand). Uncaptured fields render as ghosts:
  `from — not captured on this site  [capture from this page…]`.
- **candidates:** — the ranked list with learned/prior split, folded to one
  line, `▾` expands to today's full breakdown.

Compact popover variant: same sections at 276 pt, candidates collapsed,
evidence middle-ellipsised, identical keyboard.

### 5.3 Entry points and flows

**Timeline** (the primary "why" moment — shape unchanged): click slice →
click window chip → Evidence Card replaces the monospaced pane (`detailText`
retired). Multi-window selection shows one card per window, as the panes do
today. The move-windows strip stays for bulk re-slicing; committing a move
now shows the grain ladder inline beneath the strip ("remember for: ● domain
… ↵ / esc") instead of calling `learnEmailRule` silently.

**Popover**: the certainty caption gains a why suffix —
`7m · 95% · ✉ harborlane.example ▾` — click (or ⌘E) expands the compact card
inline under the header (popover grows; no new window, no modal). Fixing here
relabels the running session (Change-to semantics) then applies the chosen
grain. Separately, picking a task from the Switch/Change list while an
email/recipe surface is focused appends the one-line grain footer under the
list ("remember for  ● domain harborlane.example  ↵ / esc") — ignoring it or
esc = once, so the express path stays two clicks and never blocks.

**Review queue**: when every selected segment shares one email context, the
assign bar gains the same one-line grain footer after assignment.

**Toasts** (first-learn + first-fire): popover-anchored banner; mirrored to a
system notification only when `systemNotifications` is on.

```
┌────────────────────────────────────┐
│ ✉ Learned: harborlane.example      │
│   → Northgate Insurance               │
│   [why / change…]  [undo]          │
└────────────────────────────────────┘
```

Fires on (a) rule creation and (b) a rule's first match that moved time —
never per-match. `[why / change…]` opens the Evidence Card on that signal;
`[undo]` deletes the rule. Suppressed automatically while the Mac is
screen-sharing or presenting (ScreenCaptureKit shareable-content check);
suppressed toasts queue behind the popover's why-caption badge dot. Settings
toggle "Announce newly learned rules" (default on); off keeps the badge dot,
so learning still leaves a visible trace — silence never becomes silent
learning again.

**Rules Ledger** (audit surface, later phase): window reachable from Settings
(a "Context rules…" button in the Email → task matching section) and the
popover gear context-menu.

```
┌───────────────────────────────────────────────────────────────────┐
│ Context rules                    [search rules…      ]  [+ rule]  │
│ ▾ Northgate Insurance (3)                                            │
│    ✉ domain    harborlane.example     learned · 8× · 12 Jun    ✕ │
│    ✉ address   b.smith@gmail.com      learned · 2× · 28 Jun    ✕ │
│    📌 url      op.example.com/insur…   pinned  · —              ✕ │
│ ▸ andeye (2) · ▸ Do not track (4)                                 │
│ Capture recipes:  Gmail ✓ · Outlook — · crm.foocorp.com ✓        │
│                   per-site toggles                  [manage…]     │
└───────────────────────────────────────────────────────────────────┘
```

Row click opens the Evidence Card in ledger host mode — same view, but the
evidence section shows the rule's last 5 matches instead of one live signal.
Bulk actions: forget all learned rules for a task; export rules (JSON). The
capture-recipes strip with per-site enable toggles is the privacy opt-in
surface (Sam's "most important row on the screen").

### 5.4 What happens to existing controls

- **Pin editor / pin badge**: unchanged; still the home of URL/app prefix
  pins, Expression and AI modes. "Always 📌" from the card writes a PINNED
  `EmailRule` for email grains, or a `Pin` for the site-section grain on a
  non-email surface (the card's most-specific non-email row maps to a
  PinScope prefix). The pin badge's shortLabel gains a ✉ glyph for pinned
  email rules.
- **Boost / heavier-teach**: retired as a separate concept. "Once" = the
  weight-2 soft teach (today's `confirm`); a grain commit writes a
  deterministic rule, which is strictly stronger than any weight boost.
  `learnSurface(weight:)` stays as internal machinery.
- **Silent `learnEmailRule` on every correction**: retired. Corrections
  PROPOSE (grain footer / toast + undo) rather than silently write.
  `assign()`/`confirm()` keep sticky + soft-prime behaviour unconditionally,
  so declining a grain never loses today's fix.
- **Email ladder in Settings**: unchanged, and now also orders the card's
  grain rows; the section gains the "Context rules…" ledger button.
- **`emailrules.json`**: schema-migrated in place (metadata defaults,
  `origin: .migrated`).

### 5.5 Edge cases (normative)

- **No correspondent captured**: address/domain rows render as unavailable
  ghosts with `[capture from this page…]`; the default grain falls to the
  most specific AVAILABLE row (subject if present, else site-section). Rows
  are never hidden — their absence IS the coverage/privacy signal.
- **Shared webmail domain** (`Attributor.sharedWebmailDomains`): domain row
  gets a caution tint + "shared — matches everyone's gmail.com"; default
  selection skips to address; choosing it anyway requires a second ↵ on an
  inline "really match ALL gmail.com mail?" confirm.
- **Multiple correspondents**: the address row shows the primary + `+2 ▾`;
  expanding lists all counterparties with checkboxes; Remember writes one
  rule per checked address. The domain row de-duplicates domains the same
  way.
- **Conflicting rule exists** (same level+value → different task): the card
  shows "replaces: harborlane.example → OldTask" before commit; commit
  replaces, matching `learnEmailRule`'s same-level replacement semantics
  (a pinned rule is never silently replaced by a learned one).
- **Re-grain to a LESS specific level than an existing rule**: ladder
  semantics unchanged (most specific wins); the card warns which rule keeps
  winning ("your address rule for b.smith@ still outranks this").
- **Draft emails / mutating titles**: identity keys on the normalised subject
  (existing `normalisedSubject`), so the card stays stable while typing.
- **No email context at all** (plain page, no recipe): the grain ladder IS
  the PinScope chain (host ▸ path …) — the card degrades into a friendlier
  prime/pin editor: Remember = soft prime + learned association (today's
  behaviour), Always = Pin. One card everywhere.

### 5.6 Implementation surface (by file)

- `andeyeTTCore/ContextIdentity.swift` — new.
- `andeyeTTCore/EmailMatch.swift` — EmailRule metadata + decode migration.
- `andeyeTTCore/Attributor.swift` — `forgettable`/`forget`/`explainWithout`;
  fireCount bump in `emailRuleMatch`; silent `learnEmailRule` call sites
  removed from `confirm`/`assign` (function kept; the card/footer call it
  with an explicit level).
- `andeyeTTUI/EvidenceCardView.swift` — new (three hosts).
- `andeyeTTUI/TimelineView.swift` — `detailText`/`selectedSpanPanes` → card;
  move-strip grain footer.
- `andeyeTTUI/PopoverView.swift` — why-caption + ⌘E inline card; post-pick
  grain footer; toast host.
- `andeyeTTUI/ReviewView.swift` — assign-bar grain footer (later phase).
- `andeyeTTUI/RulesLedgerView.swift` — new window; scene in
  `RootScenes.swift` (later phase).
- `andeyeTTUI/SettingsView.swift` — ledger button; "Announce newly learned
  rules" toggle; capture-recipe list (later phase).
- `andeyeTTMac/AppController.swift` — rules exposed as published lists,
  forget plumbing + undo, persistence bump, screen-share detection for toast
  suppression (later phase).
- `MANUAL.md` — a "Context rules" section replacing the "Why was this tracked
  as X?" prose; keyboard tables gain ⌘E and the card's ↑ ↓ ↵ ⇧↵ esc.

---

## 6. MVP cut vs later polish

### MVP (closes R1, R2, R3 for email)

1. `ContextIdentity` (email + PinScope segments; no recipe fields).
2. `EmailRule` metadata + `emailrules.json` migration.
3. `Attributor.forgettable` / `forget` / `explainWithout` + tests (forget
   each source kind; explainWithout never mutates; ladder semantics
   unchanged).
4. Evidence Card, timeline host — replaces the monospaced why-pane: BECAUSE
   + [✕ forget] + live fallback preview, sees-line, grain ladder,
   Remember/Always, full keyboard (↑ ↓ ↵ ⇧↵ esc).
5. Evidence Card, popover host — why-caption + ⌘E expansion; post-pick grain
   footer (this is what replaces silent `learnEmailRule`).
6. First-LEARN notice, popover-anchored only (one line + [undo]; no system
   notification, no screen-share detection yet).
7. Edge cases in-scope: shared-domain skip + confirm; ghost rows for missing
   correspondent (without the capture affordance); replace-warning.
8. MANUAL.md update.

### Later polish

- Rules Ledger window (inventory, search, last-5-matches, bulk forget,
  export, + rule) + Settings entry point.
- First-FIRE toast; system-notification mirror; screen-share suppression.
- Site recipes beyond Gmail: bundled selector pack (Outlook/Proton/Yahoo/
  Fastmail), per-site enable toggles (the privacy opt-in surface), the
  point-and-teach element picker, AI-assisted recipe derivation, ◆ recipe
  segments in the card, `ContextRule` generalisation of `EmailMatchLevel`.
- Review-queue grain footer; multi-correspondent checkbox expansion.
- Candidates `▾` expansion inside the card (per-line learned/prior split).
- "Suppress" polish for ranked-source forgets + per-task learning reset in
  the ledger.
