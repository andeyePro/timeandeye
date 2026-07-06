# CLAUDE.md

Agents and humans both start here. Read `README.md`, `TODO.md`,
`CHANGELOG.md`, `Package.swift` and `scripts/make-app.sh` before touching
anything – this file is a map, not a substitute for those.

## What this is

andeye: a macOS menu-bar app that automatically time-tracks against a
project-management backend (OpenProject fully supported, Xero next,
standalone/no-backend works today too). It watches the active window/app/
browser tab, attributes time to the most likely task, and learns from
corrections. Local-first: a SQLite journal on the Mac is the source of
truth. An iOS companion (`ios/`) shares the same Core. This repo is the
open-core **community** build (AGPL-3.0, see LICENSE); the paid **andeyePro**
flavour lives in a separate private repo and depends on this package.

## Module map

SwiftPM targets, all lowercase (`andeyeTT*`, `andeyeApp`) – Swift **type**
names stay UpperCamelCase (`AndeyeLogo`, `AndeyeApp` the App struct, etc).
Never write `andeyeTTPro`: the paid product is `andeyePro`, a separate
package, not a module in this one.

- `andeyeTTCore` – platform-independent engine: attribution, the
  `TaskBackend` seam, sync, learning, settings. No AppKit/UIKit.
- `andeyeTTStore` – platform-neutral persistence/sync transport (SQLite
  replica, CloudKit pipe, key store). Both macOS and iOS build on this.
- `andeyeTTPhone` – the iOS app's engine (manual tracking, pick list,
  export). UI-framework-free so the CLT-only Mac loop can check it too.
- `andeyeTTMac` – macOS-only: sensors (NSWorkspace, Accessibility, Apple
  Events, idle/sleep), Keychain, app controller.
- `andeyeTTUI` – the SwiftUI layer as a library; Community and Pro
  executables are both thin wrappers over it.
- `andeyeApp` – the Community menu-bar executable, wrapped into
  `andeye.app` by `scripts/make-app.sh`.
- `andeyeTTChecks` / `andeyeTTIntegration` – the test suites (see below).

## Build, check, run

```bash
rm -rf .build                  # required after any module rename/pull (case-insensitive fs caches by dir name)
swift run andeyeTTChecks       # the whole suite – expect: TOTAL: N passed, 0 failed
./scripts/make-app.sh          # build + install andeye.app (macOS 14+, CLT only)
cd ios && xcodegen             # regenerate andeye.xcodeproj after project.yml changes
```

No XCTest anywhere – the build Mac has Command Line Tools only, so
`andeyeTTChecks` is a plain executable that IS the test suite (tiny
assertion vocabulary, real scenarios, comments explaining WHY a case
matters). `andeyeTTIntegration` runs headless end-to-end against a real
OpenProject instance. This container has no macOS, so checks must be run
on a Mac – don't claim a check result you haven't actually seen.

## Hard rules – do not "clean up" these

- The dev signing identity lives in the `andeyett-dev` keychain
  (`make-app.sh`). Its stability is what preserves TCC grants
  (Accessibility/Automation permissions survive rebuilds only if the
  signing identity doesn't change), so don't re-mint a cert or create a
  fresh keychain casually.

## TODO.md / CHANGELOG.md

`TODO.md` is the open backlog: `[ ]` open, `[x]` done-inline-with-note,
`[!]` abandoned with a one-line failure reason (kept, not deleted – it
stops the next person re-attempting a dead end). `CHANGELOG.md` is the
done-work audit log, newest date heading first, `[x] **title** –
narrative`. Both commit in the SAME commit as the code they describe.

## Elsewhere in the repo

- `site/` – the Astro + Starlight product website (Cloudflare Pages); the
  user manual is published there at `/manual`. `site/src/content/docs/manual/`
  is the hand-maintained source for those pages – it was seeded by splitting
  root `MANUAL.md` once, but the two have since diverged and there is no
  generator; edit the page under `site/` directly, and register new pages in
  `site/astro.config.mjs`'s `sidebar`. `MANUAL.md` at the repo root is a
  separate, README-linked doc for the same audience – keep both current when
  you touch user-facing behaviour, but they are not kept in sync mechanically.
- `docs/superpowers/specs/` – dated design specs; read the relevant one
  before a non-trivial feature change.
- Licence/contributor terms: see `LICENSE`, `CLA.md`, `CONTRIBUTING.md`.

## Manual standing rules

The manual (both `site/src/content/docs/manual/` and root `MANUAL.md`) must
keep up with the app, but never at the cost of user-friendliness –
comprehensive but concise and clear beats exhaustive. Write for the fresh
reader: it never explains why something changed from X to Y, never
apologises for a past version, and never carries failure-mode history – that
context belongs in commit messages, not user-facing docs. Illustrations are
code-drawn (SVG/canvas), never screenshots, so UI polish doesn't invalidate
them.
