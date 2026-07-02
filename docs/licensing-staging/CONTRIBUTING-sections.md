# CONTRIBUTING.md licence section — one variant per option

Append EXACTLY ONE of these to CONTRIBUTING.md in the LICENSE commit, then
delete this file with the rest of docs/licensing-staging/.

## Variant A — GPL-3.0 (also fits AGPL-3.0: swap the licence name)

```
## Licence and contributions

andeye is licensed under the GNU GPL-3.0 (see LICENSE). andeye Ltd also
ships the same code in proprietary builds (for example the App Store
releases), which is possible because the company holds sufficient rights
in every line.

To keep that true, contributions are accepted under the andeye Individual
Contributor Licence Agreement (CLA.md): you keep ownership of your work
and grant andeye Ltd a licence broad enough to distribute it under both
the GPL and the proprietary build terms. State your agreement in your
first pull request (the PR template includes the line); PRs from authors
who have not agreed cannot be merged.
```

## Variant B — Apache-2.0

```
## Licence and contributions

andeye is licensed under the Apache License 2.0 (see LICENSE).
Contributions are accepted under the Developer Certificate of Origin
(developercertificate.org): sign each commit off with
git commit -s, certifying you have the right to submit the work under
the project licence. No CLA is required.
```

Note for the landing: variant A pairs with adding CLA.md at the repo root
and (before going public) a CLA-assistant or PR-template check; variant B
pairs with the DCO GitHub check and no CLA.md.
