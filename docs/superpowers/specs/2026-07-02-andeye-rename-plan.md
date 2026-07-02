# Ambitick → andeye rename plan

Naming decided 2026-07-02 (coordination note, PRO vibe relaying Martin):
product brand is **andeye**; "Ambitick" survives only as the community repo
location and the historical working name. This plan splits the rename into
what users see (must change before first external distribution) and what only
developers see (cheap to defer, decide at FOSS-publish).

## Phase 1 — user-visible (lands with the first beta/public build)

| Surface | Today | Action |
|---|---|---|
| App bundle + process name | `Ambitick.app` | `andeye.app` (short name, Martin 2026-07-02); long/store name "andeye time tracker" |
| Bundle identifier | ad-hoc, none baked | mint as `com.andeye.mac` (or Apple-portal choice) when the entitled build lands — never shipped, so free |
| CloudKit container | not yet created | `iCloud.com.andeye.mac` — created AFTER rename, no migration |
| Menu-bar/UI strings | "Ambitick Time", "Ambitick Review", "Ambitick Settings", popover copy | sweep AmbitickUI string literals |
| Signing identity | "Ambitick Dev" (ad-hoc stable) | new "andeye Dev" identity; replaced anyway by Developer ID |
| **Application Support dir** | `~/Library/Application Support/Ambitick/` (journal.sqlite, settings, learning, pins…) | **THE ONE DATA-RISK ITEM**: on first andeye launch, if the andeye dir is absent and the Ambitick dir exists, MOVE it (rename, not copy) then proceed. One-shot, checked by a Mac-layer test. Do NOT leave dual dirs. |
| Debug log | `/Users/Shared/ambitick-debug.log` | `/Users/Shared/andeye-debug.log` (no migration; old file just goes stale) |
| URL scheme | `ambitick://xero-callback` (pro) | PRO flips to `andeye://` (already announced); main has no scheme today |
| Licence keys | `ANDE1.` prefix | DONE 2026-07-02 (flipped before any real key) |
| README/MANUAL/docs | Ambitick throughout | copy sweep; keep one "formerly Ambitick" line for search |
| OP integration runner | scratch WP #224 naming only | cosmetic, leave |

Sequencing: everything in phase 1 is mechanical EXCEPT the support-dir
migration, which needs its own check + an on-device verification (live
journal at stake). Do the migration commit first and alone.

## Phase 2 — developer-visible (decide at FOSS-publish, default: keep)

SPM package/target/module names (`Ambitick`, `AmbitickCore`, `AmbitickMac`,
`AmbitickUI`, checks, integration), the `pro` package's product names, and
the GitHub org/repo — DESTINATION now known: github.com/andeyePro/andeye
(transfers leave permanent redirects, so the move is cheap whenever taken).

Renaming modules is pure churn: giant diff, breaks the PRO repo's imports
(coordinate via the seam-change protocol), invalidates local checkouts, zero
user value. The public story "working name Ambitick, product andeye" is
normal (cf. countless projects). RECOMMENDATION: keep module names
permanently; if brand hygiene wins at publish time, do it in one
compiler-guided commit + a coordinated PRO bump, before any external
contributor exists.

## Explicitly NOT renamed

- Journal/store JSON keys (`pushedToOP`, `opTimeEntryID`, `is_op`): frozen
  wire format, name is historic, checked by the wire-freeze suite.
- a private notes repo note names already swept by the PRO vibe (stubs left).
