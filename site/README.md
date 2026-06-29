# rolanfreeman — site

A static portfolio / product hub built with [Astro](https://astro.build) — dark, layered,
data-driven. Designed for Vercel-native deploys (bundle is plain static `dist/`).

## Stack

- **Framework**: Astro 5 (static output, no SSR, no backend)
- **Languages**: TypeScript, plain CSS with custom properties
- **Fonts**: Inter Variable + JetBrains Mono Variable (self-hosted via `@fontsource-variable/*`)
- **No** Tailwind, no React, no three.js. Hand-rolled CSS, hand-rolled Canvas for the hero.

## Local development

```powershell
cd site
npm install        # one-time
npm run dev        # http://localhost:4321 (Astro dev server)
npm run build      # astro check (type check) + astro build (writes site/dist/)
npm run preview    # serve the built dist/  on http://127.0.0.1:4321
```

> **Windows / PowerShell note:** all commands above work in PowerShell. If you prefer
> bash, every command here is portable.

## Adding a product

The catalog is data. Edit `src/data/products.ts` and append an entry:

```ts
{
  slug: 'my-new-tool',
  name: 'My new tool',
  tagline: 'One sharp line about what it does.',
  status: 'released',                       // or 'coming-soon'
  description: 'Long-form **markdown** copy. Use _italics_ for engine names, `code` for paths and flags.',
  poster: '/products/my-new-tool/poster.svg',
  demoVideo: '',                             // or '/products/my-new-tool/demo.mp4'
  repo: 'rolanfreeman6-png/my-new-tool',     // driving auto-fetched release buttons
  links: {
    github:  'https://github.com/rolanfreeman6-png/my-new-tool',
    issues:  'https://github.com/rolanfreeman6-png/my-new-tool/issues',
  },
}
```

Then drop artwork into `public/products/<slug>/`:

- `poster.svg` (or `poster.png`)  — used as hero fallback and og:image
- `demo.mp4` / `demo.webm`       — looping video for the hero (keep it small)

That's it. Run `npm run build` and:

- a card appears on `/`
- a full page appears at `/product/<slug>`
- if `repo` is set, the download buttons auto-fetch the latest GitHub release

### Status rules

- `released` — full product page, working download buttons, link strip in the footer.
- `coming-soon` — card is greyed; the page still exists but the download section
  turns into a "Coming soon / Watch on GitHub" panel.

## Deploying to Vercel

You have two paths; pick the one that fits your flow.

### Path A — Let Vercel build from Git

1. Push this repo to GitLab (already wired) — the `site/` directory is committed
   under the repo root.
2. In Vercel → **Add New Project** → import the GitLab repo.
3. Settings:
   - **Framework Preset**: Astro
   - **Root Directory**: `site`
   - **Build Command**: `astro build`     (Astro's default; or `npm run build`)
   - **Install Command**: `npm install`   (default)
   - **Output Directory**: `dist`         (default; **overrides** Astro output to `dist`)
4. Hit **Deploy**. Vercel will detect every commit on `main` and rebuild.

`site/vercel.json` already encodes the directory + framework choice so Vercel
auto-detect gives the right answer even with no UI tweaking.

### Path B — Vercel CLI from this machine

`vercel` is already authenticated on this box as `weghin-8337`.

```powershell
cd site
npm install
vercel --prod
```

That gives you a production URL on Vercel under your account instantly. Use
`vercel` (without `--prod`) for a preview URL. The CLI packages `dist/` and
uploads — no GitHub interaction needed.

#### Aliasing your domain on Vercel CLI

```powershell
vercel domains add rolanfreeman.com
vercel alias rolanfreeman-<...>.vercel.app rolanfreeman.com
```

(Or do that in Vercel Dashboard → Domains — usually easier.)

### One thing that matters

The download block uses an **unauthenticated** call to
`https://api.github.com/repos/<owner>/<repo>/releases/latest`. That endpoint is
rate-limited to **60 requests / hour / IP**. The page caches the response in
`localStorage` for **1 hour** to soften it; if you serve heavy traffic, add a
GitHub PAT via `?token=` or front the API with an edge function later — out of
scope here.

## File map — where to tune what

| You want to change…                       | Edit                                                                   |
| ----------------------------------------- | ---------------------------------------------------------------------- |
| **Colors / palette**                      | `src/styles/tokens.css` — vars `--void`, `--event-horizon`, `--accretion-1`, `--accretion-2`, `--lensing`, `--violet`, `--text`, `--muted` |
| **Spacing scale** (8-pt grid)             | `src/styles/tokens.css` — vars `--space-1` … `--space-11`              |
| **Type scale, leading, tracking**         | `src/styles/tokens.css` — vars `--text-*`, `--leading-*`, `--tracking-*` |
| **Motion easing + durations**             | `src/styles/tokens.css` — vars `--ease-out`, `--duration-fast|base|slow|stage` |
| **Radii**                                 | `src/styles/tokens.css` — vars `--radius-sm|md|lg|pill`                |
| **Accent-gradient stops**                 | `src/styles/tokens.css` — var `--gradient-accent` (used in `--gradient-accent-soft`, `--gradient-border`) |
| **Hero animation: black-hole tuning**     | `src/components/BlackHole.astro` — constants `STAR_COUNT`, `PARTICLE_COUNT`, `DISK_INNER`, `DISK_OUTER` (lines ~67–71), and rotation period (`Math.PI * 2 / 90`, ~90 s per revolution) |
| **Hero animation: disable entirely**      | `src/components/BlackHole.astro` — wrap the `start()` call in an `if (false)` block, OR remove the `<BlackHole />` from `src/pages/index.astro` |
| **Video blur / dark overlay**             | `src/components/VideoHero.astro` — `.video-hero__video, .video-hero__poster` filter + scale |
| **Scroll-reveal delay / distance**        | `src/styles/components.css` — `.reveal` rule, and per-element `style="--reveal-delay: …ms"` already set on catalog + sibling list items |
| **Download fetcher: cache TTL**           | `src/components/DownloadBlock.astro` — `CACHE_TTL_MS`                  |
| **Download fetcher: OS-keyword detection**| `src/components/DownloadBlock.astro` — `matchOS()` function regexes     |
| **Catalog data**                          | `src/data/products.ts`                                                |
| **Analytics / SEO tweaks**                | `src/layouts/Base.astro`                                              |
| **Page meta defaults**                    | `astro.config.mjs` — `site: 'https://rolanfreeman.com'` (used for canonical / og) |

## Accessibility / motion commitments

- `prefers-reduced-motion: reduce` — globally collapses durations to **1ms**,
  disables the black-hole animation (single static frame), and disables the
  looping hero video (poster only).
- All animations and videos pause on hidden tab (`visibilitychange`).
- Focus ring is visible but never chunky (`:focus-visible`).
- Color tokens chosen for AA contrast on body copy; headings run `--text-strong`
  for max contrast.
- All videos are `muted`, `loop`, `playsinline`, with `poster` and either
  `preload="metadata"` (video) or `loading="eager" decoding="async"
  fetchpriority="high"` (poster).

## Build / preview commands reference

| Command                | What it does                                                 |
| ---------------------- | ------------------------------------------------------------ |
| `npm run dev`          | Dev server with HMR at <http://localhost:4321>               |
| `npm run check`        | TypeScript + Astro check, no build artefacts                 |
| `npm run build`        | `astro check && astro build` — type check, then static build |
| `npm run preview`      | Serve the built `dist/` on <http://127.0.0.1:4321>          |

Build output lives in `dist/` — gitignored by Astro defaults.

## Status

- Last verified build: **0 errors, 0 warnings** under `astro check`.
- 4 static routes produced: `/`, `/product/rpgm-decrypt`,
  `/product/project-tba`, `/product/project-tba-2`.
- `sitemap-index.xml` + `sitemap-0.xml` are emitted by `@astrojs/sitemap`.
