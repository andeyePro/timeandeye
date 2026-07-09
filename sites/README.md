# sites/ – the andeye web estate

Two Astro projects, one shared eye engine, one previews folder. The Time
andeye product site (Astro + Starlight, incl. the manual) is NOT here – it
stays at `/site` in the repo root and deploys to time.andeye.com.

| Path | Domain | What it is |
|---|---|---|
| `andeye.com-astro/` | andeye.com | suite/values home – copy editable in src/content/home.md |
| `vibe.andeye.com-astro/` | vibe.andeye.com | vibe explainer – copy editable in src/content/home.md |
| `shared/andeye-eye.js` | – | the eye engine (source of truth; both projects copy it into public/) |
| `previews/` | – | SELF-CONTAINED review files (open in any browser): andeye.com.html, vibe.andeye.com.html, logo-lab.html – regenerated in place after every change, same filenames |

Superseded static drafts (`andeye.com/`, `vibe.andeye.com/`, the root
`logo-lab.html`) were pruned 2026-07-08 – git history keeps them.

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
  app's real eyelid wink; the tail retracts along its own curve so the &
  holds shape; the iris is clipped by the aperture and appears after the
  draw-on. Tuning: previews/logo-lab.html.
- Palette matches the Time&I site (dark navy, #f0a13a accent).
- Copy rules: Martin's voice; no em dashes (en dash with spaces); the
  values copy is from his 2026-07-07 brief (recorded in
  a private path
