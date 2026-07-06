import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';

export const collections = {
  docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
  // owner-editable landing-page prose (src/content/copy/home.md); permissive
  // schema on purpose so the page's copy shape can evolve without a schema
  // edit here every time - see src/pages/index.astro for how it's consumed.
  copy: defineCollection({
    loader: glob({ pattern: '**/*.md', base: './src/content/copy' }),
    schema: z.record(z.any()),
  }),
};
