# Contributing to andeye

Thanks for looking under the hood. This repo is the open-core home of the
andeye time tracker: everything here builds a fully functional app
(OpenProject backend + standalone included); paid backends live in a separate
private package and never gate anything you find here.

## Build and test

```bash
git clone https://github.com/andeyePro/andeye.git
cd andeye
swift run AndeyeTTChecks   # the whole test suite — expect: TOTAL: N passed, 0 failed
./scripts/make-app.sh          # build + install andeye.app (macOS 14+, CLT only)
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

andeye is licensed under the GNU AGPL-3.0 (see LICENSE). andeye Ltd also
ships the same code in proprietary builds (for example the App Store
releases), which is possible because the company holds sufficient rights
in every line.

To keep that true, contributions are accepted under the andeye Individual
Contributor Licence Agreement (CLA.md): you keep ownership of your work
and grant andeye Ltd a licence broad enough to distribute it under both
the AGPL and the proprietary build terms. State your agreement in your
first pull request; PRs from authors who have not agreed cannot be
merged.
