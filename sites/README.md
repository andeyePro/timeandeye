# sites/ – the andeye web estate (static, no build step)

Each subdirectory is one Cloudflare Pages project serving plain static
files – no framework, no dependencies, nothing to rot. The Time andeye
product site (Astro + Starlight, incl. the manual) stays at `/site` and is
unchanged by this directory.

| Directory | Domain | Status |
|---|---|---|
| `andeye.com/` | andeye.com | ready to deploy – values home + product cards |
| `vibe.andeye.com/` | vibe.andeye.com | ready to deploy – explainer/holding page |

## Deploying (Martin, ~5 min each, Cloudflare dashboard)

1. Cloudflare Pages → Create project → "Direct upload" (or connect the repo
   with root directory `sites/<domain>` and NO build command, output `/`).
2. Add the custom domain (andeye.com / vibe.andeye.com) to the project.
3. BEFORE pointing andeye.com here: create the conferences project and move
   the CURRENT andeye.com content to conferences.andeye.com (its source is
   not in this repo – it lives wherever the existing site is hosted). The
   new andeye.com deliberately does NOT link to it.

## Design notes

- The eye mark is code-drawn SVG using the app's own AndeyeLogo cubic
  geometry – never a screenshot. Orange
  clock-iris = Time andeye; white circle-iris-with-`>` = Vibe andeye.
- Palette matches the Time andeye site drafts (dark navy, #f0a13a accent).
- Copy rules: Martin's voice; no em dashes (en dash with spaces); the
  values copy is from his 2026-07-07 brief (recorded in
  a private path
