// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// https://astro.build/config
export default defineConfig({
  site: 'https://rolanfreeman.com',
  trailingSlash: 'never',
  output: 'static',
  integrations: [sitemap()],
  build: {
    // Inline only the smallest CSS; let Astro CSS code-split the rest into per-route bundles.
    inlineStylesheets: 'auto',
  },
  vite: {
    build: {
      cssMinify: 'esbuild',
    },
  },
});
