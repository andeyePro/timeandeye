import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://andeye.com',
  integrations: [
    starlight({
      title: 'Time&i manual',
      description: "Time&i's user manual – the community macOS menu-bar time tracker.",
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/andeyePro/timeandeye' },
      ],
      components: {
        SiteTitle: './src/components/AndeyeSiteTitle.astro',
      },
      sidebar: [
        { label: 'Overview', slug: 'manual' },
        { label: 'The menu-bar popover', slug: 'manual/menu-bar-popover' },
        { label: 'Auto-tracking and attribution', slug: 'manual/auto-tracking-and-attribution' },
        { label: 'Pinning', slug: 'manual/pinning' },
        { label: 'The Time window', slug: 'manual/time-window' },
        { label: 'Settings', slug: 'manual/settings' },
        { label: 'Data, sync and safety', slug: 'manual/data-sync-and-safety' },
        { label: 'Keyboard', slug: 'manual/keyboard' },
        { label: 'Getting help', slug: 'manual/getting-help' },
      ],
    }),
  ],
});
