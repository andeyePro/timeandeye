# andeye.com

The andeye product site: a placeholder marketing landing page at `/`, plus
the user manual (Starlight docs) at `/manual`. Built with
[Astro](https://astro.build) and [Starlight](https://starlight.astro.build),
deployed to Cloudflare Pages as a static site (no SSR adapter).

## Cloudflare Pages settings

When connecting this repo in the Cloudflare Pages dashboard, use:

- **Framework preset**: `Astro`
- **Root directory**: `site`
- **Build command**: `npm run build`
- **Build output directory**: `dist`
- **Environment variables**: `NODE_VERSION` = `20` (Astro 5 needs Node 18.20.8,
  ^20.3, or 22+; the framework preset alone doesn't always pin a modern
  enough default)

Cloudflare will build from `site/` on every push, so nothing else needs
configuring on the dashboard side.

## Local development

```
cd site
npm install
npm run dev      # http://localhost:4321
npm run build    # outputs to site/dist
npm run preview  # serve the built site locally
```
