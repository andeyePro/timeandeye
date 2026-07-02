# Licence landing kit (staging — delete this directory after landing)

Pre-staged so the moment Martin answers GPL / AGPL / Apache, the LICENSE +
CONTRIBUTING commit lands in minutes. Nothing in here is active licensing:
the repo has NO licence until a LICENSE file sits at the repo root.

## To land (single commit)

1. Copy the chosen text to the repo root as `LICENSE` (exact, unmodified).
2. Append the matching section from `CONTRIBUTING-sections.md` to
   `CONTRIBUTING.md`.
3. GPL/AGPL only: add `CLA.md` (Martin reviews the draft first — it is a
   template, not legal advice) and wire the CLA-assistant check before the
   repo goes public.
4. Delete `docs/licensing-staging/`.
5. Commit all of it together; the repo flips public only AFTER this commit
   (the publish click-list is on OP WP 223).

## Files

- `LICENSE.gpl-3.0.txt` — GPL-3.0-only, verbatim SPDX text.
- `LICENSE.agpl-3.0.txt` — AGPL-3.0-only, verbatim SPDX text.
- `LICENSE.apache-2.0.txt` — Apache-2.0, verbatim SPDX text.
- `CLA.md` — individual contributor licence agreement DRAFT (grant to
  andeye Ltd broad enough to dual-license the App Store builds). Needed for
  GPL/AGPL; for Apache a DCO sign-off replaces it.
- `CONTRIBUTING-sections.md` — the licence section to append to
  CONTRIBUTING.md, one variant per option.

## Why a CLA and not just the licence

andeye Ltd ships the same code to the App Store under proprietary terms
(GPL from OTHER copyright holders cannot ship there). That works only while
the company holds rights to every line. The CLA keeps external contributions
dual-licensable; without it, the first merged outside PR freezes the App
Store build out of that code.
