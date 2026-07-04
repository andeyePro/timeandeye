# Manual image strategy

Status: **AGREED convention.** How illustrations get into the Starlight
manual at `/manual` with the least maintenance.

## The principle: prefer code-drawn illustrations over screenshots

A screenshot is a photograph of a moving target - the moment the UI shifts it
lies, and nobody notices until a user does. The manual should lean on
illustrations that are *drawn from the same source the app is drawn from*, so
they can't drift:

- The brand mark is already `assets/brand/andeye.svg`, and the landing page's
  demo already renders the menu bar, the timeline bar and the time pie
  authentically in the browser from the real `AndeyeLogo` geometry and the
  real timeline/pie maths. That same technique - small, self-contained SVG or
  inline-canvas snippets - is how the manual should illustrate those surfaces.
  They regenerate from code, track the app's real visual language, and an
  agent can author them with no Mac in the loop.
- Diagrams that explain a concept rather than show a pixel-exact UI - the
  red→green certainty gradient, the broad→narrow pin-grain ladder, the
  attribution order (pin ▸ sticky ▸ OP-URL ▸ email rule ▸ prime ▸ ranker) -
  are SVG, tiny, diffable, and never need re-shooting.

Reach for a real screenshot only when a code drawing genuinely can't carry
the point (a full window's layout, a real macOS control). Keep those few.

## No manifest, no ceremony

An earlier draft proposed a screenshot manifest and a per-PR re-shoot rule.
That is overkill for a solo pre-alpha and it is exactly the kind of process
that rots. Drop it. Instead:

- Illustrations are code, so "keeping them current" is just normal code
  review - they change when the thing they draw changes, in the same edit.
- For the handful of real screenshots, re-shoot opportunistically when you
  happen to notice one is stale. A slightly dated screenshot next to correct
  prose is a small sin; a maintenance ritual nobody keeps up is a bigger one.
- Pages read fine text-first. Ship the words; add pictures where they earn
  their place, never as a gate.

## Mechanics (when an image is warranted)

- **Code drawings** (preferred): inline SVG in the `.md`/`.mdx`, or a small
  Astro component under `site/src/components/` reused across pages. No asset
  files to keep in sync.
- **Real screenshots** (rare): PNG in `site/src/assets/manual/<page>/`, so
  Astro optimises and serves modern formats; reference with a relative
  `![alt](...)`. Retina 2x capture, cropped tight, no real client/task data
  (reuse the demo cast - Maren, Priya, an accounts task, a kitten break).
- **Alt text** always, describing what it shows and means, not "screenshot".

## First pass

Do the code-drawn ones now, no Mac needed: the certainty gradient strip, the
pin-grain ladder, the attribution-order flow, and a menu-bar / timeline / pie
mock lifted from the landing demo. Real screenshots stay a "later, if a page
needs one" item, not a launch blocker.
