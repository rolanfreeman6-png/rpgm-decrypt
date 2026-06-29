/**
 * Product catalog — the only place you edit to add or change products.
 *
 * Every product renders:
 *   • a card on the home catalog (`src/pages/index.astro`)
 *   • an entire page at /product/<slug> (`src/pages/product/[slug].astro`)
 *
 * To add a new product:
 *   1. Append an entry below.
 *   2. (Optional) drop assets into `public/products/<slug>/poster.svg` and
 *      `public/products/<slug>/demo.mp4` — the page will pick them up.
 *   3. Commit + redeploy. No code edits required.
 *
 * Schema fields:
 *   slug          — URL segment. Lowercase, hyphenated, unique, stable.
 *   name          — display name.
 *   tagline       — single line for the catalog card.
 *   status        — 'released' shows a primary release badge; 'coming-soon'
 *                   greys the card and disables downloads.
 *   description   — long-form markdown, rendered on the product page.
 *   demoVideo     — path under /public, e.g. '/products/<slug>/demo.mp4'.
 *                   Empty = poster fallback only.
 *   poster        — path under /public, fallback for hero when video is absent
 *                   or user prefers reduced motion. Defaults to the global
 *                   fallback if omitted.
 *   repo          — 'owner/name' on GitHub. Used by the client script to
 *                   auto-fetch the latest release assets. Leave empty to skip
 *                   release fetching for that product.
 *   links         — supplementary external links.
 */

export type ProductStatus = 'released' | 'coming-soon';

export interface ProductLinks {
  github?: string;   // full URL, e.g. https://github.com/owner/repo
  issues?: string;
  homepage?: string;
  docs?: string;
}

export interface Product {
  slug: string;
  name: string;
  tagline: string;
  status: ProductStatus;
  description: string;
  demoVideo?: string;
  poster: string;
  repo?: string;            // 'owner/name' — drives download buttons
  links?: ProductLinks;
  /** Optional ISO date of latest release (manual override; auto-fetched at runtime if repo set) */
  releasedAt?: string;
  /** Optional version override (auto-fetched at runtime if repo set) */
  version?: string;
}

export const products: Product[] = [
  {
    slug: 'rpgm-decrypt',
    name: 'rpgm-decrypt',
    tagline: 'One small binary that unlocks the assets out of any RPG Maker game.',
    status: 'released',
    poster: '/products/rpgm-decrypt/poster.svg',
    demoVideo: '', // drop demo.mp4 in public/products/rpgm-decrypt/ to enable
    repo: 'rolanfreeman6-png/rpgm-decrypt',
    links: {
      github: 'https://github.com/rolanfreeman6-png/rpgm-decrypt',
      issues: 'https://github.com/rolanfreeman6-png/rpgm-decrypt/issues',
    },
    description: [
      'A single static binary that recovers assets across the **five RPG Maker engine generations** —',
      '_XP_, _VX_, _VX Ace_, _MV_ and _MZ_ — from one command, with no installer and no runtime.',
      '',
      'It reads the encryption key out of `System.json` / `rpg_core.js` automatically; you do not pass one.',
      'If your game layout does not match the engine defaults, hand it the key with `--password` or',
      'a candidate list with `--password-file`.',
      '',
      '**Five formats, one tool** — `.rgssad` / `.rgss2a` / `.rgss3a` (XP / VX / VX Ace) and the',
      'MV / MZ packages (`.png_`, `.ogg_`, `.rpgmvp`, `.pak`).',
      '',
      '**Built to be wrong gracefully** — fuzzed aggressively, formally verified on its parser, and',
      'every write is contained inside the output folder.',
      '',
      'Use it on content you have the right to touch: recovering *your* assets, a lost key,',
      'a translation, or game preservation. See the project README for the full story.',
    ].join('\n'),
  },

  // ── coming-soon placeholders, kept minimal so the card grid shows how ─────
  // additions look. Replace or extend at will.
  {
    slug: 'project-tba',
    name: 'Project TBA',
    tagline: 'A second product slot, kept empty on purpose.',
    status: 'coming-soon',
    poster: '/products/rpgm-decrypt/poster.svg', // placeholder; swap when artwork exists
    description: 'Coming soon.\n',
  },
  {
    slug: 'project-tba-2',
    name: 'Project TBA II',
    tagline: 'A third slot to demonstrate the catalog at larger sizes.',
    status: 'coming-soon',
    poster: '/products/rpgm-decrypt/poster.svg',
    description: 'Coming soon.\n',
  },
];

export function findProduct(slug: string): Product | undefined {
  return products.find((p) => p.slug === slug);
}
