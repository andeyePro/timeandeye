# Site recipes – pluggable page understanding beyond Gmail

Status: DESIGN (no code in this commit). Spec date 2026-07-09. Closes NAIL
item (e) – "generalise the mechanism beyond Gmail: pluggable page recipes
for web apps where app/URL/title are insufficient" – and implements the
host-as-signal half of the ambiguous-web-page policy note (6907245).

Trigger (Martin, verbatim, from the 2026-07-03 context-rules requirements):
"…ideally one that will work beyond Gmail and into other web pages where
the app, URL and title aren't enough to give you what you need for accurate
task allocation." Plus the 2026-07-01 policy note: "Treat the URL HOST as a
first-class domain signal, the web sibling of the email correspondent-domain
ladder: one correction generalises the whole host (github.com → task). …
Fold 'web host' in as another ladder level later." This spec is that later.

## 0. Open questions for Martin (answer before /vs build starts)

1. **Which recipes ship in v1?** All three candidates (§4) are URL/title
   recipes – no DOM probe, no new permissions, cheap to add once the model
   exists. (a) GitHub + Google Docs/Drive only, Xero when the Xero backend
   lands; (b) all three now, with Xero's extractors verified live before the
   suite claims them; (c) a different set – name it. Recommend **b** – the
   marginal recipe is a data table plus fixtures, and Xero is where the
   accounts entities live.
2. **Host-level rules on EVERY site, or only recipe'd sites?** The `site`
   grain (§5) is derivable from any URL – it needs no recipe. Offering it
   everywhere implements the policy note's "one correction generalises the
   whole host" one-tap on every web page; restricting it to recipe'd hosts
   keeps the card unchanged elsewhere. (a) every site; (b) recipe'd sites
   only. Recommend **a** – it is the policy note's core ask, and the grain
   row costs nothing on pages that never get corrected.
3. **Recipe fields as learned features too?** Deterministic SiteRules are
   the headline, but the naive-Bayes learner could also key on extracted
   fields (`github.repo=example-repo`), exactly as correspondents were added in
   2026-07-03. (a) yes, features from day one; (b) rules only, features
   later. Recommend **a** – the correspondent precedent showed the ranked
   fallback stays junk-driven without the strong field.
4. **Per-recipe capture toggles default ON?** URL/title recipes read only
   what the sensors already capture (no new data classes – §9), so "off"
   protects nothing extra. (a) on; (b) off until enabled in the ledger's
   recipe strip. Recommend **a**, matching Gmail's ships-enabled precedent –
   the toggle still exists for legibility.
5. **User-defined recipes in v1?** (a) built-ins only, point-and-teach and
   a JSON pack later; (b) a hand-editable siterecipes.json now. Recommend
   **a** – Doug's focus-group verdict stands ("if it's 'paste a DOM
   selector' I'm out"), and a JSON file nobody edits is dead weight; §8
   keeps the model data-shaped so the pack costs nothing later.

## 1. What the code says today (investigation)

- **The Gmail recipe is already half the model.** `EmailSystem`
  (Sources/andeyeTTCore/EmailSystem.swift) is host detection (anchored
  suffix match – the C20 fastmail lesson), DOM selectors as data
  (`senderSelector`/`recipientSelector`, its own doc comment: "data, not
  code, so it can later ship in an updatable pack"), and a per-system view
  gate (`isMessageView`, 2026-07-09) that refuses capture on list/label/
  search surfaces because Gmail keeps the LAST-open conversation's DOM
  cached – the selectors would report stale parties and the list title
  makes a junk subject ("Inbox (1)"). Any generalisation must carry that
  staleness lesson, not just the selectors.
- **The capture pipeline is two-tier already, implicitly.** The subject is
  a cheap synchronous read of the window title
  (`EmailSignal.subject(fromTitle:)` in Sensors.swift's
  `captureEmailIfEligible`); only correspondents need the async osascript
  JS probe (`EmailCaptureEngine`: subprocess, 2 s deadline, one in flight,
  Chromium-only, result applied retroactively via `.focusEnrichment` with
  SessionTracker's same-`Surface` guard). URL and title are free and never
  stale – they ARE the current signal; the DOM is expensive and CAN be
  stale. §3 names these Tier 0 and Tier 1 and ships v1 entirely in Tier 0.
- **The rails the fields land on all exist.** `ContextIdentity`
  (Sources/andeyeTTCore/ContextIdentity.swift) already declares
  `SegmentKind.recipeField(String)` ("◆ extracted; assoc = field name") and
  `from(signal:order:recipeFields:)` takes a `recipeFields` parameter today
  – "the extension point for site recipes (spec: spliced in after the root
  segment, marked ◆); recipes themselves come later". The Evidence Card,
  the popover's post-pick grain footer, the review queue's post-assign
  footer and the pin editor all render from ContextIdentity, so recipe
  grains appear in every teach surface the moment the chain carries them.
  One wrinkle: the current implementation SPLICES recipe segments into the
  PinScope chain at index 1, which for URL-derived fields would duplicate
  the raw path segments they were parsed from (`github.com ▸ ◆Aqueum ▸
  ◆a private notes repo ▸ Aqueum ▸ a private notes repo ▸ issues`) – §6 replaces the chain instead.
- **The rule shape is proven twice.** `EmailRule` (level ladder, pinned
  flag, provenance metadata, most-specific-wins `EmailMatcher`) and its
  younger sibling `CalendarRule` (2026-07-09 calendar spec §4, which chose
  a parallel type over premature abstraction: "a shared protocol is a nice
  later refactor once there's a third rule domain to justify it"). Site
  rules are that third domain – §5 still recommends a parallel type
  (email levels are a fixed enum; site levels are per-recipe field names,
  so the shapes genuinely differ), with the refactor noted, not forced.
- **`BackendPageRecognizer` is a different animal and must stay one.**
  `OPPageRecognizer` (Sources/andeyeTTCore/OPBackend.swift) maps a backend
  task page to a TASK ID deterministically – `/work_packages/<id>` URL,
  `#<id>` in a PWA title – and flags project pages so the ranker trusts
  its priors scoped to that project (`projectHint`). It sits ABOVE email
  rules in `Attributor.attribute()`'s ladder and involves no learning. A
  recipe never re-derives a task id; a recognizer never extracts evidence
  fields. §7 draws the line precisely so nobody ever writes an "OP recipe".
- **The learner's compliance invariant constrains the extension
  mechanism.** `LearningStore`'s header (Xero T&Cs, Dec 2025): "features
  derive EXCLUSIVELY from sensor-observed `ActivitySignal` fields (what is
  on the user's own screen) – backend-sourced text … must NEVER be added
  as a feature", frozen by a check. Recipe fields are parsed from the URL
  and window title the sensors already captured – sensor-observed by
  construction – so they are compliant, including on go.xero.com pages.
  What the invariant forbids is any future recipe mechanism that decorates
  pages with API-fetched strings (task subjects, contact names from the
  Xero API); §8 states this as a hard rule for recipe authorship.
- **Learned generalisation is too coarse for exactly the sites Martin
  lives in.** `LearningStore.features` emits `urlHost` and `urlPath`
  (host + FIRST path component only) – on GitHub that is the owner, never
  the repo; on Google Docs it is `/document`, never the document. PinScope
  prefix pins can reach `github.com/example-org/example-repo`, but nothing LEARNED
  can, and a Google Doc's identity (the opaque `d/<id>` path segment)
  renders as an unreadable pin. Recipes give these grains names and make
  them learnable.
- **Review-queue evidence rides free.** `ReviewSegment` stores
  `app`/`windowTitle`/`tabURL` per segment (and, since 2026-07-09,
  correspondents/subject). Tier 0 recipe fields are a pure function of
  URL + title, so the review footer can DERIVE them at render time from
  what is already persisted – no schema change, and old queue rows gain
  recipe grains retroactively.
- **The ambiguous-page policy note (6907245)** asks for three things: host
  as a ladder level (this spec, §5's `site` grain), a one-tap "this site →
  task" that learns the host (§6 – the grain footer's host row), and
  sticky-plus-red-certainty behaviour when NOTHING matches. The third is
  attribution policy, not recipe machinery – it stays an open TODO item
  awaiting Martin's sticky-vs-review steer, unblocked but untouched here.

## 2. Principles

- **URL and title first, DOM last.** Tier 0 extraction is free, synchronous,
  and cannot be stale; the DOM probe is a deadline-bounded subprocess with
  a documented staleness failure mode. A recipe only earns Tier 1 when the
  page genuinely hides the signal from URL and title – Gmail's
  correspondents are the only known case today.
- **Recipes structure what is already seen; they never see more.** v1
  captures no new data classes: every field is parsed from the app/title/
  URL triple the sensors have always emitted. The privacy story is
  legibility (named fields, per-recipe toggles), not new collection.
- **One vocabulary, third verse.** Ladder of grains, most-specific-wins,
  pinned beats learned at a level, provenance metadata, first-fire notice,
  ledger audit – the shape email proved and calendar copied. No new
  interaction grammar; the Evidence Card and grain footers just get more
  rows.
- **Deterministic rules outrank soft learning, and both stay below
  explicit signals.** A SiteRule caps at the 0.95 inferred ceiling on the
  same rung as an email rule – under pins, stickies and backend task URLs,
  above primes and the ranker. The existing ladder order is untouched.
- **Backend identity is the recognizer's job; ambient evidence is the
  recipe's.** The two never overlap on a page: if a URL names a task, the
  recognizer already won before rules are consulted.

## 3. The recipe model

New type in `andeyeTTCore` (Sources/andeyeTTCore/SiteRecipe.swift) – a
value, not a protocol, so a bundled pack can later ship as JSON without a
redesign:

```swift
public struct SiteRecipe: Codable, Equatable, Sendable {
    public let id: String                    // "github" – stable, keys rules & toggles
    public let label: String                 // "GitHub" – Evidence Card / ledger display
    /// Anchored host match: equal, or suffix at a dot boundary
    /// (the C20 lesson – "github.com" must not match "notgithub.com").
    public let hosts: [String]
    /// Tier 0 = URL/title only (v1). Tier 1 = adds DOM extractors via the
    /// browser JS channel (later; Gmail is the only Tier 1 today).
    public let tier: Int
    /// When extraction may run at all – the generalised `isMessageView`.
    /// Tier 0: a page-kind classifier (is the interesting entity open?).
    /// Tier 1: ALSO the staleness gate (cached-DOM guard).
    public let viewGate: URLShape
    public let fields: [Field]               // general → specific, the grain ladder

    public struct Field: Codable, Equatable, Sendable {
        public let name: String              // "repo" – SegmentKind.recipeField assoc
        public let label: String             // "Repository"
        public let source: Source            // where the value comes from
        /// true = subject-like content matched by case-insensitive
        /// CONTAINS (rule values are substrings); false = identity matched
        /// by equality (lowercased).
        public let isContent: Bool
        /// Multi-value fields (email correspondents) commit one rule per
        /// chosen value – reuses the multi-correspondent checkbox flow.
        public let multi: Bool
    }

    public enum Source: Codable, Equatable, Sendable {
        case pathComponent(Int)              // URL path segment by index
        case pathAfter(String)               // segment following a marker ("d" → doc id)
        case fragmentLastComponent           // Gmail's thread id position
        case titleStripSuffix([String])      // title minus trailing " - Google Docs" etc.
        case titleLeadingSegment(separator: String)   // "Issue title · Issue #42 · o/r"
        case domSelector(String, attribute: String?)  // Tier 1 only
    }
}
```

`URLShape` is a small declarative predicate (all-of): host in `hosts`,
minimum path depth, an optional regex on a named URL part (path, fragment
tail), an optional first-segment denylist (GitHub's reserved
`/settings`, `/notifications`, …). Declarative rather than a closure so a
recipe stays serialisable and a future pack can ship new gates without
code.

Extraction is one pure function, `SiteRecipes.extract(_ signal:) ->
SiteContext?` – nil when no recipe's hosts match, when the host is a known
mail system (`EmailSystem.detect != .unknown`; email keeps its own richer
pipeline, §6), or when the `viewGate` fails. `SiteContext` carries the
recipe id, the host, and `[(field, value)]` for every field whose source
yielded a non-empty value; missing fields are simply absent (they render
as ghost rows, per the existing §5.5 convention). Pure and synchronous, so
attribution, identity chains, learned features and the review footer all
derive it on demand from any signal – nothing new is stored anywhere.

**Gmail, re-expressed in the model** (proof of generality – NOT migrated
in v1, §11):

```
id: gmail            hosts: [mail.google.com]         tier: 1
viewGate: fragment's last path component matches ^[A-Za-z0-9_-]{16,}$
          (verbatim isMessageView – the cached-DOM staleness gate)
fields:
  system         source: constant("Gmail")                       identity
  correspondent  source: domSelector(".gD"/".g2", attribute:     identity,
                 email ?? data-hovercard-id), multi: true,       multi
                 post-filter: own-address/domain removal
  domain         DERIVED: domain-of(correspondent)               identity
  subject        source: titleLeadingSegment(" - ")              content
```

Everything the live pipeline does fits: the view gate is `isMessageView`,
the selectors are the `Field.source`, the subject's title read is a
`titleLeadingSegment`, and the one thing the model adds a named concept
for – a DERIVED field (domain-of) – is a transform the email ladder
already performs implicitly. The own-address post-filter stays a
field-role behaviour (counterparty fields get it), not per-recipe code.

## 4. The v1 recipes – chosen for Martin's real usage

OpenProject is deliberately absent: its task and project pages are the
recognizer's territory (§7), and its remaining pages carry no field the
`projectHint` prior doesn't already exploit. The three below are where
Martin's browser time actually goes and where URL + title are
insufficient TODAY (the policy note's github.com example verbatim).

### 4.1 GitHub (`github`, tier 0)

| grain (general → specific) | source | example |
|---|---|---|
| site | host | github.com |
| owner | path[0] (denylist: settings, notifications, orgs, marketplace, pulls, issues, search, …) | Aqueum |
| repo | path[1] | a private notes repo |
| section | path[2] when in {issues, pulls, actions, wiki, discussions, projects} | issues |
| item title (content) | titleLeadingSegment(" · ") when path names an issue/PR number | "Pin editor loses focus" |

viewGate: path depth ≥ 1, first segment not in denylist. The money grain
is **repo** – "example repo → task X" in one correction, which neither `urlPath`
learning (owner only) nor anything short of a hand-built pin reaches
today. The content grain mirrors the email subject: substring match, for
"anything mentioning 'invoice' in this repo's issues" style rules later.

### 4.2 Google Docs / Drive (`gdocs`, tier 0)

| grain | source | example |
|---|---|---|
| site | host | docs.google.com / drive.google.com |
| doc type | path[0] in {document, spreadsheets, presentation, forms}; drive: "drive" | spreadsheets |
| document | pathAfter("d") – the opaque doc id; DISPLAY is the title-derived name | "andeye accounts FY26" (id d1AbC…) |
| doc title (content) | titleStripSuffix([" - Google Docs", " - Google Sheets", " - Google Slides", " - Google Drive"]) | "andeye accounts FY26" |

viewGate: a `d/<id>` (or Drive folder id) present. The **document** grain
keys the RULE on the stable opaque id but DISPLAYS the human name – the
segment's existing value/display split does this for free, and the rule
survives the document being renamed. Title extraction is gated on the
suffix actually matching; otherwise the field ghosts (title lag on SPA
navigation must not mint a junk value – the "Inbox (1)" lesson applied to
Tier 0's one stale-ish input, the window title).

### 4.3 Xero (`xero`, tier 0) – extractors to be verified live

| grain | source | example |
|---|---|---|
| site | host | go.xero.com |
| organisation | the `!shortcode` path segment; display from the title's org suffix when present | !x7Kp2 ("andeye Ltd") |
| section | first path segment after the shortcode (app area: invoicing, bank, contacts, projects, reports) | invoicing |
| page title (content) | titleStripSuffix([" | Xero"]) | "Amounts owed to you" |

The organisation grain maps Xero orgs to their entity tasks (andeye Ltd,
Aqueum, …) in one correction each – the accounts-period use case. Xero's
URL and title shapes are asserted from memory, not from a live session:
the build must verify them against real pages before the recipe's checks
claim them (the diagnostics probe pattern – `EmailCaptureEngine.captureNow`
behind a button – generalises to a "show me what recipes see here" row in
Settings diagnostics, worth shipping in the same session). Everything on
these pages is screen-observed; nothing here touches the Xero API, so the
LearningStore invariant is untouched (§9).

## 5. Site rules – the ladder, third verse

New parallel types in `andeyeTTCore` (Sources/andeyeTTCore/SiteMatch.swift),
mirroring `EmailRule`/`CalendarRule` deliberately (the calendar spec's
"parallel type over premature abstraction" call, reaffirmed – email levels
are a closed enum, site levels are open per-recipe field names, so a shared
generic would have to erase exactly the part that differs):

```swift
public struct SiteRule: Equatable, Codable, Sendable {
    /// nil = the recipe-less host-level rule (the policy note's
    /// "one correction generalises the whole host").
    public let recipeID: String?
    /// "site" (reserved, host value) or a recipe field name ("repo").
    public let field: String
    public let value: String                 // lowercased; content fields: substring
    public let target: TaskRef
    public let pinned: Bool
    public var createdAt: Date               // provenance block, verbatim EmailRule
    public var origin: EmailRule.Origin      // reuse: .correction/.card/.ledger/.migrated
    public var fireCount: Int
    public var lastFired: Date?
}

public enum SiteMatcher {
    /// Ladder order = ["site"] + the matched recipe's declared field order
    /// (general → specific; content field last). Most specific level with
    /// any match wins; pinned beats learned at a level; newest unpinned
    /// wins ties – EmailMatcher.match()'s semantics verbatim.
    public static func match(_ context: SiteContext, rules: [SiteRule]) -> SiteRule?
}
```

- **Attributor rung**: `siteRuleMatch(_:)` joins `emailRuleMatch(_:)` on
  the SAME rung – after pin, sticky and the backend recognizer; before
  primes and the ranker; certainty `inferredCeiling` (0.95). Email is
  consulted first purely for determinism; the two are host-disjoint by the
  §3 mail-host exclusion, so no page can ever match both. `recordFire`,
  `onFirstFire` (the first-fire toast), `forgettable`/`forget`/
  `explainWithout` and `AttributionExplanation.matchedEmailRule` all gain
  site-rule twins – the un-learn card path works day one because it is the
  same code shape the email rung already exercises.
- **The `site` level needs no recipe** (§0 Q2): on any URL page,
  `SiteContext` degrades to host-only, so "this site → task" is learnable
  everywhere. This is the policy note's host ladder level. It is
  deliberately a LEARNED, forgettable rule at 0.95 – distinct from a
  PinScope host pin (1.0, standing law), which remains the "Always" form.
- **Learning stays proposal-based**: no silent rule writes (the §5.4
  retirement holds). Rules are born only from the Evidence Card, the
  popover's post-pick grain footer, the review footer, or the ledger.
- **LearningStore** (§0 Q3): `Feature.Kind` gains `.recipeField`, value
  encoded `"<recipeID>.<field>=<value>"`, emitted from
  `SiteRecipes.extract` inside `features(from:)` – additive, decodes old
  learning.json unchanged, inert until recipes match, exactly the
  correspondent playbook. Content fields are NOT emitted as features
  (title tokens already cover them; a whole issue title as one feature
  would never repeat and only bloat counts).
- **Persistence**: `siterules.json` beside emailrules.json; no migration
  (new file); AppController publishes the list like the other rule stores.

## 6. Landing in the existing rails – no new UI concepts

- **ContextIdentity**: `from(signal:…)` gains the recipe branch. For a
  recipe-matched page the chain is host root + one `◆ recipeField` segment
  per declared field (ghosts for missing values) + the content field last
  – REPLACING the raw path segments, not splicing alongside them (the
  fields ARE the path, structured; the current insert-at-1 behaviour would
  render `github.com ▸ ◆Aqueum ▸ ◆a private notes repo ▸ Aqueum ▸ a private notes repo`). Host-only
  pages keep today's PinScope chain untouched. Email chains are untouched.
- **Evidence Card / grain footers / review footer**: nothing structural –
  they render whatever chain ContextIdentity hands them. `SegmentKind
  .recipeField` gains a `siteRuleCommit` twin of `emailMatchLevel`:
  Remember writes a learned SiteRule at the row's grain, Always writes a
  PINNED SiteRule (mirroring the card's pinned-EmailRule convention); the
  host row's Remember writes the `site`-level SiteRule (Q2), its Always
  stays the existing PinScope root pin. Default grain selection mirrors
  email's conservatism per recipe: the second-from-root identity grain
  (owner→repo's REPO, gdocs' DOCUMENT, xero's ORGANISATION – each recipe
  declares its default), never the content field.
- **Review queue**: the footer derives `SiteContext` from the stored
  `tabURL`/`windowTitle` at render time – old rows gain recipe grains with
  no schema change. A batch whose derived contexts disagree degrades to
  the shared `site` grain, the same rule email's footer already applies.
- **Rules Ledger**: a third segment ("Sites") beside Email – grouping,
  provenance line, fire stats, forget-with-undo, bulk forget, "Copy rules"
  export, all duplicated in the small-function style the calendar spec
  chose. With three domains now real, the shared-protocol refactor is
  legitimately justified – noted for a dedicated cleanup pass, NOT bundled
  into this feature (two behaviour-preserving refactors mid-feature is how
  suites go red). The ledger's recipe strip (per-recipe enable toggles,
  the context-rules spec's "capture recipes" row) ships here as the
  privacy-legibility surface.
- **First-learn notice / first-fire toast**: identical hooks, site rules
  included – nothing durable is ever learned silently (Sam's hard line,
  still standing).

## 7. Recipes vs backend recognizers – the line, drawn once

| | BackendPageRecognizer | SiteRecipe |
|---|---|---|
| answers | "which TASK is this page?" | "what FIELDS does this page show?" |
| output | TaskRef (+ project hint) | named evidence values |
| ladder position | above rules, 0.95, deterministic | feeds rules at 0.95 / features in ranked |
| learning | none – it is already the answer | grains for rules; features for the ranker |
| per-backend | one per connected backend | independent of any backend |

They compose without duplication: on an OP work-package page the
recognizer wins before rules are consulted; on every other page recipes
supply evidence the recognizer never claimed. Hard rule for recipe
authors: a recipe never parses task ids – the day a site's pages name
backend tasks (a Xero Projects deep link, say), that parsing belongs in
that backend's recognizer, where it gets the higher rung and the
project-scoped prior for free. Conversely the recognizer never grows
field extraction. No "OP recipe" exists, ever.

## 8. Extension mechanism

- **v1: built-in recipes only** – a static `SiteRecipes.builtIn:
  [SiteRecipe]` table in Core. The type is Codable data throughout
  precisely so the later phases are additive: a bundled JSON pack
  (updatable without an app release), then user-taught recipes via the
  point-and-teach element picker the context-rules spec §5.1 sketched
  ("click the bit of the page that says the client name", never "paste a
  DOM selector").
- **Per-recipe enable toggles** live in the ledger's recipe strip (default
  per §0 Q4); a disabled recipe extracts nothing, its rules go dormant
  (kept, listed, greyed – deleting a user's rules because a toggle
  flipped would be data loss).
- **Compliance rule for all recipe authorship, now and later**: a recipe's
  sources may read ONLY the sensor-observed page – URL, window title, and
  (Tier 1) the visible DOM. No recipe may ever incorporate backend-API
  text (task subjects, contact lists, project names fetched over HTTP) –
  that is the LearningStore invariant extended to the recipe layer, and it
  is what keeps recipe fields legal as learned features under the Xero
  T&Cs. The existing "backend text never becomes a learned feature" check
  gains a recipe case: seed a signal on a recipe'd host, assert every
  emitted feature value derives from the signal's own app/title/URL.
- **Tier 1 beyond Gmail** (Outlook/Proton selectors, CRM client names) is
  explicitly later: it inherits the whole EmailCaptureEngine discipline –
  subprocess + deadline, one in flight, view gate, same-surface
  application guard – and should arrive together with the enrichment
  plumbing generalisation (§11), not before.

## 9. Privacy posture and staleness guards

- **Captured**: nothing new in v1. Every field is parsed from the
  app/title/URL triple the sensors have emitted since day one; recipes
  add structure and names, not reach. The Evidence Card's ghost rows keep
  absence visible (a field that didn't extract says "not captured").
- **Never captured**: page body text, DOM content outside a Tier 1
  recipe's declared selectors, anything on a disabled recipe's pages,
  anything off-screen. Recipe field values are never written to DebugLog
  (the email-capture precedent: log mechanics and failures, never
  content).
- **Persisted**: a committed SiteRule's value lands in siterules.json –
  the accepted bar (emailrules.json already holds correspondent
  addresses, which are more sensitive than a repo name). Rules export via
  the ledger's existing user-initiated "Copy rules" only. Nothing
  recipe-derived is pushed to any backend or sync transport.
- **Staleness guards, by tier**: Tier 0's inputs cannot be stale (the URL
  is the signal), except the window title on SPA navigation – so content
  fields are (a) gated by the viewGate (only extract a doc title when the
  URL says a doc is open) and (b) validated by their own source shape
  (suffix must match or the field ghosts). Tier 1 keeps the full Gmail
  battery: viewGate as the cached-DOM gate (`isMessageView`'s
  generalisation), the async probe's deadline and single-flight limit,
  and SessionTracker's same-`Surface` drop of late enrichments.
- **Permissions**: none new. Tier 0 uses the existing Accessibility
  (titles) and Automation (tab URL) grants; Tier 1 reuses the existing JS
  channel grant Gmail already exercises. No Info.plist change, no new TCC
  prompt, the andeyett-dev signing identity untouched.

## 10. Acceptance criteria (andeyeTTChecks style – pure Core, seedable)

1. Host matching: anchored suffix semantics (github.com matches, notgithub
   .com and github.com.evil.example do not); mail-system hosts never
   produce a SiteContext.
2. Extraction fixtures per recipe: real URL/title pairs (GitHub issue, PR,
   repo home, reserved path; Docs document/sheet/Drive folder, suffix-less
   lagging title; Xero org/section pages once verified live) produce
   exactly the expected fields; viewGate failures produce nil; missing
   fields are absent, not empty strings.
3. Chain shape: a recipe-matched signal's ContextIdentity is host + ◆
   fields + content, with NO raw path duplication; a recipe-less URL keeps
   today's PinScope chain byte-for-byte (regression).
4. `SiteMatcher.match()`: most-specific-wins over the recipe's declared
   order, `site` below all recipe fields, pinned beats learned at a level,
   newest unpinned wins ties, content fields match by case-insensitive
   substring – the EmailMatch scenarios ported.
5. Attributor rung: a SiteRule wins over primes and the ranker at 0.95;
   loses to a pin, a sticky and a recognizer task URL on the same signal;
   fireCount/lastFired bump only on a real `attribute()` win;
   `onFirstFire` fires once at 0→1.
6. Un-learn: `forgettable` returns the unpinned SiteRule that fired
   (nil for pinned); `forget` removes exactly it; `explainWithout`
   restores state byte-for-byte.
7. Features: a recipe-matched signal emits `.recipeField` features for
   identity fields only (never content); learning.json with unknown-kind
   rows still decodes (additive migration).
8. Compliance: the "backend text never becomes a learned feature" check
   extended per §8 passes on recipe'd hosts.
9. Review derivation: a seeded ReviewSegment with a GitHub tabURL yields
   the repo grain in the footer's offer; disagreeing batch evidence
   degrades to the shared `site` grain.
10. Ledger: SiteRules group/sort/export like EmailRules (parallel suite).

## 11. v1 scope vs later

**v1 (one /vs session)**: `SiteRecipe` model + `SiteRecipes.extract` +
the three built-in Tier 0 recipes (§4, Xero gated on live verification);
`SiteRule`/`SiteMatcher` + the Attributor rung with fire provenance,
first-fire hook and the forget/explainWithout family; the `site` level
per Q2; `.recipeField` learned features per Q3; ContextIdentity recipe
branch (replace, not splice); grain-commit paths in the card and both
footers; ledger "Sites" segment + recipe strip toggles; the Settings
diagnostics "what recipes see here" row; checks 1–10; MANUAL.md +
site manual page ("Site rules" section beside the email one).

**Later**: fold Gmail into the recipe model (migrate `EmailSystem`'s
selectors and `isMessageView` into a Tier 1 recipe and emailrules.json
into siterules.json – a real migration on a live, soak-verified pipeline,
deliberately not risked in v1); the bundled JSON recipe pack + update
channel; point-and-teach user recipes and the AI-assisted selector
derivation; Tier 1 recipes beyond mail (CRM client fields) with the
generalised enrichment plumbing; the shared rule-domain protocol refactor
across Email/Calendar/Site (now justified, three verses in); per-recipe
ladder reordering in Settings (email's reorderable ladder, generalised);
the ambiguous-page policy note's remaining half – sticky-on-unknown and
red-certainty display – once Martin steers sticky-vs-review.
