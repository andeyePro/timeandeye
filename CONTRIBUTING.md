# Contributing to andeye

Thanks for looking under the hood. This repo is the open-core home of the
andeye time tracker: everything here builds a fully functional app
(OpenProject backend + standalone included); paid backends live in a separate
private package and never gate anything you find here.

New here? [CLAUDE.md](CLAUDE.md) is the orientation map – agents and humans
both start there. It has the module layout, the build/check commands, and
the handful of "do not clean this up" rules that will bite you otherwise.

## Build and test

```bash
git clone https://github.com/andeyePro/timeandeye.git
cd timeandeye
swift run timeandeyeChecks   # the whole test suite — expect: TOTAL: N passed, 0 failed
./scripts/make-app.sh          # build + install timeandeye.app (macOS 14+, CLT only)
```

The checks are a plain executable (no XCTest) and every PR must keep them
green — CI runs them on every push.

## What makes a good PR here

- Tests first-class: behaviour changes come with checks in the same commit
  (see any `*Checks.swift` for the house style — tiny assertion vocabulary,
  real scenarios, comments explaining WHY the case matters).
- The journal's JSON wire format is FROZEN (see the wire-format checks in
  ModelsChecks). Anything that would change how existing rows decode needs a
  migration story, not a format change.
- The attribution learner must never train on backend-API-sourced text
  (Xero API terms; frozen by a check). Features come from the sensor signal
  only.
- `TaskBackend` is the seam new backends implement — `OPBackend` is the
  reference conformer.

## Licence and contributor agreement

andeye is licensed under the GNU AGPL-3.0 (see LICENSE). We chose the AGPL
deliberately: it keeps this codebase and everything built on it open, for
good.

But the AGPL and Apple's App Store are incompatible – Apple's terms and the
AGPL's source-distribution requirements can't both be satisfied, which is
why projects like VLC had to be pulled from the store, and why an AGPL app
can't simply be published there. So for andeye to exist both as a genuinely
copyleft community app here AND as an iPhone / App Store app (and the paid
andeyePro build), one party needs to hold rights broad enough to ship under
both sets of terms. That party is andeye Ltd, and the CLA is how it gets
those rights without you giving up yours.

Contributions are therefore accepted under the andeye Individual
Contributor Licence Agreement ([CLA.md](CLA.md)): you keep ownership of your
work, it stays under the AGPL here forever, and you additionally grant
andeye Ltd a licence broad enough to distribute it under the proprietary
build terms too. It's a three-minute read with a plain-English summary at
the top. To sign, state your agreement in your first pull request and add
your name to [CONTRIBUTORS.md](CONTRIBUTORS.md); PRs from authors who have
not agreed cannot be merged.
