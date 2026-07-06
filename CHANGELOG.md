# Changelog

## 2026-07-06

- [x] **Site demo rebuilt: fixed-size windows, one andeye Time view at a
  time, live local clock, second-person story v2** (site/src/pages/
  index.astro). The Mail window never changes size again: reading view is
  a preview-rail + pane grid inside a fixed-height window, click-outside
  returns to the inbox – and the root cause of the original "window grows"
  bug is fixed properly (`[hidden]` loses to author `display` rules per
  the CSS cascade; a `[hidden]{display:none!important}` reset now wins).
  The andeye Time window shows the timeline OR the pie, switched by
  orange-underlined chrome buttons, like the real app. Story: client is
  now Sarah Coleman (a person) who runs a bakery, saying yes to "the
  spring retainer – where do I sign?"; research is the first Chrome tab
  and its own tracked project; all three tab drawings are fresh,
  render-verified compositions (kitten-and-yarn video page, bakery site,
  sector-outlook article). The whole demo anchors to the visitor's local
  clock (heading daypart, menu-bar clock, email times, timeline start;
  no-JS fallbacks kept). Sitewide: no ALL-CAPS anywhere (andeye is
  lowercase), "Your timesheet writes itself in three moves" as a
  hover/click flowsheet with a reserved detail panel, privacy split into
  four click-accordions (gist headline + dig-in body, "Only what you
  approve ever leaves" now its own entry), Community/Pro as tabs with a
  sliding orange underline, eyebrow mini-logos that draw on and wink per
  section, the red→green certainty phrase set in an actual gradient,
  menu-bar logo/clock gap closed, waitlist mailtos → time@andeye.com.
  Adversarial review: one major (the [hidden] cascade bug), two nits, all
  fixed; needs a Mac-browser eyeball for the reserved panel heights.

- [x] **Manual: winking logo header, "Getting help" page, standing rules**
  (site/src/components/AndeyeSiteTitle.astro, site/astro.config.mjs,
  site/src/content/docs/manual/{getting-help,index}.md, CLAUDE.md). The
  manual's Starlight header now carries the andeye mark as a live canvas –
  draws itself on at load, winks occasionally (eyelid close, visibility-
  and reduced-motion-aware), and clicks back to the one-page app; geometry
  is a verbatim port of AndeyeLogo.swift via index.astro with a
  keep-in-sync comment. New "Getting help" page: GitHub Issues/Discussions
  walkthrough for everyone (written for non-developers), time@andeye.com as
  the andeyePro support channel, and an honest paragraph on why
  person-to-person support is one of the things Pro pays for. CLAUDE.md
  gained the manual's standing rules: keep up with the app but never at the
  cost of user-friendliness; comprehensive but concise; written for the
  fresh reader (no X→Y change history, no self-flagellation); code-drawn
  illustrations, never screenshots. Adversarial review: clean bar two nits
  (em-dash comments, opener register), fixed.




















## 2026-07-05

- [x] **Site demo back to basics: second-person story, andeye Time window
  on the demo desktop** (site/src/pages/index.astro). The demo drops the
  named-career persona (the freelance designer) for a career-neutral
  second person — "Your Tuesday morning, 9:41" — since any career label
  forces the visitor to identify with someone else, and the paying
  audience (people who invoice; the Xero tier) only needs to recognise
  their own desk: an inbox, a client saying yes to *the proposal*
  ("where do I sign?"), the accountant, a mid-certainty research tab,
  one honest kitten. The timeline + pie stop being a separate section
  below the Mac frame and become the **andeye Time window on the demo
  desktop itself** — truer to the product and it restores the everything-
  visible-at-once layout the four-window grid had broken. Three work
  windows on top (Mail, Chrome, Pages proposal doc; design app and chat
  removed), andeye Time full width beneath, never a tracked surface and
  excluded from the idle hint pulse. Billable framing made honest and
  explicit: only client work is billable (Accounts = "your books",
  Anthropic = "reading", Kittens = "break") with a live "Billable so
  far" total under the legend, and the caption lands the money hook:
  "the billable slice is your invoice, and you never wrote anything
  down". All three browser-tab drawings plus the proposal document are
  fresh compositions (the kitten is now mid-pounce after a ball of yarn
  in a video player — nothing shared with the earlier head-and-box art).
  Astro build green; adversarial review clean bar one stale comment,
  fixed.

## 2026-07-04

- [x] **Context rules UI phase: the Evidence Card, un-learn, and the Rules
  Ledger** (2026-07-03-context-rules-ux.md, Option A + grafts, MVP items
  4/5/7 of §6; Core items 1-3 landed earlier WIP 2e6f784). New
  `EvidenceCardView` (andeyeTTUI) — one view, two hosts — shows BECAUSE (the
  source that fired, with the matched rule's/pin's provenance), a live
  `[✕ forget]` / `[✕ suppress]` with the "would then fall back to…" preview
  rendered BEFORE the click, the `sees:` evidence line (ghosts for
  not-captured fields, never hidden), and a `Wrong? file as` fix flow with
  the grain ladder rendered as labelled full-width rows (↑/↓ move the
  grain, Once/Remember/Return/⇧Return/Always). Reachable from the popover's
  new why-caption (⌘E, inline expansion under the header) and from the
  timeline's per-window panes (replacing the old monospaced `detailText`
  dump). Retired the silent `learnEmailRule` call from `Attributor.confirm`/
  `assign` per spec §5.4 — a plain correction no longer writes a durable
  rule behind the user's back; the card and the popover's new post-pick
  grain footer propose one instead, undoable like everything else via the
  existing `UndoStack`. New Rules Ledger window (Settings ▸ Email → task
  matching ▸ "Context rules…") lists every learned + pinned rule grouped by
  task with provenance (origin, created, fired, last fired) and a per-row
  delete. Core additions: `Attributor.learnEmailRule` gained an explicit
  level/value/pinned/origin path (the auto-detect default stays for direct
  callers); `ContextIdentity.cardDefaultGrainIndex` (the card's own
  conservative default — domain for an org, address for shared webmail,
  narrowest-available when no correspondent captured — deliberately NOT the
  pin editor's most-specific-available `defaultGrainCount`);
  `SegmentKind.emailMatchLevel`/`Segment.emailMatchValue` (the grain→rule
  commit mapping, unlike `pinPredicate` treats the system row as a real
  EmailRule level so "Always: everything in Gmail" is representable); new
  `RulesLedger.grouped` (pure sort/filter). 13 new checks (CardDefaultGrain,
  EmailGrainCommitMapping, RulesLedger suites) plus 6 existing checks
  updated whose scenarios depended on the retired silent call (confirm/
  assign now teach a rule only when the check calls `learnEmailRule`
  directly, matching the new UI-driven flow). Deferred to later polish
  (spec §6, unchanged from the diagnosis): first-learn/first-fire toasts +
  screen-share suppression, site recipes beyond Gmail, review-queue grain
  footer, multi-correspondent checkbox expansion, ledger row opens the
  card, bulk-forget/export. UNVERIFIED — no Mac available to build/run
  `andeyeTTChecks` or eyeball the SwiftUI; every signature was grepped
  against the landed Core, not compiled.

- [x] **Landing: Martin's demo refinements re-applied natively, original
  voice restored.** The mechanics from the directed iterations (story cast
  with Priya@x-accounts.com, click-to-open emails, four designer windows,
  macOS traffic-light focus with dimmed background windows, no autoplay,
  working menu bar [winking mark · elapsed · one-word task], line-art Chrome
  tabs incl. the still kitten, clickable timeline + pie, orange hero, varied
  red→green certainty) kept; the copy pass reverses the drift Martin flagged
  ("the copy went downhill fast"): the hero lede is back to the original's
  cadence ("attributes your time to tasks by itself &ndash; on your Mac,
  never phoning home"), the demo intro carries the eye-follows/winks line
  with the corrected red/green, and the privacy section returns to the
  original's three tight blocks ("the eye answers to the person it watches",
  "Learning stays local", "Your rules, on your disk") with the single false
  claim patched honestly ("the only thing that ever leaves is a finished
  time entry you approve"). All three bake-off treatments preserved at
  docs/site-treatments/ for the record. Build green, 10 pages.

- [x] **Ambitick removed from the codebase entirely (migrations are done).**
  Martin: he wants the old working name gone, kept only as a private note.
  The data-folder and keychain migrations have run on the only machine that
  matters, so the backward-compat code was now dead and safe to drop:
  `AppSupport.directory` no longer moves a legacy `Ambitick/` dir (just
  returns the `andeye` home); the four migration checks in MacChecks are
  replaced by two plain data-home checks; `make-app.sh` drops the
  `ambitick-dev` keychain-migration block and the `Ambitick.app`/process-name
  handling; `install-andeye.command`, `APIKeyStore`, the integration scratch
  subject, CLAUDE.md's hard-rules and entitled-build's keychain reference are
  all cleaned. 
  NOTE: removing the auto-migration means a machine still holding
  Ambitick-era data would start fresh rather than adopt it - there are none,
  but it's no longer a safety net. Checks not run here (no Swift toolchain);
  run `swift run andeyeTTChecks` on the Mac (net -2 checks in the suite).

- [x] **Landing accuracy fixes, manual leads with auto-tracking, image
  strategy.** From the adversarial accuracy review (no blockers): the OBSERVE
  copy drops the absolute "that is the whole feed" claim (the AGPL-visible
  `MicMonitor` makes an exhaustive "this is everything we watch" statement
  false), so the page is selective without over-claiming - the untested
  mic-in-use sensor is left unmentioned rather than advertised, since naming
  it reads as eavesdropping on calls; "what a message was about" tightened to
  "its subject line"; "files in your home folder" corrected to andeye's own
  folder.
  The manual now leads with Auto-tracking and attribution (sidebar + Overview
  both reordered; the Overview opens on "there is no start button" - the
  automatic experience is the starting point). Added a manual image strategy
  spec (docs/superpowers/specs/2026-07-04-manual-image-strategy.md): where
  images live (src/assets, Astro-optimised), PNG-for-UI/SVG-for-diagrams,
  light+dark for key shots, alt-text and a staleness manifest, and the split
  between Mac-captured screenshots and agent-authorable diagrams.

- [x] **Finished the Ambitick residual sweep.** The 2026-07-03 rename passes
  left reader-facing mentions behind: the README's H1 area carried a "the
  original working name was Ambitick" parenthetical (removed - public
  baggage), the README cited the old `2026-06-10-ambitick-design.md` spec by
  name (dropped), two `github.com/aqueum/ambitick` test-fixture URLs in
  ContextRulesChecks (→ `andeyePro/andeyeTT`), and a stale "(previously
  'Ambitick Time')" TODO parenthetical (removed). Genuinely load-bearing
  strings (the legacy Application-Support dir migration in AppSupport /
  MacChecks, the `ambitick-dev` keychain path in make-app.sh, the OP scratch
  subject) and dated historical specs/plans are deliberately kept. Local
  Xcode `xcschememanagement.plist` still names old schemes - regenerates on
  the next `xcodegen`, not hand-edited.

- [x] **Landing page major revision: story-driven demo, honest certainty
  colours, honest privacy claim, real timeline + pie, hover-reactive CTA.**
  Five coherent changes to `site/src/pages/index.astro` (still fully
  self-contained, CSP-safe, reduced-motion respected, body never scrolls
  horizontally):
  - *Certainty colour fixed to the app's truth.* The old copy/demo said the
    tint was "grey when unsure, amber when sure" — wrong. `MenuTitle.colour`
    blends `#FF3B30` (systemRed) → `#34C759` (systemGreen) linearly by
    certainty, so the mark is RED when unsure and GREEN when sure. The demo's
    `certRGB` and the caption/how-it-works copy now match.
  - *Story-driven demo.* Replaced the generic clickable surfaces with a
    freelancer's Tuesday morning. An email client with three correspondents —
    Maren Vale (a rebrand/website client → "Maren · rebrand"), Priya the
    accountant (→ "Accounts · Q2 invoices"), and Anthropic (→ "Claude
    integration") — plus a browser with three tabs: Maren's staging site and a
    localhost tab (work) and a kitten video (an honest, non-billable break).
    Click any email or tab and andeye attributes the time to the job that
    correspondence/tab belongs to; the clock restarts, the eye winks, the tint
    blends red→green by confidence. Auto-plays a scripted loop until first
    interaction, then hands over.
  - *Real timeline + real pie below the demo,* fed by the demo's accumulated
    attribution and growing as the story plays. Slices/wedges are coloured by
    project via the app's HSB(hue, 0.55, 0.85) palette (AppController.colour);
    the pie is a donut-with-a-hole (time-by-project) with a legend that flags
    the break as not billable.
  - *Hover/focus-reactive CTA subtext.* One line under the buttons that changes
    on hover or keyboard focus: a build-from-source line for "Star on GitHub",
    a plain-English "a ready-to-download app is coming, we'll email you" line
    for "Join the waitlist", and a neutral default otherwise.
  - *Privacy claim reframed honestly.* Dropped the false "nothing ever leaves"
    framing. New centrepiece: the raw signal (what you looked at, page
    contents, correspondents, attribution, learning, pin rules, the SQLite
    journal) never leaves your Mac and andeye Ltd receives nothing; the ONLY
    thing that travels is the finished time entries you approve, to your own
    OpenProject / Xero. Also fixed the meta description and the OBSERVE step.
  `npm run build` green at 10 pages; node_modules removed after build.

- [x] **Landing page: the "Watchful" treatment (Fable-authored original) is
  the `/` route.** Martin picked it from the three-way bake-off (Instrument /
  Ink / Watchful — all three authored by Fable 5 subagents just before the
  session credit limit; the drafts were never committed, which mis-attributed
  the page to the later session that wrapped it). The hero is a playable
  menu-bar demo: the living andeye mark (verbatim AndeyeLogo.swift geometry —
  draw-on, eyelid-close wink), clickable app surfaces, attribution following
  focus. This is the ORIGINAL treatment; the demo-refinement iterations
  Martin directed later (story cast, macOS traffic-light focus, clickable
  timeline/pie, red→green certainty fix et al.) live on the `opus4.8` branch,
  to be merged or re-applied here. `npm run build` green, 10 pages.

## 2026-07-03

- [x] **Contributor-facing governance: CONTRIBUTORS roster, CLA
  plain-English summary, CONTRIBUTING explanation.** Adds CONTRIBUTORS.md
  (the signing roster CLA.md already references), a plain-English summary
  box at the top of CLA.md (additive; the binding clauses are unchanged),
  and a CONTRIBUTING.md rewrite that links CLAUDE.md and explains honestly
  why the CLA exists (AGPL and the App Store are incompatible, per the VLC
  precedent, so dual-licensing is what lets one codebase be the community
  app and the iPhone/Pro app). Note for review: the CLA still has no
  explicit governing-law clause.

- [x] **Root CLAUDE.md: orientation map for agents and humans.** Module
  layout (lowercase `andeyeTT*`/`andeyeApp` targets, UpperCamelCase types),
  build/check/run commands, the load-bearing legacy-string and
  keychain-identity rules, and the TODO/CHANGELOG conventions.

- [x] **Website scaffold: Astro + Starlight in `site/`, built for Cloudflare
  Pages.** One Astro project serves both the marketing landing page (`/`, a
  swappable placeholder until the chosen treatment is productionised) and the
  full manual (Starlight at `/manual`, search on). The manual is seeded by
  splitting MANUAL.md into eight pages (getting started, auto-tracking &
  attribution, pinning, the menu-bar popover, the time window, settings,
  sync & safety, keyboard). Static output, no SSR adapter; `npm run build`
  green (10 pages). `site/README.md` carries the exact Cloudflare dashboard
  settings (root directory `site`, build `npm run build`, output `dist`).
  Design decisions recorded in docs/superpowers/specs/2026-07-03-website-design.md.

- [x] **A pinned Gmail surface can now reach the grain ladder — reopen a
  root site pin and it opens INTO the ladder, system grain selected.**
  Martin: "Going into various emails does not show [the ladder]" — one broad
  mail.google.com (or legacy) pin covers every email, so each one showed the
  📌 chip; reopening a `.components` pin deliberately suppressed the ladder
  (3d2d122's round-trip guard), so the ladder was unreachable exactly where
  it's most wanted: "the whole site is pinned, narrow it to this
  correspondent". Root URL pins on an email surface now reopen into the
  ladder with the system/site grain selected by its OWN index (so a
  reordered ladder can't misindex; re-committing untouched rebuilds the
  identical root PinScope, id reused). Deep path pins and app pins still get
  the classic strip — they have no ladder equivalent.

- [x] **Module-level case rename: `AndeyeTT*`/`AndeyeApp` → `andeyeTT*`/`andeyeApp`.**
  Brings every SwiftPM target/product/directory in line with Martin's
  lowercase-module convention (module `andeyeTTCore`, matching the sibling
  `andeyeProBackends`/`andeyeProChecks` targets in the Pro repo) — only the
  identifiers change, Swift TYPE names stay UpperCamelCase
  (`AndeyeLogo`/`AndeyeLogoImage`/`AndeyeScenes`/`AndeyeApp` the `App` struct
  all untouched). Renamed: `Sources/AndeyeTTCore` → `andeyeTTCore`,
  `AndeyeTTMac` → `andeyeTTMac`, `AndeyeTTUI` → `andeyeTTUI`, `AndeyeTTStore`
  → `andeyeTTStore`, `AndeyeTTPhone` → `andeyeTTPhone`, `AndeyeTTChecks` →
  `andeyeTTChecks`, `AndeyeTTIntegration` → `andeyeTTIntegration`,
  `AndeyeApp` → `andeyeApp`; Package.swift targets/products/dependency
  strings and `swift run` comments follow; `ios/project.yml`'s three
  `product:` lines and every `import AndeyeTT*` across Sources/ and
  ios/Sources (~50 files) now read lowercase; `scripts/make-app.sh`'s
  `--product`/bin-path lines follow. **Pro-side fallout: the Pro repo's
  imports must change too** — `import AndeyeTTCore` etc. now fail to
  resolve; every Pro file importing this package needs `import
  andeyeTTCore`/`andeyeTTMac`/`andeyeTTUI`/`andeyeTTStore`/`andeyeTTPhone`.
  **First Mac build after pulling this needs `rm -rf .build`** — a
  case-insensitive filesystem caches build products keyed by directory name,
  and `AndeyeTTCore`/`andeyeTTCore` collide there; stale cache from the old
  case causes confusing build errors otherwise. Also run `cd ios &&
  xcodegen` to regenerate `andeye.xcodeproj` from the updated `project.yml`
  (the pbxproj itself was left untouched here — it's generated and has
  Martin's uncommitted local edits).

- [x] **Ambitick mention purge — the residual-name sweep the 4e7a393 module
  rename deferred.** Every remaining "Ambitick"/"ambitick" mention now says
  the right new name: check fixture strings and their assertions updated
  together (menu-suffix check is now `"andeyeTT design"` → `"21m andey"`;
  the learned-titleToken expectation follows the lowercased `"andeyett"`;
  the regex-operator fixture is `("andeyett", "and.?y")`; case-insensitivity
  checks keep case-differing needles), example URLs/segments moved from
  `aqueum/ambitick` to `andeyePro/andeyeTT`, temp-file scratch names to
  `andeyett-*`, code doc-comments and the Settings caption ("21m andey")
  swept, TODO/.gitignore/entitled-build/overnight-memo updated
  (entitled-build now carries the rename plan's `com.andeye.mac` /
  `iCloud.com.andeye.mac` IDs and the real `AndeyeJournal` zone), the
  2026-07-02 taskref-remote plan's file paths follow the renamed tree, and
  the three dated 2026-06 Ambitick plans/specs keep their filenames+content
  as historical record with a one-line "now andeyeTT" gloss. LEFT IN PLACE
  deliberately: the legacy data-dir migration strings (`Ambitick/` support
  dir in AppSupport + MacChecks — they must match old installs), the
  pre-rename quit/retire lines in make-app.sh and install-andeye.command,
  make-app.sh's existing `~/ambitick-dev.keychain-db` (renaming would mint a
  new identity and void TCC grants), the OP integration scratch-WP subject
  (reuses the live WP; rename plan says leave), the `ambitick` Mac build
  user in the overnight memo (real account name), CHANGELOG history, and
  ios/andeye.xcodeproj/project.pbxproj (stale generated `AmbitickCore/
  Store/Phone` productRefs — regenerate on the Mac with `cd ios && xcodegen`
  from the already-correct project.yml rather than hand-editing).

- [x] **Pin editor grain ladder — pin an email by correspondent, domain or
  subject, visually, no typed expressions (pin-editor slice of the
  context-rules-ux spec).** Martin: "I don't want to have to pin every single
  email, but … I do need the ability to pin them by correspondent email
  address and domain … a really intuitive interface for this." Deliberately
  the pin-editor slice ONLY — no Evidence Card, no un-learn, no rules ledger,
  no toasts (those stay open, see TODO). When the popover's pin editor
  (Components mode) opens on a surface with email evidence, it now shows the
  broad→narrow email ladder (Gmail ▸ harborlane.example ▸
  r.naismith@harborlane.example ▸ "subject") instead of the bare URL/app
  strip, fed by `ContextIdentity` (landed WIP 2e6f784) via a new
  `AppController.pinEmailIdentity()`. Same interaction as the proven strip:
  click a segment, ← wider, → narrower, ↵ commits — but clicking a segment
  SETS that single grain (Option B's model) rather than accumulating a
  prefix. Mapping: correspondent/domain/subject grains commit as a single
  `PinRule.expression` leaf (`sender is <addr>`, `sender contains <domain>`,
  `subject contains <normalised text>`); the system/site grain (and any
  plain, non-email surface) keeps the existing `.components(PinScope)` root
  pin — "this whole site" is exactly what that already means, regardless of
  where the user's `emailMatchOrder` setting puts it in the ladder. Ghost
  ("not captured") segments render greyed, italic and unclickable; ← / → skip
  over them via a new pure `ContextIdentity.steppedGrainCount`, so a ghost is
  never reachable at all, matching the spec's "rows are never hidden, their
  absence IS the coverage signal" without ever letting one become the
  selection. Reopening an email-grain pin round-trips: a system/site pin
  reopens in the classic Components strip (it IS a plain PinScope pin); a
  correspondent/domain/subject pin reopens in Expression mode with the rule
  rendered back to text (deliberately not reverse-mapped onto the ladder —
  the spec explicitly allows this as the simplest correct behaviour). +8
  checks (`isEmailGrain`/`pinPredicate` mapping incl. ghosts, `defaultGrainCount`,
  `steppedGrainCount` incl. ghost-skipping and both-edges clamping). Not
  verified on-device (no Swift toolchain in this environment — Mac-side
  smoke test needed: open the pin editor on a captured Gmail message, confirm
  the ladder renders and each grain commits/reopens correctly). Out of scope
  (see TODO): the Evidence Card (see-why, un-learn, live fallback preview),
  first-learn toasts, the Rules Ledger, and the shared-webmail caution tint
  on the strip.

- [x] **Gmail correspondent capture is live again — async, deadline-bounded,
  one probe in flight (capture layer of the correspondent-attribution
  programme).** The 2026-07-03 diagnosis (a90fe90) found capture had been off
  since the 6-30 freeze-revert (5439a83): every live signal carried nil
  correspondents/subject, so the whole email-rule system (EmailRule ladder,
  sender/domain pins, email-keyed stickies) was dead code at runtime. Fix per
  the diagnosis's fix design: new `EmailCaptureEngine` (AndeyeTTMac) replaces
  every `NSAppleScript` round-trip — main-thread-bound, the actual cause of
  the freeze — with an `/usr/bin/osascript` SUBPROCESS run off a background
  queue, hard per-call deadline, watchdog kill. `SensorHub.poll()` emits the
  plain `.focus` signal immediately (never blocks) and only on a
  surface-change onto a chrome-like browser sitting on a KNOWN, recipe'd mail
  host (`EmailSystem.hasRecipe`) kicks a capture off fire-and-forget, one in
  flight at a time (a request while busy is dropped, not queued). The result
  comes back as a new `SensorEvent.focusEnrichment`, applied RETROACTIVELY by
  `SessionTracker.applyEnrichment` to the still-open span — but only if the
  surface is still the one the probe was captured for (`Surface(signal:)`
  equality); a probe that outlives the user's next focus change is dropped
  silently, never mis-tagging whatever is open now. The diagnostics "Probe
  email sender" button now shares the same engine
  (`EmailSignalProbe.buildReport()`, run via `Task.detached` so it no longer
  risks even its own AX-crawl blocking main). +9 checks (3 SessionTracker
  retroactive-enrichment scenarios incl. the stale-surface drop; 6
  EmailCaptureEngine pure gate cases — the `osascript`/`Process` execution
  itself is impure and browser-dependent, so it needs the on-device soak the
  diagnosis explicitly calls for: "191 green checks did not catch a
  main-thread stall" was the 6-30 lesson). Out of scope here: the Evidence
  Card / un-learn UI (context-rules-ux spec, Core layer landed WIP in
  2e6f784, unverified, UI phase not started) and the base poll's own
  tab-URL/title AppleScript hazard (TODO.md — a separate, lower-probability
  instance of the same freeze class, left for its own fix).

- [x] **Menu-bar jiggle killed; wink is now an eyelid close on task change.**
  Martin: "when seconds are counting, the logo is jiggling" — the logo image
  was a fixed 28×18 canvas all along; the 1 Hz seconds text ("41s"→"42s")
  changed width in proportional digits and the right-anchored status item
  dragged the logo with it (identical in the dot era, just invisible on a
  12 px circle). Fix: `.monospacedDigit()` on the menu Text plus a leading
  FIGURE SPACE (U+2007, exactly one tabular-digit wide) on single-digit
  seconds, so 9s→10s doesn't reflow either — no reserved width for minutes.
  Wink retargeted per Martin: tracked-task change winks, minute tick doesn't
  (was the reverse); stopped→tracking is a start, not a switch, so no wink.
  And the wink itself is redesigned from whole-mark vertical squash to a
  true eyelid close: left side and both eye corners pinned, top lid comes
  down a lot, bottom lid rises a little, meeting in a slightly-positive ‿
  line — closed control points fitted numerically (least-squares of the top
  lid onto the reversed raised bottom lid; max lid gap 1.6 SVG units against
  the 17-unit stroke, so they render as one line). AndeyeLogoChecks rewritten
  for the new invariants (corners/left side fixed, monotone lid travel,
  lids-meet gap bound, gentle-sag bound); MacChecks covers the pad.

- [x] **iOS timeline is now DRAWN, matching the Mac's (321 checks green,
  iOS simulator build succeeded).** Martin: "why did you ditch the beautiful
  and highly functional timeline from the mac app and replace it with a
  regular list?" — TimelinePhoneView's List replaced with a Canvas timeline
  mirroring the Mac look: horizontal time axis with adaptive hour ticks +
  labels (`TimelineMath.tickStep`, width-aware so labels never collide on a
  phone), coloured slice bars with task labels (same PhonePalette scheme as
  the pie/Now views), gaps as gaps, a red "now" line, and the live slice
  growing at the right with the Mac's zig-zag torn edge (same SliceShape
  geometry). Touch model: pinch-zoom anchored on the fingers + drag-pan,
  both clamped to today (`TimelineMath.clampViewport`, pure + checked);
  opens framed on the latest block like the Mac (`latestBlock`), "Day"
  toolbar button zooms back out. Tap a slice → read-only detail card (task,
  start–end, duration, live badge); edits stay Mac-side. Drawing factored
  into `ios/Sources/TimelineCanvas.swift` (no UIKit, no controller) and
  visually verified: rendered headless on the build Mac via ImageRenderer
  at 8 h / 24 h / 1 h zooms, light + dark, and inspected — matches the Mac
  bar. +4 TimelineMath checks (viewport clamp, tick step).

- [x] **Menu-bar icon now renders Martin's real andeye mark, not invented
  geometry.** He supplied the actual logo (assets/brand/andeye.svg +
  andeye-logo.afdesign, moved from repo root, 3-line README added);
  AndeyeLogo.swift now hardcodes its path verbatim — four cubics, translate
  applied, normalised to a unit-width box preserving the 365:235 aspect.
  Pupil/eyelid machinery dropped (his mark has none); the arc-length draw-on
  reveal stays, and the wink is now a vertical squash of the whole mark
  toward its centre (width preserved) so it can never mangle the curves.
  AndeyeLogoImage strokes at 17/365 width, round caps/joins, ~18pt tall ×
  ~28pt wide; certainty tint and AppController trigger plumbing untouched.
  Checks rewritten (contiguity, closed loop, reveal monotone/linear, squash
  bounds, aspect); geometry rendered to PNGs at 360×232 and 36×24 and
  visually verified against the SVG. 321 checks green.

- [x] **Full rename: the package is `andeyeTT` (317 checks green, iOS
  simulator build succeeded).** Martin's call — the core carries the brand
  for future adjacent apps. Targets/products: AmbitickCore→AndeyeTTCore,
  Store→AndeyeTTStore, Mac→AndeyeTTMac, UI→AndeyeTTUI, Phone→AndeyeTTPhone,
  App→AndeyeApp, CoreChecks→AndeyeTTChecks, Integration→AndeyeTTIntegration;
  public types AmbitickScenes→AndeyeScenes, AmbitickSettings→AndeyeSettings,
  version enum Ambitick→Andeye; CloudKit zone AmbitickJournal→AndeyeJournal
  (never minted, so free). Brand refs in comments/UI strings swept to
  andeye; the LEGACY data-folder migration strings keep "Ambitick" verbatim
  (they name the old on-disk dir). install-ambitick.command →
  install-andeye.command (still quits pre-rename installs). ios/project.yml
  package andeyeTT. Announced to the PRO vibe first (its product references
  need the new names on next sync); the Mac folder ../Ambitick and build
  user stay until Martin renames the folder. Clone URL in docs now
  andeyePro/andeye (Martin transfers/renames the GitHub repo).

- [x] **andeye logo in the menu bar — draw-on, certainty tint, minute wink
  (317 checks green).** The coloured dot is now the brand mark: an ampersand
  drawn as one continuous stroke whose tail closes into an eye (andeye =
  "&eye"), pure bezier geometry in `AmbitickCore.AndeyeLogo` (unit box,
  platform-free, 12 checks: contiguity, arc-length reveal linear in t, lids
  as the final draw phase, pupil under the lids, wink squash/clamps).
  `AndeyeLogoImage` (AmbitickMac) strokes it into the ~18 pt status-item
  image, tinted by the existing `MenuTitle.colour` certainty pipeline — the
  colour still means what it meant. On launch the mark hand-draws itself
  (t 0→1 over ~1.2 s, the end closing into the eye, pupil popping in last);
  each time the displayed tracked minute ticks over the eye winks
  (shut→half→open, ~360 ms). Both are fire-and-forget Task frame loops —
  no continuous animation timer; the 1 Hz title refresh is untouched.
  Visual result unverified until Martin rebuilds (geometry is check-proven,
  plus contrast-rendered off-Mac).

- [x] **iOS v1 feedback pass — Mac-popover feel + the Time pie/timeline
  (305 checks green).** Martin's on-device notes, all six: the "andeye"
  title is gone; share moved into a single hamburger menu with Settings;
  the huge stop button shrank to a small red stop control beside a compact
  name + elapsed row (the menu-bar popover feel); tapping the tracked task
  is now a no-op (`start` returns on `tracking?.task == task` — before, it
  restarted the timer on every tap); a tap still SWITCHES, but long-press
  offers "Re-label current timer as this" — new
  `PhoneController.relabelCurrent(to:)` moves the RUNNING slice onto the
  task keeping its start (checkpoint follows, nothing banked). And the
  Mac's coolest views came over: a LIVE mini-pie toolbar icon (Canvas +
  Core's PieGeometry) opens a Time page — donut by project, tap a wedge
  for its task ring, Today/Week picker, label-keyed selection — plus a
  read-only timeline list of the day's slices. New PhoneController data
  accessors `spentNodes(from:to:)` (live slice included, boundary-clipped,
  no app level) and `bankedSessions(from:to:)`. Five new checks: tracked-tap
  no-op, relabel keeps start + updates checkpoint + banks nothing, relabel
  idle no-op, spentNodes grouping, bankedSessions ordering.

## 2026-07-02

- [x] **Session-sticky categorisation — your word holds for the day (300
  checks green).** Martin's 23:27 report: composing an email, every
  leave-and-return re-ran the inference ladder and an older email rule
  re-took the slice for the wrong project. Now any explicit assignment
  (popover pick, review assign, timeline edit, do-not-track) records a
  `SessionSticky` keyed on the email's normalised subject (re:/fwd:
  stripped — a draft's window title mutates while typing, the subject
  doesn't), falling back to correspondent set, then focus surface. In the
  ladder it sits directly below explicit pins and above everything
  inferred (URL recognition, email rules, primes, ranker), expires at the
  local day boundary (the durable email rule the same assignment teaches
  takes over), and the why-panel names it. 10 checks incl. the verbatim
  report scenario.

- [x] **iOS engine moved into the checked package (290 checks green).**
  PhoneController left ios/ (where nothing compiles it until Xcode) for a
  new platform-neutral `AmbitickPhone` target: SwiftUI import dropped for
  Combine, data home + clock injectable. Eight new checks cover the manual
  tracker's behaviour — sub-30s taps discarded, slices journalled, live
  slice surviving app death and resuming on relaunch, switch = stop+start,
  local-task dedupe, fuzzy pick list, todaysTotal, CSV export. Only the
  SwiftUI shell in ios/ now waits for a machine with Xcode. Fixed en route:
  the check harness drove async suites from a semaphore-blocked main
  thread, which deadlocked any check hopping to the MainActor — now
  top-level await (SE-0343).

- [x] **Licence landed: AGPL-3.0 + CLA (Martin's call, 15:03 BST).** LICENSE
  is the verbatim SPDX AGPL-3.0-only text; CLA.md is an ICLA-style agreement
  granting andeye Ltd rights broad enough to dual-license the proprietary
  App Store builds; CONTRIBUTING's pending section now states both; README
  gains a Licence section. The staging kit (docs/licensing-staging/) deleted
  itself in this commit. Remaining before the repo flips public (WP 223):
  Martin reviews the CLA text and the CLA enforcement check gets wired.

- [x] **UndoStack extracted to Core (282 checks green).** The pure stack +
  grouping semantics behind the global ⌘Z (LIFO, group-bundles-to-one-entry
  with reversed replay, nested groups folding into the outermost, empty
  groups pushing nothing) moved from AppController into
  `AmbitickCore.UndoStack` with 5 checks; the controller keeps the sounds,
  notification and published count. First of the three review-flagged
  AppController extractions.

- [x] **PieGeometry extracted to Core + label-keyed pie selection (277 checks
  green).** The Time Spent donut's pure geometry (slice-angle layout, polar
  normalisation, radial band hit model, metrics) moved from SpentView into
  `AmbitickCore.PieGeometry` with 10 checks, sharable with the iOS pie.
  Fixes the parked fable2 review finding: hover/pin selection was positional
  (`project(i)`/`task(i,j)`) into a re-sorted nodes array, so a background
  reload while a wedge was pinned could silently retarget the pin — selection
  is now keyed by node labels and resolved against the current array each
  render (a vanished node clears the pin instead of retargeting; regression
  check covers the re-sort survival).

- [x] **Duplicate reconcile generalised beyond OP (267 checks green,
  11c6d0a).** `RemoteTimeEntry` is a real Core struct with String ids (was a
  typealias to OP's Int-id shape); `ReconcileAction` is backend-neutral
  (String taskID, RemoteEntryID survivor/deletes); OPBackend converts at its
  edge; journal matching goes through `task.backendTaskID`, so the duplicate
  scan works for any backend that can list entries. Closes the TODO left
  open by the TaskRef.remote migration.

- [x] **Rename phase 1 executed: the app IS andeye now (261 checks green).**
  Data home migrates `Application Support/Ambitick` → `andeye` via a checked
  one-shot MOVE (fresh-install / move-with-contents / one-shot semantics all
  covered); debug log → andeye-debug.log; make-app.sh builds andeye.app
  (bundle id com.andeye.mac, "andeye Dev" signing identity, quits/retires
  pre-rename installs); window titles + popover copy renamed; README/MANUAL
  swept (repo URL + module names deliberately keep the working name — see
  the rename plan's phase 2). NOTE FOR THE NEXT BUILD: new bundle id + new
  signing identity = macOS treats it as a new app — Accessibility and
  Automation get granted ONCE more.

- [x] **Seam: `supportsTaskComments` capability (255 checks green).** Xero
  Projects has no task-comment endpoint; rather than erroring per note, the
  controller now skips comment-to-task for backends that declare false (the
  note still lands on the time entry). OP declares true.

- [x] **`TaskRef.remote(String)` — GUID backends are first-class (255 checks
  green).** Executed docs/superpowers/specs/2026-07-02-taskref-remote-plan.md
  : additive third case, so
  every existing journal row / pin / email rule / primed surface decodes
  byte-identically — the wire format is now FROZEN by checks. The seam speaks
  String task ids (OP converts at its edge); backends declare `owns(_:)` and
  the SyncEngine skips un-owned eligible sessions silently (an .op session
  can never push to Xero — it waits for its own backend). `is_op` column
  keeps its name, means "remote/pushable". Recognizers return TaskRefs.
  AIAssist's reply grammar accepts GUID strings and now resolves ids through
  the live task cache — which also fixes a latent bug where a hallucinated
  id fabricated a nonexistent `.op` task. DuplicateReconcile stays OP-only
  (TODO'd). SEQUENCING: this ships one Community release before any GUID
  backend mints `.remote` refs (older builds can't decode the new case).

- [x] **Open-core app shape: the SwiftUI layer is now the `AmbitickUI`
  library; `AmbitickApp` is a three-line Community wrapper.** New
  `AmbitickScenes.body(controller:)` (@MainActor SceneBuilder) carries the
  MenuBarExtra + all windows; the private repo's Pro executable becomes the
  same thin wrapper plus paid-backend registration. `AmbitickMac`/`AmbitickUI`
  exported as library products for the pro package to depend on. Behaviour
  identical (bindings on the Time windows constructed explicitly — a static
  SceneBuilder has no `$controller`). the build bridge now cleans the remote
  Sources tree before syncing (tar never deletes, so moved files ghosted).
  245 checks green.

- [x] **Controller sync wiring + CloudKit transport skeleton (245 checks
  green).** New `escalateOrigin` on the journal protocol: deliberate user
  actions promote a slice's cross-device authority (timeline edit/reassign →
  `edited`, idle-gap claim → `manual`; auto tracking stays `auto`); promotion
  re-stamps + dirties (it must sync), downgrades are refused no-ops.
  `AmbitickSettings.journalSyncEnabled` (default OFF — store behaviour is
  byte-for-byte pre-sync until flipped); on enablement the controller mints a
  persisted device id, restores the HLC clock state (persisted per stamped
  mutation, so stamps stay monotonic across a wall-clock regression), excludes
  the crash-checkpoint row, and runs the idempotent backlog stamp.
  `CloudKitSyncTransport` (Mac layer, `canImport(CloudKit)`) maps
  SessionRevision ⇄ CKRecord in one custom private-DB zone — thin by design,
  Core's merge stays the authority; inert until the entitled build exists.

- [x] **Licensing rail (5 checks, 244 total green).** Core `License` /
  `LicenseTier` (plus/pro/premium/enterprise; Community = no licence, fully
  functional) with offline Ed25519 verification of `AMBI1.<payload>.<sig>`
  keys (dot-separated JWT-style; base64url payload is canonical sorted-keys
  JSON). Checks cover tamper (payload-swap upgrade attack), keygen (foreign
  private key), expiry vs perpetual, garbage inputs, whitespace tolerance.
  The production PUBLIC key is embedded; the private key + generator live
  only in the pro staging area (gitignored) pending the ambitick-pro repo.
  Settings gains a Licence section (paste key, tier/licensee/renewal status,
  problem line — an expired key explains itself rather than silently
  downgrading); controller revalidates on key change.

- [x] **RemoteEntryID widened Int → String (Xero-ready; 239 checks green).**
  The seam's entry id is now String (OP: ints, Xero: GUIDs); `OPBackend`
  converts at its edge and surfaces a non-numeric id as an error instead of
  silently no-opping. `Session.opTimeEntryID` widens with a custom decode so
  every pre-widening journal row (Int in the JSON) still reads — covered by a
  legacy-decode regression check — while encoding always writes the String
  form. DuplicateReconcile keeps Int on the OP-API side and compares via
  String at the journal boundary.

- [x] **SQLite journal becomes a sync replica (15 checks, 237 total green).**
  The sessions table now carries the revision meta (HLC triplet, origin,
  deleted, dirty) beside the row; `SQLiteJournalStore` conforms to
  `RevisionStore`. With a clock attached, every JournalStore mutation
  re-stamps + dirties (markPushed included) and deletes become travelling
  tombstones; without one, behaviour is byte-for-byte pre-sync (hard deletes,
  no stamping). All reads filter tombstones. The live crash-checkpoint row is
  sync-excluded (never stamped, never uploaded, hard-deleted).
  `stampAllUnstamped` is the one-shot enablement migration (start-ordered,
  idempotent). clearDirty is HLC-matched so an edit landing mid-push stays
  queued. New conformance suite runs against BOTH stores, plus an end-to-end
  check where a SQLite replica and an in-memory replica converge through the
  mock server.

- [x] **Sync orchestration: `JournalSyncer` + `SyncTransport`/`RevisionStore`
  seams (5 checks, 222 total green).** The replica sync cycle (pull → HLC
  receive → record-LWW apply → push dirty → clear) is pure Core, driven in
  checks by a `MockSyncServer` that reuses the same `SessionMerge` LWW.
  Proven scenarios: two offline replicas converge to identical raw sets and
  views; conflicting whole-record edits resolve to the later HLC on both
  sides; tombstones travel and a later edit resurrects; push echoes are
  idempotent (no duplicates, nothing left dirty, no re-push of clean
  records); a dirty local that wins LWW survives the pull and propagates.
  Remaining for real sync: SQLite adoption of `RevisionStore` + controller
  stamping (origin/HLC per mutation path), then the thin CloudKit transport.

- [x] **Sync foundation: design doc + pure-Core HLC/merge engine (11 checks,
  217 total green).** Decision (Martin): multi-master journal from day one —
  iOS-only users have no Mac to own it. New
  `docs/superpowers/specs/2026-07-02-sync-design.md`: every device holds a
  full SQLite replica; the raw revision set is the synced truth; overlap
  resolution is a DERIVED, deterministic view (never persisted/pushed — the
  one way LWW could diverge); one backend-pusher lease per account. Code:
  `HLC` hybrid logical clock (monotonic tick, causality-preserving receive,
  1 h drift cap), `SessionRevision` (hlc + origin + tombstone),
  `SessionMerge` — record LWW (newer delete beats edit, newer edit
  resurrects) + the overlap ladder (edited > manual > auto; ties by HLC;
  middle overlaps keep the loser's larger side; covered slices surface
  deleted). Convergence checked commutative and arrival-order independent.
  CloudKit is a thin transport adapter later (needs the Apple signing
  identity).

## 2026-07-01

- [x] **Menu clock: excursions no longer wear the old slice's elapsed ("11m
  Studi").** Since the 06-27 banked-under-count fix, the clock took
  `max(now − liveSliceStart, banked+running)` — correct for the task that owns
  the open slice, wrong during a grace-pending switch, where the display
  already follows the NEW task but `liveSliceStart` still spans the OLD task's
  slice: the menu bar paired the new task's name with the old task's clock.
  New `SessionTracker.liveSliceOwner` (the outgoing task until commit); the
  controller only applies the live-slice clock when the displayed task owns
  the slice, so an excursion shows its own visit time (what would post if the
  switch commits — the documented semantics). Found live by Martin right after
  the fable2 build swap; root-caused from the debug log (healthy pipeline,
  display-only). 1 new check; 206 green.

- [x] **Efficiency pass (from the fable2 whole-repo review).** (1) The 1 Hz
  `elapsedText` republish is now change-gated like its neighbours — it fired
  `objectWillChange` on the shared controller every second while tracking,
  re-rendering EVERY open window (timeline, pie, settings) at 1 Hz, 24/7; the
  single largest energy leak found. (2) Durable recency no longer decodes the
  whole sessions table once a minute: new `JournalStore.latestEndByTask
  (excluding:)` aggregates in SQL (`json_extract` + `GROUP BY` + `MAX(end)`).
  (3) `markPushed`/`assign` read-modify-writes now hold the store lock across
  the whole critical section (an off-main sync could interleave with a
  main-actor edit of the same row between their two lock acquisitions —
  last-writer-wins data loss). (4) Dead `refreshTick` state removed from
  Timeline/Spent (it forced a redundant extra body invalidation per poll).
  (5) Timer tolerances on the 60 s refresh and both 2 s pollers so the OS
  coalesces wakeups. 2 new store-conformance checks; 205 green.

- [x] **Timesheet export (standalone slice of Rank 9).** New pure-Core
  `TimesheetExport`: a period's sessions as RFC-4180 CSV
  (`date,start,end,duration,project,task,comment`) or day-grouped Markdown with
  per-day + grand totals. Settings ▸ Maintenance gains an "Export timesheet"
  row (period picker + Copy CSV / Copy Markdown via the clipboard); works with
  or without a connected backend — the standalone way OUT of Ambitick for
  invoicing. 4 new checks (203 total green).

- [x] **Backend seam (TODO Rank 9 core): `TaskBackend` protocol; OpenProject
  moves behind `OPBackend`.** New Core protocol `TaskBackend` (task list, time
  entries, task comments, `taskURL`, capability flag `supportsActivities`) plus
  `BackendPageRecognizer` (task-page/URL/title recognition for attribution).
  `OPBackend` wraps `OPClient` and owns every OP quirk — the startTime-422
  fallback moved here from `SyncEngine` (and now persists across syncs instead
  of resetting each run, since the controller holds one backend instance);
  `SyncEngine` is backend-agnostic. `Attributor` consults a recognizer (default
  = OP built from `instanceHost`, injected by the backend on connect) instead
  of calling `OPURLParser` directly. `AppController` talks only to
  `any TaskBackend`; standalone = nil backend (explicitly NOT a silent no-op
  sink: with no backend no SyncEngine exists, so nothing can be marked pushed
  without going anywhere). `RemoteEntryID`/`TimeActivity`/`RemoteTimeEntry`
  typealiases mark the spots that widen when Xero lands (entry ids become
  String GUIDs — one-line alias flip, compiler-guided). UI: activity picker
  hides for backends without activities; "open in OP" URLs come from the
  backend. 199 checks green; behaviour-preserving by design.

- [x] **Batch (drafted by subagents, integrated serially): pin grammar, smarter
  search, ladder-reorder UI.** (1) Expression pins gained `from`/`sender` (match
  the email correspondents), `subject`, and `any` fields; `PinField` is now
  multi-valued (a leaf matches if ANY value matches) and bare keyword text spans
  correspondents + subject too — so `from contains "harborlane.example"` pins all
  mail to/from a company. (2) Task filter is learning-backed: `LearningStore.
  learnedValues(for:)` feeds `FuzzyMatch.filter`, so typing "voting" finds the
  task you always work in a voting window even when its OP subject never says the
  word (gated at substring-or-better so weak subsequence noise can't leak in).
  (3) A Settings "Email → task matching" section reorders the specificity ladder
  via chevrons. Also confirmed the Review window already creates named local
  tasks. 199 checks pass; the two Core patches are fully unit-tested, the two UI
  bits need an on-device look.

## 2026-06-30

- [!] **Email capture REVERTED same day — it froze tracking.** The capture below
  ran a synchronous Chrome AppleScript/JS call on the 2s sensor-poll thread; in
  Gmail every email switch is an email URL, so every poll blocked, the sampler
  stalled, focus switches went unrecorded and time lumped onto the last task. Pulled
  the call from the hot path (the engine stays, inert). Must be redone async/off-main.
- [x] **Email auto-learner goes live: capture populates correspondents** — the
  sampler now, on a surface change to a recognised webmail MESSAGE, runs the page
  recipe and attaches the external correspondents (sender+recipients minus self,
  via the "me" heuristic) and subject to the `ActivitySignal`. It fires only on an
  email-URL surface change — non-email focuses pay just a host check, so no
  hot-loop cost (the per-poll URL read was already there). With the engine below,
  this makes it end-to-end: correct an email's task once → mail from that
  org-domain (or that person, for shared webmail) auto-attributes. `EmailSignal.
  subject(fromTitle:)` parses the subject off the tab title (unit-checked). NEEDS
  on-device validation (perf on thread-switch + that correspondents populate).
- [x] **Email auto-learner engine (Core, wired, zero live change yet)** — the
  correction→rule learner that drives email attribution. `ActivitySignal` now
  carries optional `correspondents` + `emailSubject` (optional → old journalled
  signals still decode, round-trip-tested). `Attributor` gained learned
  `emailRules` + the `emailMatchOrder`: a confirmation on an email surface learns
  a rule conservatively (an org domain generalises to the whole company; a shared
  webmail address — gmail/outlook/icloud/… — stays per-person), and a matching
  rule then auto-attributes via a new `.emailRule` source (caps 0.95, below a pin
  / OP-URL), resolved most-specific-first through the user's ladder. Rules persist
  in `emailrules.json`; the why-panel explains the new source. Because the Mac
  capture doesn't populate `correspondents` yet, production behaviour is
  unchanged — but the whole engine is unit-tested (learn-by-domain, shared-webmail
  per-person, non-email signals ignored). 191 checks pass. Next: the perf-gated
  Mac capture that fills `correspondents` and flips it live.
- [x] **Settings file is now wipe-proof — the OP URL survives any rebuild** —
  root-cause fix for the recurring "rebuild deleted my OP URL" bug. The settings
  decoder fell over whenever ONE field couldn't be read (twice now: a renamed enum
  rawValue), because `try decodeIfPresent(...) ?? default` rethrows a *throw* (it
  only catches nil); the whole file then failed to load, collapsed to an
  empty-URL default, and the next save persisted that over the real file. Now
  EVERY field decodes through a `lenient` helper that swallows its own throw and
  falls back to that field's default — so a renamed/removed/type-changed field can
  never take the file (or the OP URL) down again. Regression test covers a renamed
  enum, a wrong-typed field, and a good field together. NB you'll need to re-enter
  the URL once (the already-damaged file has it blank); after that it persists.

## 2026-06-29

- [x] **Email→task precedence ladder (user-editable backbone)** — the shared
  most-specific-wins ladder both the auto-learner and the pin will resolve
  through. New pure, unit-checked Core: `EmailMatchLevel` (emailSystem <
  senderDomain < sender < subject, general→specific), `EmailContext`, `EmailRule`
  (learned or pinned; a pin beats a learned rule at the same level), and
  `EmailMatcher.match` (most-specific matching level wins; subject matches by
  substring so RE:/Fwd: prefixes don't break it). The order persists in settings
  (`emailMatchOrder`, tolerant-decoded) so the user can retune it. 185 checks pass.
- [x] **Gmail sender extraction: channel + recipe found, typed foundation** —
  on-device probing settled the approach. Chrome keeps its renderer accessibility
  tree off (AXManualAccessibility didn't wake it — two ~65-node reads), so the
  channel is **page JavaScript over Apple Events**. A blanket `[email]` query was
  polluted by the 100+ inbox-list `.yP` rows Gmail keeps in the DOM; the validated
  recipe is **`.gD` = open-message sender, `.g2` = recipients**, and since Gmail
  names your own address "me" the external counterparty falls out cleanly (e.g.
  the broker's `@harborlane.example`). Shipped the typed foundation: `EmailSystem`
  (host detection + per-system selectors), `EmailSignal.Party` /
  `counterparties` / `domain` (pure, unit-checked), and
  `EmailSignalProbe.frontBrowserParties` (recipe-driven), all surfaced in the
  Settings ▸ Diagnostics probe (now shows System / Sender / Recipients /
  Counterparties / domains). 184 checks pass. Still to wire: sender/counterparty
  into the ActivitySignal + learner + pin `from` field, validation/self-heal, and
  more providers.
- [x] **Email-sender signal: backlog item + Gmail AX probe (prototype)** — logged
  the root flaw (capture only sees app/title/url; a Gmail tab exposes subject +
  account but never the sender, the most useful "which task" key) as a defined
  TODO: sender as a captured signal + learner feature + pin `from` field, subject
  trumps sender in specificity, a new `any` field spanning all fields, done across
  all major email systems via smart generalisations with self-learning (system- or
  AI-derived per-client hints). Started the prototype: `EmailSignal.addresses`
  (pure email extraction, unit-checked) + `EmailSignalProbe` (bounded AX walk of
  the front browser's focused window) behind a Settings ▸ Diagnostics button that
  reports the email-like strings and their AX roles and copies them to the
  clipboard — so we design the real extractor from live data. AX walk is Mac-only;
  needs an on-device run. 182 checks pass.

## 2026-06-28

- [x] **Pin editor AI mode (#11 final phase)** — a fourth hamburger entry for
  windows whose own app/title/url don't say which task they are. New Core builders
  (unit-checked): `AIAssist.pinRulePrompt` assembles a prompt from the captured
  fields + an editable guidance box (pre-seeded `defaultPinAdvice` nudging toward
  a stable pattern over a volatile title), and `AIAssist.cleanRuleReply` strips
  fences / trailing prose from the answer. The prompt is shown scrollable and
  auto-copied; the pasted reply is parsed by the existing PredicateParser into an
  ordinary **editable Expression rule** (↵ applies → review → ↵ pins), or shows
  the parse error. A **Fix with AI** button on an Expression parse error hands the
  failed rule into this mode. Controller gained `currentSurfaceFields()` and a
  generic `copyToClipboard`. 181 checks pass; UI flow needs an on-device check.
- [x] **Keyboard shortcuts across every surface + parity audit** — an Explore
  inventory confirmed every action already has a mouse path. Added ⌘-shortcuts to
  the daily-driver surfaces and put each chord in the control's tooltip and in
  MANUAL.md's rewritten Keyboard section. Popover: ⌘T flip Switch/Change, ⌘P pin,
  ⌘. stop, ⌘R resume, ⌘Z back, ⌘Y Time, ⌘U Review, ⌘, Settings, ⌘Q quit, ↵ in the
  filter picks the top task, ⌘↵ claims the idle gap. Time window: ⌘\ flip
  timeline/pie; timeline ⌘[ /⌘] pan, ⌘−/⌘+ zoom, ⌘B block, ⌘0 today, ⌘⌫ delete in
  editor; pie ⌘1–4 period, ⌘⇧O OpenProject-only, ⌘⇧C calendar, ⌘[ /⌘] month.
  Review: ⌘D do-not-track, ⌘⇧C copy prompt, ⌘↵ apply response, ↵ assigns top task.
  Settings/Review forms stay on standard macOS Tab/Space/arrow navigation. Builds
  clean; the key-window shortcut firing still needs an on-device check.
- [x] **Calendar click snaps to the preset width; drag = custom** — a plain click
  re-anchors the active preset's width on the clicked day (Today → that one day,
  Week → that day's week, Last 7 days → 7 days ending on today's weekday, Month →
  that month). Dragging across days, or shift-clicking, makes an arbitrary
  contiguous custom range instead. (Refines the entry below.)
- [x] **Calendar: selectable day-ranges + pie keeps full height** — the calendar
  is now an arbitrary day-range selector: click one day, drag across a span, or
  shift-click to extend (origin = the current selection's start). The pie shows
  exactly the selected days; a hand-selection that happens to equal a preset
  re-lights that preset button (new pure `TimePeriod.matching`, unit-checked),
  otherwise the picker reads "Custom". Also reworked the layout so opening the
  calendar no longer forces the pie up: the pie fills the full height on the left,
  the legend + calendar share that height in the right column, and the total /
  OpenProject-only controls overlay the pie's empty bottom-left corner. Dropped
  the **Yesterday** preset and shortened "This week"/"This month" to "Week"/
  "Month". 179 checks pass.
- [x] **Pie highlight-calendar + no timeline focus-ring** — the whole timeline
  bar had picked up a blue selection ring (`.focusable()` draws a focus effect);
  added `.focusEffectDisabled()` so arrow-key focus stays but the ring is gone.
  Then implemented the pie's calendar: a new pure `TimePeriod` enum in Core with
  an **anchorable** `range(anchor:now:)` (so a period can be viewed on any prior
  date, not just relative to today), unit-checked. A new `MonthCalendar` grid
  sits bottom-right below the legend: it highlights the days in the shown range,
  pages months (future months disabled), rings today, and re-anchors the pie on
  a tapped day — "This week" jumps to that day's whole week, "Last 7 days" to the
  7 days ending on today's weekday. The Today/Yesterday/… picker moved from the
  top of the window to below the calendar, and the calendar is closeable (✕ →
  a compact reopen button). 178 checks pass.
- [x] **TODO batch (drafted by subagents, integrated serially)** — 7 items, each
  built + checked + committed: Time-window titles per view (Timeline / Time Pie);
  pie "OpenProject only" + total moved bottom-left; optional per-pin **priority**
  override (Advanced) in the pin editor; **auto-prime a new local task** to the
  current window so its time files correctly from the first second; why-panel
  **weight controls** (boost/always via `Attributor.learnSurface`); a **true
  global ⌘⇧L** away hotkey (Carbon, fires from any app); **arrow-key slice
  navigation** in the timeline (←/→ move, ⇧ extends, Return edits). 175 checks
  pass. (Two items not shipped: the pie highlight-calendar draft conflicted with
  the OP-only relocation and had a malformed test — reverted, needs a focused
  pass; named-local-tasks-from-Review the agent didn't draft.)
- [x] **Reconnect on the URL alone when a key is stored** — the connect button
  required the always-blank key field; now "Connect" reuses the stored key.
- [x] **Settings can no longer be silently wiped (data-safety)** — `JSONFileStore`
  treated any unreadable file as "use empty defaults", and the first settings
  change then atomically OVERWROTE the file with those defaults — so one bad read
  of `settings.json` lost the instance URL, local tasks, colours, etc. (with no
  backup). Now every save mirrors the just-written good file to a `.bak`; `load`
  recovers the latest value from `.bak` if the main file is corrupt and preserves
  the bad file as `.corrupt` (nothing silently lost). Applies to all four stores
  (settings, learning, primed, pins). +2 checks. (The API key was never affected
  — it's a separate file.)
- [x] **Stop NEW OP duplicates at the real source: serialise sync** — duplicates
  were STILL appearing because `syncIfEnabled` had no re-entrancy guard, yet it's
  fired from ~7 places (every slice flush, the 60 s timer, every timeline edit).
  `pushEligible` fetches the unpushed sessions, then `await`s the network
  `createTimeEntry` before `markPushed` — and that await frees the main actor, so
  a second sync (e.g. the 60 s timer firing during a flush-triggered sync) fetched
  the SAME still-unpushed session and POSTed it again = two OP entries. The
  earlier rank-3a fix only covered a `markPushed` throw, not two runs that both
  succeed. `syncIfEnabled` is now non-reentrant (a `syncing` flag), with a
  `syncRequested` re-run so a trigger arriving mid-sync isn't lost. This is the
  root cause of the ongoing duplicate creation.

## 2026-06-27

- [x] **Reconcile robustness + display fixes** (from live testing) — three real
  problems with the duplicate tool:
  - **Safety:** grouping keyed on task+start-minute alone, so on an OP instance
    that doesn't report per-entry start times every entry collapsed to the day's
    midnight and genuinely-separate entries could be grouped as "duplicates".
    Grouping now also keys on duration, and — the real safety rail — the JOURNAL
    decides how many entries are real (slices linked to the group, or matching
    task+minute+duration); only the EXCESS over that count is ever deleted, so
    two real same-day slices are never collapsed. (+2 checks.)
  - **"created ?":** OP timestamps with fractional seconds were rejected by the
    default ISO-8601 parser; `parseStamp` now tolerates them.
  - **"start 0:00":** when OP reports no start time, the entry no longer shows a
    misleading midnight — it reads "no start time" and the group header omits the
    time, leaning on the created timestamp instead (`OPTimeEntry.hasStart`).
- [x] **OpenProject duplicate-entry reconcile (rank 3 complete)** — an in-app
  maintenance action (Settings ▸ Maintenance ▸ "Scan for duplicate OpenProject
  entries"). Reads back your recent OP time entries (`listTimeEntries`), groups
  them against the journal, and for each genuine duplicate proposes a confirm-
  each cleanup following the agreed policy: never two records for one point in
  time; keep the RICHEST entry (most comment, then longest, then lowest id); fold
  the deleted entries' comments into the survivor (`updateTimeEntryComment`, so
  nothing is lost); re-point the journal slices at the survivor; and never touch a
  group with no matching journal slice (could be hand-entered in OP). Pure
  `DuplicateReconcile` core (4 checks) + the OP endpoint (mock-transport check) +
  controller `findDuplicateActions`/`applyReconcile` + the confirm-each UI. This
  is the cleanup half; the double-create that *made* new dupes was closed earlier
  today (rank 3a). Each group expands (chevron, or Expand all) to show every
  entry's id, created time, duration, activity and comment so you can judge
  safety before deleting, with KEEP/delete tags; and an "open in OpenProject"
  per entry (opens its work package) to check anything Ambitick can't read —
  custom fields etc. (`listTimeEntries` now also reads createdAt/updatedAt/
  activity).
- [x] **Backlog batch (drafted by subagents, integrated + verified serially)** —
  five contained optimisation items, each built and checked on the Mac before
  the next; 160 checks pass.
  - **Rank 2 crash-safety:** a task switch now clears-then-rewrites the live
    checkpoint to the new task (a crash mid-switch could otherwise double-recover
    already-flushed time); new pure Core `CheckpointRecovery` rejects a stale row
    that's sub-floor or already covered; dedicated ~12s checkpoint timer gated to
    tracking (tolerance-coalesced). Plus `JournalStore.session(id:)` /
    `sessionCount()` / `pushedCount()` so edit/undo paths and the journal summary
    stop decoding the whole table.
  - **Rank 6 banked menu-clock:** under-counted during heavy flitting; now
    derived from `tracker.liveSliceStart` (= what posts to OP).
  - **Rank 3a OP double-create:** `SyncEngine` was marking pushed after the POST,
    so a failed mark re-POSTed next sync (the ~143-surplus root); the create is
    idempotent now (delete the orphan on a failed mark; surface a malformed id).
  - **Rank 7 test backfill:** SessionTracker live-editing/away, parser aliases,
    PinScope about:blank fallthrough (+9 checks, no hidden bugs surfaced).
  - **Rank 8 dead-code:** removed `WorkspaceLayout.swift` (228 dormant lines) and
    the dormant `taskLayouts`/`lastLayout` settings.
- [x] **Timeline: ⌘A selects all windows** in a slice once you've selected one
  (the span-reassign bar carries the shortcut).
- [x] **Faster Time window + readable "why" panel** — the pie window was slow
  because `SpentView.nodes` was a computed property running a journal query +
  TimeAggregator pass on EVERY body render, and the view re-renders ~1Hz (the
  menu clock), so it re-queried the journal about once a second. Now cached in
  `@State`, refreshed only on appear / the 30s tick / journal mutation / period /
  OP-only toggle. Also made the active-space window config idempotent (it re-ran
  per render). The attribution "why" panel was clipped with no scroll — each
  detail pane now scrolls vertically so the full explanation is reachable.
- [x] **One Time window, two views in place + a second-window escape hatch** —
  the timeline and pie are no longer separate windows that swap; they're one
  "Time" window whose view flips in place when you click a preview. To see both
  at once, ⌃-click / right-click (or the preview's context menu) opens the other
  view in a second window. App.swift now has `time` + `time2` windows hosting a
  `TimeContainer` bound to `controller.timeWindowView` / `timeWindow2View`;
  TimelineView/SpentView take a `TimeNav` (switchTo / openSecond) instead of
  opening/dismissing windows themselves; the window identity tracks the shown
  view so the scroll-pan monitor still recognises the timeline.
- [x] **User manual** — `MANUAL.md` (linked from the README): popover, auto-
  tracking + the "why" panel, pinning, the Time window incl. the combined-view
  navigation and the ⌃/right-click second window, Settings, data/sync, keyboard.
- [x] **Combined Timeline/Pie view — the previews ARE the navigation (#5)** — the
  popover's two separate Timeline/Pie footer icons are now one launcher that
  itself shows a **live mini-pie of today's breakdown**; clicking it opens the
  timeline, the pie, or whichever was viewed last, per a 3-way Setting (Time
  button opens: Timeline / Last viewed / Pie chart). There's no separate switcher
  icon: in the timeline window, clicking the today mini-pie opens the pie; in the
  pie window, clicking a slice in the current-block mini-timeline opens the full
  timeline **framed on and editing that exact slice** (via
  `AppController.pendingTimelineFocus`). The mini-timeline is labelled with the
  first slice's start time. Last-viewed persists across a relaunch. New
  `TimeViewChrome.swift` (`MiniPie` + tappable `MiniTimeline`); controller
  `todaySpentNodes`/`currentBlock`/`timeViewToOpen`/`noteTimeViewOpened`; all
  three surfaces cache the journal query rather than running it per render.
- [x] **Explainable attribution — "why was this tracked as X?" (#1 v1)** — click
  a slice, click a window in its detail strip, and the pane shows why that task
  was chosen: the decision source (pinned / OP-URL / OP-id-in-title / just-opened
  OP task / remembered correction / learned+priors), the ranked candidate tasks
  each with their score split into learned-vs-prior, and the signal features the
  learner keys on. `AttributionExplanation` + `Attributor.explain()` mirror
  `attribute()`'s source order so the explanation can't disagree with reality;
  `scored()` refactored to expose its components. Moving a window to the right
  task already teaches the learner, so that's the weight-edit loop — the panel
  points you to it and shows the scores. Controller `explainSpan`/`teachSurface`.
- [x] **Deep-review optimisation passes (ranks 1, 4, 5)** —
  - **Rank 1:** `liveStartConflicts` (warning) and `adjustLiveStart` (trim) now
    derive from one `liveEditContext(from:to:)` window, so the overlap warning
    equals what's actually trimmed even across midnight (they previously used
    independent calendar-day windows that could desync).
  - **Rank 4:** a slice deliberately started that ran 61–120s under a Switch
    Buffer set >60s was silently dropped at flush — floored at `min(buffer,60)`
    now (it's work, Martin's call; default 30s unchanged). `PinOp.startsWith` is
    case-insensitive like `equals`/`contains`. `matchingPin` only compares
    specificity within a rule kind (prefix.count vs leafCount aren't
    commensurable), else falls through to recency. `.regex` documented as
    unanchored. +3 regression checks.
  - **Rank 5:** the timeline scroll-pan monitor gates on the window identifier
    (set via `openOnActiveSpace(id:)`) not a localisable title substring, and is
    idempotent (no stacked global monitor → no app-wide double-pan).
- [x] **Renamed `KeychainStore` → `APIKeyStore`** — it has stored the OP API key
  in a plain 0600 file, not the Keychain, since 2026-06-24; the name was
  misleading.
- [x] **Popover tidy (#2/#3/#4)** — removed the pencil/double-arrow mode icons
  (the running-task title flips Change-to ⇄ Switch-to; the default is now a
  Setting, `popoverDefaultsToChangeMode`, defaulting to Change-to); dropped the
  separate unpin-✕ on the pin badge (the chip reopens the editor, whose ✕
  unpins); dropped the task name duplicated under the headline (popover shows
  `elapsedText`, time only).

## 2026-06-26

- [x] **Optimisation programme — passes 1–3** (Programme Manager + per-domain
  Project Managers analysed Ambitick; deep-review pending a credit reset). Done:
  - **perf:** added the missing `sessions(start)` index; `sessions(from:to:)`
    now bounds both sides in SQL via a new `end` column (was: decode every row
    before `to`, filter in Swift); hoisted per-push `ISO8601DateFormatter`;
    de-duplicated the triplicated dominant-span idiom into `dominantSpan(of:)`.
  - **fix (cross-midnight #8 follow-up):** `coalesceAdjacent`, `commitLiveSlice`
    and `lastTrackedTask` still bucketed by calendar day, so same-task slices
    straddling midnight didn't merge, a pre-midnight live slice wasn't found on
    commit, and the post-midnight resume candidate was empty. Now window-around-
    the-edit / live-slice-start / 36h-lookback respectively.
  - **perf:** `TimelineView` cached its journal fetch (`@State` + a
    `journalRevision` mutation signal) instead of running a SQLite query + JSON
    decode on every `sessions` access — it was re-querying inside gesture
    `.onChanged` closures and on every mouse-move.
  - Remaining backlog captured in TODO.md (gesture robustness, menu/banked-clock,
    attribution deep pass, crash-safety, OP write path, test extraction, dead
    code, backend seam).
- [x] **Removed the redundant "Recent/Likely tasks in popover" counts (#4)** —
  the popover now shows the whole task list (recency-first, then ranked,
  scrollable + filterable), so a fixed recent/likely cap was meaningless. Dropped
  both Settings, the `AmbitickSettings` fields, and `TaskRanker.pickList`'s
  count parameters; the ordering is now `TaskRanker.recentThenRanked` (recently-
  confirmed first, then everything ranked, no caps). Old settings JSON with the
  keys still decodes (the keys are just ignored).
- [x] **Pin parse errors are now legible** — the earlier tap-to-expand showed
  the error inside the cramped button row, overlapping the icons. The error now
  has its own full-width wrapping line above the buttons (selectable). `PopoverView`.
- [x] **Window-name pins survive title volatility (#2 follow-up)** — a Ghostty
  window pinned by name ("electroPioreactor" → AEP-design) tracked as the wrong
  task because `PinScope.matches()` was a strict POSITIONAL prefix match, and a
  terminal prepends its mode to the title ("nvim — electroPioreactor"), sliding
  the name out of position 1 so the pin silently stopped matching and a broader
  Ghostty attribution won. App pins now match on PRESENCE: the app must match
  and every pinned title segment must appear somewhere in the title (any order).
  URL pins keep positional prefix (host/path is stable). `PinScope`. (Two
  subagents investigated; one proposed "the pin-precedence comparator is
  inverted" — verified false, `max(by:)` with `<` correctly picks highest
  specificity, and the specificity test passes; the real cause was matching, not
  selection.)
- [x] **Pin badge shows the most distinctive clause (#11)** — an Expression
  pin's badge showed the FIRST clause; it now shows the leaf with the longest
  value (the bit that actually identifies the pin). `Predicate.shortLabel`.
- [x] **Expression negation: `is not` / `does not contain` (#11)** — the parser
  now accepts natural negations (`app is not "Ghostty"`, `url does not contain
  "github"`, `title doesn't match "…"`), so the user's example parses.
  `PredicateParser` (+ checks).
- [x] **Pin parse errors are viewable in full (#11)** — a long parse error was
  truncated to one line; tap it to expand (and it's in the hover tooltip too).
  `PopoverView`.
- [x] **Popover filter is focused on open** — the "type to search all N tasks"
  hint promised typing would work, but the filter field had no focus so nothing
  happened. It's now focused when the popover opens (and the hint only shows
  while the filter has focus). `PopoverView`.

## 2026-06-25

- [x] **Pin editor hamburger: Components + Expression (#11)** — the boolean
  engine existed but only the visual Components editor was wired up. The pin
  editor now has a hamburger (between Pin and Cancel) switching Components ↔ a
  typed Expression editor. New `PredicateParser` (Core, 7 checks) parses the
  agreed syntax — `app/title/url` · `is/contains/starts with/matches` ·
  `and/or/not/( )`, bare text = contains-any-field — into the same `Predicate`
  the engine evaluates, and renders it back (so re-opening an Expression pin
  shows editable text). Switching into Expression seeds the box from the current
  Components selection. Parse errors show inline and keep the editor open. AI
  paste-back mode is the remaining phase. `AppController.commitPin(rule:)`,
  `PopoverView`.
- [x] **Continuous cross-midnight timeline (#8)** — the viewport was hard-
  bucketed per calendar day (clamped midnight..midnight, `dayOffset` stepper),
  so a work block spanning midnight couldn't be seen whole and you couldn't pan
  across the boundary. The timeline is now one continuous absolute-time window
  that pans/zooms freely across midnight; the only bounds are a 90-day history
  floor and the live edge (now). Sessions fetch by visible range
  (`timelineSessions(from:to:)`, replacing the per-day variant); grid ticks
  anchor to local midnight and show the date + a darker line at each day
  boundary; the header shows the visible date (or a cross-midnight range), ‹ ›
  pan by a day, Today jumps to midnight..now, Block to the latest run.
  `TimelineView` + `AppController`.
- [x] **Sub-minute excursions no longer journal a "0:00" slice** — a ~31 s dip
  into another window (longer than the 30 s Switch Buffer, under a displayed
  minute) committed as its own slice and showed `0:00`. A WORK switch now only
  commits once held a full minute (`sliceFloor = max(switchGraceSeconds, 60)`);
  briefer excursions fold back into the surrounding task, exactly as a
  sub-grace flit already did. Display still follows instantly; only the journal
  commit waits. Non-work auto-stop and the flush floor keep the user-set buffer
  (so a genuinely-short first/last slice survives). `SessionTracker`.
- [x] **Recency survives a restart** — `lastConfirmedAt` lived only in the
  in-memory cache, so a heavily-tracked task silently dropped out of the recent
  pick-list after a relaunch (the "where did Client Work go the morning after?"
  symptom). Recency is now re-derived from the journal at startup and on every
  OP refresh, taking the later of journal and in-memory. `AppController`.
- [x] **App pins default to app + window, not app-only** — most people run
  several windows of one app on different tasks (e.g. named Ghostty windows), so
  the useful default scope is the window, not the whole app. Titleless apps
  still default to app-only. Widen with ←. `PinScope.defaultPrefixCount`.
- [x] **Popover task list is fully scrollable** — the default list was hard-
  bounded to the recent+likely picks, so a task outside them was unreachable
  without typing a filter. It now shows the full ranked set (recent+likely
  first), scrollable. With the recency fix above, the wanted task rises to the
  top. `PopoverView`.
- [x] **Timeline zoom homes on the cursor** — ± buttons and pinch keep the time
  under the pointer fixed instead of fixing the viewport centre. `TimelineView`.
- [x] **Overlap resolution: whole-windows vs exact time** — editing a slice end
  over a neighbour now offers two resolutions: Snap to windows (↵, default)
  moves the boundary to the nearest tracked-window edge so a straddling window
  lands wholly on one task (no duplicate-under-both-slices, no 1-min overlap);
  Exact time (space) keeps the time typed. `TimelineView` + `windowBoundaries`.
- [x] **Keyboard: delete/backspace removes selected slice(s)** — and a Delete
  button on the multi-select reassign bar. First step of the keyboard/mouse
  parity sweep (see TODO). `TimelineView`.
- [x] **Pin editor ✕ now unpins** (instead of a redundant exit-without-saving) —
  Enter is the only way to keep a pin; the ✕ (and esc) mean "no pin here", so
  they unpin an existing pin (same as the badge ✕) or drop a never-committed
  draft. `PopoverView`.
- [x] **Editor field focus no longer stolen mid-edit** — the 30 s refresh tick
  rebuilt the editor subtree and dropped focus from the h:mm field you'd just
  clicked (the intermittent "it didn't go blue" bug). The tick now pauses while
  the editor is open. `TimelineView`.

## 2026-06-24

- [x] **OP API key moved out of the Keychain to a 0600 file (stop the
  login-password prompt on every launch)** — a self-signed / no-Apple-team app
  cannot read its own login-keychain item without macOS challenging for the
  login password at every launch, and "Always Allow" never persists because the
  system won't trust an unanchored signature across rebuilds (the data-protection
  keychain that avoids the prompt needs an entitlement a teamless app can't
  get). `make-app.sh` now relaunches the app, so this fired on every build. The
  key now lives in an owner-only file in the app support folder beside the
  journal/settings (already plaintext there — same on-disk posture). Requires
  re-entering the OP API key once in Settings; the old keychain item is left
  orphaned and harmless. (`KeychainStore` kept as the type name for call-site
  stability; it is no longer a keychain.)
- [x] **Pins no longer instant-commit on every flit (the real flit-gap cause)** —
  debug-trace evidence: pinned windows attribute at score 1.0, which hit the
  `>= 0.96` "deliberate, commit at once" path and bypassed the grace window. So
  flitting THROUGH a pinned window (the user pins several Ghostty windows to
  different tasks) instant-committed a switch each time, fragmenting the base
  task into pieces with floored gaps between — and pushed 2-second slices to OP.
  That `>= 0.96` path existed for OP work-package URLs at 0.99, but those are now
  capped at 0.95, so nothing legitimate needs it. Removed it: every
  attribution-driven switch now respects the Switch Buffer (display still
  follows instantly; only the commit waits), so flitting through pinned windows
  folds back into the base task and the timeline stays continuous. Manual picks
  (confirm/start) are unaffected. KNOWN FOLLOW-UP: the menu-bar clock uses a
  separate per-task accumulator that still credits brief excursions to the
  excursion's task, so it can under-count during heavy flitting even though the
  journal/timeline is now correct — to be fixed next. (+ test; 122 total pass.)
- [x] **Flitting through a non-work tab no longer auto-stops the clock** — the
  pending-switch handler skipped `doNotTrack`, so a pending non-work stop was
  never cancelled when you returned to work: flit to a non-work tab, come back
  within grace, and ~30 s later the clock auto-stopped anyway. That "pause"
  couldn't be reclaimed because click-to-fill only fills *between* slices and a
  stop leaves open-ended trailing time. Now a pending non-work stop is cancelled
  the instant a real task is back in focus. (+ test; 122 total pass.)
- [x] **Hard floor on slice length, tied to the user's Switch Buffer** —
  emitted sessions had no minimum length (the `minSegmentSeconds` check only
  ever gated the review queue), so brief slices could still land (e.g. a pin
  instant-commit that bypasses the switch grace). `flushSessions` now drops any
  run shorter than `switchGraceSeconds` — the same "Switch buffer" knob in
  Settings, since it's the same idea (minimum time on a task for it to count),
  so it's user-settable with no new control. The grace fix stops most flits
  upstream; this floor guarantees the "pile of ~0-minute slices" can't appear
  regardless of path. NOTE: forward-looking only — slices journalled before this
  build stay until deleted in the timeline. (+ test; 121 total pass.)
- [x] **Settings/other windows open on the current Space** — opening a window
  (e.g. the gear) yanked you to whichever Desktop it was last on; they now use
  `.moveToActiveSpace` so the window comes to you instead.
- [x] **Settings text fields are visibly editable** — added rounded borders to
  the Instance URL / API key / colour fields (they were borderless and low
  contrast). Missing-API-key error now points at the Settings gear rather than
  a non-existent "below" field; "Saved to Keychain" → "Saved".
- [x] **Rapid window-flitting no longer logs a pile of sub-minute slices** —
  root cause in `SessionTracker.handleFocus`: when a switch A→B was pending
  (provisional through the grace window) and a third window C appeared, the code
  committed B regardless of how briefly it had been focused ("a newer task
  arrived, so B must have been real"). So flitting A→B→C→D committed each
  transient window as its own sub-minute slice, attributed to whatever the
  ranker guessed (the "a university course / Project B / Timesheets at 15:09" mess); and
  when one flit was an uncertain/doNotTrack window it auto-stopped, so the real
  work window that followed couldn't resume and logged as "nothing". Fix: a
  pending excursion that hasn't matured past grace is never committed — when a
  third task arrives it folds back into the base task and the new target pends
  from that same base. Only a window actually held past the grace window
  commits. `minSegmentSeconds` only ever gated the review queue, never sessions
  — the grace bug, not a missing floor, was producing the tiny slices. New
  SessionTracker check reproducing the flit (120 total pass).

- [x] **Pin rule engine (phase 1 of richer pins)** — generalised pins from a
  fixed component-prefix to a predicate so they can match windows that the
  URL/title-prefix model can't. A `Pin` now carries a `PinRule` that is either
  `.components(PinScope)` (the existing blue/grey editor) or `.expression(Predicate)`
  — a boolean tree of `field op value` leaves where field ∈ {app, title, url},
  op ∈ {equals, contains, startsWith, regex}, combined with AND/OR/NOT. This
  folds "contains" and "regex" into operators (no separate rule types — less
  code, the anti-bloat path), and is the shape the upcoming AI mode emits.
  Precedence when several pins match: manual `priority` (Advanced, hook present,
  UI TODO) → leaf-count specificity → most-recently-added. Attributor pins moved
  from a `[PinScope: TaskRef]` dict to an ordered `[Pin]`; legacy `pins.json`
  auto-migrates to `.components` rules on load. New `Predicate`/`PinRule`/`Pin`
  types + 5 Predicate checks + reworked Attributor checks (119 total pass).
  NOTE confirmed in design: the app sees only app name, window title, and (for
  browsers) tab URL — never window contents. Deferred to TODO: visual/webpage
  boolean builder, the typed-expression + Contains editors and hamburger
  mode-switch, AI mode (+ "fix this pin" follow-up), opt-in "look inside" apps
  (AX window-content as a 4th field), and the priority-override UI.
- [x] **Pin live-refresh** — committing a pin now re-evaluates the running
  session immediately (`SessionTracker.reevaluate()`), so the chip/100% appears
  at once instead of only on the next focus change.

## 2026-06-23

- [x] **Explicit pins + a clean certainty contract (the general fix for "it
  refuses to learn")** — root cause was architectural: attribution blended a
  naive-Bayes model with a volatile recency/status ranker prior, and surfaces
  with no durable anchor (My Page, dashboards) rode that prior to whatever
  project was hottest — the "apparently random project" Martin saw. Corrections
  to non-OP windows also drifted because a soft prime keys on the exact surface
  and for native windows that's `app + window title`, which churns (filename,
  cwd). New model, two tiers: **(1)** everything inferred — work-package URL,
  learned model, soft primes from ordinary corrections — now caps at **0.95**;
  **(2)** an explicit user **pin** is the only thing that returns **1.0**, and
  it overrides the ranker, learning, soft primes *and even a work-package URL*.
  A pin (`PinScope`) keys on a chosen **scope** — a broad→narrow prefix of the
  surface identity — so one pin covers a whole site, a section, a single page,
  a whole app, or one window. Most-specific (longest-prefix) pin wins. Pins
  persist to `pins.json`. The popover gets an inline **pin editor**: the
  captured identifier shows with the pinned prefix in blue and the rest grey,
  **← widens / → narrows** by `/`-level (URL) or title segment (app), the smart
  default is host+first-segment (URL) or app-only (native), **↵ pins / esc
  cancels**; a 📌 badge with ✕ shows/clears the active pin. The certainty number
  now means something honest: 100% ⟺ you told me outright, ≤95% ⟺ inferred.
  New `PinScope` type + 7 unit checks + 6 reworked Attributor checks
  (111 total pass). Supersedes the OP-only auto-pin from earlier the same day.
- [x] **Live-tracking & attribution fixes (Martin's in-app testing round)** —
  the live slice now renders as a continuation of its merged same-task block
  instead of a detached fragment; "Change to <task>" now *durably teaches* the
  attributor (it was a soft prime the learned model overrode, so windows
  snapped back to their old task on return); "revert" offers the task you
  actually just left (in-memory previous-task, not the journal's stray
  most-recent-by-start slice); the AI-assist parser skips unrecognised segment
  ids instead of rejecting the whole batch on the first bad one; the timeline
  viewport no longer drifts past the live edge into empty future time; and
  popover/settings text is selectable so it can be copied out instead of
  screenshotted. Workspace layouts cut (geometry-only, unreliable — see TODO).
- [x] **Stable code-signing fixed in `make-app.sh`** — it had been silently
  falling back to ad-hoc on every build, so the Accessibility/TCC grant was
  lost on each rebuild. Pinned cert creation to `/usr/bin/openssl` (Homebrew
  OpenSSL 3 writes a `.p12` that `security import` rejects) and dropped the
  `-v` filter from the identity lookup (it hides untrusted self-signed certs,
  which codesign signs with fine). Now prints `Signed with stable identity …`;
  grants persist across rebuilds.

## 2026-06-22

- [x] **Slices auto-merge; manual Stop→Start is the only discrete boundary** —
  `coalesceAdjacent` now runs at the flush sink (`onSession`) and after the
  idle-gap claim, so "continue when you were away", "revert to last task" and
  every other live-created slice fold into the adjacent same-task slice — one
  slice, one OP entry — instead of fragmenting. Adjacency uses the existing 2s
  tolerance, so a real untracked gap (a manual Stop then Start) stays two
  slices: the sole intentional break, e.g. for different comments.
- [x] **OP duplicate-on-merge fixed (was latent on the drag path too)** — a
  merged survivor kept the earlier slice's `opTimeEntryID` but was flagged for
  re-push, and `pushEligible` only ever *creates*, so each merge would spawn a
  second time entry. `coalesceAdjacent` now PATCHes the survivor's existing OP
  entry in place and marks it handled; auto-merge also skips the live
  crash-checkpoint row.
- [x] **Comment toggles: 'to tracked time' and 'to task'** — two independent
  settings (both default on). 'To tracked time' keeps the note on the time
  entry; 'to task' also posts it to the task's OP activity feed (new
  `OPClient.addWorkPackageComment`), where it is findable. Both off hides the
  note field. Routing is a pure, unit-checked `CommentRouting` helper. 98
  checks green; full SwiftUI build clean.

## 2026-06-12

- [x] **Timeline, Time Spent, local tasks (the `timeline` branch)** - Full
  interactive timeline (viewport bar, block-framing, draw/gap-fill/edge-drag
  editing with snapping and neighbour-trim, OP write-back via stored entry
  ids, window-detail strip with connectors, live-slice start edit), Time
  Spent donut (project>task>app hover rings, pin, legend), local non-OP task
  system with Settings UI and leisure routing, per-task colours, span
  recording with 30-day retention, crash traps to the debug log, self-drawn
  notification banners, per-task banked clocks with flash-visit limbo.
  81 checks + live-OP integration green throughout.

## 2026-06-11

- [x] **Ambitick v0.1 pre-alpha (overnight build)** — Full first implementation
  from the approved spec, e6a62dd..HEAD. `AmbitickCore`: domain models, OP URL
  parsing, naive-Bayes learning store, status/recency/time-of-day ranking,
  attribution with OP task-priming and OP-host fallback, dominant-minute
  session resolution, journal protocol, OpenProject v3 client (1-based page
  pagination), threshold-gated sync, copy-paste AI assist, settings.
  `AmbitickMac`: raw-sqlite3 journal (passes the same conformance suite),
  Keychain key storage, sensors (frontmost app, AX window titles, Chrome/Opera/
  Brave tab URLs via Apple Events, idle, sleep/wake, mic-in-use), app
  controller with 1 Hz→per-minute menu cadence. `AmbitickApp`: SwiftUI
  MenuBarExtra popover, review window (multi-select assign), settings UI.
  `scripts/make-app.sh` wraps it as ad-hoc-signed `Ambitick.app` (LSUIElement).
  56 checks green via `swift run AmbitickCoreChecks` — a plain-executable
  harness because the build Mac has CLT only (no XCTest/Swift Testing).
  Verified on Mac over scoped SSH (`ambitick` standard user). UI smoke testing
  deliberately deferred to Martin (README checklist): no GUI session available
  to the build user.

## 2026-06-11 (day-2 fixes)

- [x] **Live-fire fixes + real-OP integration runner** — switch-grace buffer
  (brief window excursions merge; commits via input ticks), per-task clock,
  s/m/h+m menu format, persistent primed associations, weighted session
  certainty, optional activity, ISO-8601 startTime (verified stored by OP),
  stable signing identity (TCC grants survive rebuilds), legacy notification
  API (process-abort fix), auto-resume after idle, loud connection/push
  diagnostics, popover/review type-to-filter, AmbitickIntegration headless
  end-to-end against live OP as the Claude test account. 69 unit checks +
  INTEGRATION PASS.
