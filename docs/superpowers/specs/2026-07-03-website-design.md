# andeye.com website design

Status: **DESIGN AGREED, scaffold this commit, landing page pending
treatment pick.**

Decisions agreed with Martin 2026-07-03.

## Approach

Approach (c) from the options discussed: a marketing **one-pager**, not a
multi-section marketing site. Its hero is an **interactive simulated
menu-bar demo** – a live, clickable recreation of the andeye popover running
in the page, not a screen-recording or a static screenshot. It reuses the
real `AndeyeLogo` geometry (the same vector/shape code the Mac app draws
with) rather than a re-drawn asset, so the mark on the site is provably the
same mark as the app icon, not a design team's reinterpretation.

Below the hero: a **dual call to action** – a GitHub repo link (the project
is open source; this is the primary CTA for anyone technical enough to land
here early) and a waitlist email capture (for everyone else, ahead of a
packaged release).

Three competing landing-page treatments are being produced in parallel
(not by this scaffold – that work is separate and comes after). Whichever
wins gets productionised into `src/pages/index.astro`, replacing the
placeholder this commit ships.

## Site location

The site lives **in-repo at `site/`** in `andeyeTT`, not in a separate
repo. It stays there until a second andeye product exists that needs to
share the `andeye.com` brand domain across products – at that point it's
worth externalising into its own repo so neither product's release cadence
blocks the other's site deploys. Until then, one repo, one deploy pipeline,
less to keep in sync.

## Hosting

**Cloudflare Pages**, static output, no SSR adapter. Framework preset
`Astro`, root directory `site`, build command `npm run build`, output
directory `dist`. See `site/README.md` for the exact dashboard fields.

## Manual

The user manual is **Starlight**, mounted at `/manual`, sourced from
markdown living in this repo (`site/src/content/docs/manual/`), seeded by
splitting `MANUAL.md` into per-topic pages along its real section
structure. The manual explicitly states it documents the **community
macOS app** (not a hypothetical future iOS/other-platform doc set).

Docs content routes to `/manual/*` by living under a `manual/` subfolder in
the Starlight content collection – no Astro-level `base` config is used
(that would prefix the whole site, including the landing page, which must
stay at `/`). This means the docs collection has no page at bare `/`; the
custom `src/pages/index.astro` owns that route outright.

## What this scaffold commit does and doesn't do

Does: stands up the Astro + Starlight project, builds green, ships the
manual content, and drops a deliberately undesigned placeholder at `/` so
the site is deployable today.

Doesn't: touch the landing page design – that's the three-treatments
process, still to come. `src/pages/index.astro` is intentionally trivial
so it's a clean one-file swap when a treatment wins.
