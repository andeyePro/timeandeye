# sites/ – the andeye web estate (static, no build step)

Each subdirectory is one Cloudflare Pages project serving plain static
files – no framework, no dependencies, nothing to rot. The Time andeye
product site (Astro + Starlight, incl. the manual) stays at `/site` and is
unchanged by this directory.

| Directory | Domain | Status |
|---|---|---|
| `andeye.com-astro/` | andeye.com | CURRENT – Astro, copy editable in src/content/home.md |
| `vibe.andeye.com-astro/` | vibe.andeye.com | CURRENT – Astro, copy editable in src/content/home.md |
| `andeye.com/`, `vibe.andeye.com/` | – | superseded static drafts (first-pass logos) – delete after sign-off |
| `logo-lab.html` | – | the logo variant picker (self-contained; open in a browser) |
| `shared/andeye-eye.js` | – | the eye engine both Astro projects copy into public/ |

## Deploying (Martin, ~5 min each, Cloudflare dashboard)

1. Cloudflare Pages → Create project → connect the repo with root directory
   `sites/<domain>-astro`, build command `npm run build`, output `dist`.
2. Add the custom domain (andeye.com / vibe.andeye.com) to the project.
3. BEFORE pointing andeye.com here: create the conferences project and move
   the CURRENT andeye.com content to conferences.andeye.com (its source is
   not in this repo – it lives wherever the existing site is hosted). The
   new andeye.com deliberately does NOT link to it.

## Design notes

- The eye mark is drawn live from the ORIGINAL brand file
  (assets/brand/andeye.svg: blue #56C1FF, 17px stroke, exact path) with the
  app's real eyelid wink; the iris is clipped by the aperture so a closing
  lid crops it. Variants + weights: sites/logo-lab.html. Page copy lives in
  each project's src/content/home.md – edit the markdown, push, Pages
  rebuilds.
- Palette matches the Time andeye site drafts (dark navy, #f0a13a accent).
- Copy rules: Martin's voice; no em dashes (en dash with spaces); the
  values copy is from his 2026-07-07 brief (recorded in
  a private path
