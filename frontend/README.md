# Macget — Landing Page

Next.js 15 (App Router) landing page for Macget. Built with Bun, Tailwind v4, Motion (Framer Motion v12), TypeScript.

```bash
bun install
bun run dev      # http://localhost:3000
bun run build    # production build
```

Brand SVGs are auto-copied from `../Macget/Resources/Branding/` into `public/` and `app/icon.svg` on every `dev`/`build` via the `sync-assets` script.

Edit `lib/site-config.ts` to swap the placeholder GitHub URL for the real one before release.
