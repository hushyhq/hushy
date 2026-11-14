// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

const repo = 'https://github.com/hushyhq/hushy';

export default defineConfig({
  site: 'https://docs.tryhushy.com',
  telemetry: false,
  integrations: [
    starlight({
      title: 'Hushy',
      description: 'On-device dictation and meeting notes for the Mac: how to use it, how it works, and how to train its models.',
      social: [{ icon: 'github', label: 'GitHub', href: repo }],
      editLink: { baseUrl: `${repo}/edit/main/docs/` },
      lastUpdated: false,
      sidebar: [
        { label: 'Start here', items: ['index', 'build/from-source'] },
        { label: 'Using Hushy', items: ['using', 'using/privacy'] },
        {
          label: 'How it works',
          items: ['how-it-works/pipeline', 'how-it-works/cleanup-and-guards'],
        },
        {
          label: 'Train your own models',
          items: [
            'train/overview',
            'train/setup',
            'train/meeting-extract',
            'train/cleanup',
            'train/convert-and-run',
          ],
        },
        { label: 'Measure accuracy', items: ['measure/accuracy'] },
        { label: 'Contributing', items: ['contributing'] },
      ],
    }),
  ],
});
