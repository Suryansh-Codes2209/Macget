# MacGet site: truth fixes, essential pages, versioned docs, SEO

**Date:** 2026-07-27
**Status:** Approved design, ready for implementation planning
**Scope:** `frontend/` (Next.js marketing site + docs), plus a two-line change to `site/index.html`

---

## Problem

The deployed site at <https://macget.suryansh.work/> is wrong in three distinct ways.

**It is broken.** `lib/site-config.ts` ships the literal placeholder `https://github.com/REPLACE_ME/macget` as `repoUrl`, `downloadUrl`, and `licenseUrl`. Every GitHub, Download, and License link on the live page 404s.

**It is untrue.** The site claims the app is "signed and notarized" in two places (`site-config.ts:43`, `:93`). The app is distributed free and **un-notarized** — as `README.md` and `SECURITY.md` both correctly state. The site contradicts the project's own security documentation, and users hit an unexplained Gatekeeper wall on first launch.

**It is stale.** The page advertises v1.0 while v1.2.0 ships. Two releases of features are undocumented and unadvertised: media downloads, authenticated downloads, the browser capture extension, priorities, bandwidth limits, checksums, HTTP/3, adaptive concurrency, auto-sort. There is no privacy policy, no install guide, no changelog, and no product documentation of any kind.

Additionally the site has no meaningful SEO surface: no `metadataBase`, no canonical URLs, no sitemap, no robots directives, no structured data, and a `summary_large_image` Twitter card that references no image.

## Goals

1. Every public claim on the site is true and every link resolves.
2. A user who downloads an un-notarized app knows what to expect **before** the Gatekeeper dialog appears, and knows exactly what to do after it.
3. A privacy policy that accurately describes what the app and its browser extension do — including the parts that look alarming out of context.
4. Product documentation for the shipping release, structured so it does not rot.
5. The site is fully indexable and presents correctly when shared.

## Non-goals

- Multi-version documentation trees. Only the latest release is supported (`SECURITY.md`); parallel trees would document versions that receive no fixes.
- Porting contributor documentation (`SETUP.md`, `CONTRIBUTING.md`, `CLAUDE.md`) to the site. It lives in the repo and would drift.
- Redesigning the existing visual system. New pages reuse it.
- Any change to the Swift app.

---

## Prerequisite: Next.js 15.5.22 → 16.2.12

Fumadocs 16.13 declares `next: 16.x.x` as a peer dependency. The last fumadocs supporting Next 15 is `fumadocs-ui@15.8.5`, a frozen branch — adopting it would mean building a docs system that is already end-of-life.

Migration surface is small: the app is a single static page with no middleware, server actions, route handlers, or API routes.

- `next lint` is **removed** in 16. The `lint` script migrates to the ESLint CLI (`npx @next/codemod@canary next-lint-to-eslint-cli .`). The current build already emits this deprecation warning.
- Turbopack becomes the default bundler.
- React 19.2.8 already satisfies fumadocs' `^19.2.0`. Tailwind 4.2.4 is supported by fumadocs' v4 CSS entrypoints.

**Gate:** `bun run build`, `bun run typecheck`, `bun run lint`, and `bun audit` must all pass on Next 16 with the existing single page **before** any content work begins. If 16 misbehaves, we discover it with zero new content at risk.

Next 16.2.12 also carries the CVE-2025-66478 fix (landed in 16.0.7), so this does not regress the security posture established in commit `603a6f4`.

---

## Architecture

### Routes

```
/                 landing page (refreshed)
/install          Install & First Launch          ← target of every download CTA
/privacy          Privacy Policy
/changelog        generated from CHANGELOG.md
/docs/*           fumadocs, ~15 MDX pages, labeled v1.2.0
```

### Layout boundary

Marketing routes (`/`, `/install`, `/privacy`, `/changelog`) are ordinary Next pages that reuse the existing components (`GlassCard`, `SectionHeading`, `MotionInView`, `GradientButton`) and the abyss/frost tokens in `app/globals.css`.

Fumadocs mounts in its own route group with its stylesheet **scoped to `/docs`**, so its CSS cannot leak into the marketing pages. It is themed to the brand palette rather than shipping the default theme.

Both trees share `Nav` and `Footer` so navigation is continuous.

### Content sources

| Content | Source | Mechanism |
|---|---|---|
| Docs pages | `frontend/content/docs/*.mdx` | authored, committed |
| Changelog page | `../CHANGELOG.md` | copied at build time by the existing `sync-assets` prebuild step |
| Version, URLs, features | `lib/site-config.ts` | single source of truth |

Extending `sync-assets` follows the pattern already in `package.json` (it copies branding SVGs from `../Macget/Resources/Branding/` the same way). Vercel clones the whole repo, so `../CHANGELOG.md` is present at build time.

---

## Anti-staleness

The page rotted because facts were duplicated into components by hand. Three mechanisms prevent a repeat:

1. **`lib/site-config.ts` is the only place** version strings, URLs, feature copy, and FAQ entries live. Components read from it.
2. **The changelog page is generated** from the repo's `CHANGELOG.md`. Cutting a release updates the site.
3. **The docs version label reads from one constant**, so a release is a one-line bump.

---

## Work item 1: Truth fixes

Non-negotiable corrections, applied before anything else.

| File / line | Currently | Becomes |
|---|---|---|
| `site-config.ts:11-13` | `github.com/REPLACE_ME/macget` | `github.com/Suryansh-Codes2209/Macget` |
| `site-config.ts:9` | `version: "1.0"` | `version: "1.2.0"` |
| `site-config.ts:43` | "Hardened Runtime, signed and notarized." | Hardened Runtime; ad-hoc signed; updates verified by EdDSA signature. |
| `site-config.ts:93` | "Universal binary signed and notarized." | Universal binary. Not notarized — see the install guide. |

Verified against source while writing: `Download.maxThreadCount = 16`, so the site's "up to 16 chunks" claim is correct. (`CLAUDE.md` still says 1–20 and is stale — out of scope here, worth a follow-up.)

## Work item 2: Landing page refresh

**Feature cards** rewritten to cover what 1.1.0 and 1.2.0 shipped: media downloads via yt-dlp, authenticated downloads backed by the Keychain, the browser capture extension, download priorities, bandwidth throttling, checksum verification, HTTP/3, adaptive concurrency with work-stealing, auto-sort into category folders.

**First-launch block.** Directly beneath the download CTA, a three-step "what happens on first launch" sequence: macOS shows a Gatekeeper warning → System Settings → Privacy & Security → **Open Anyway** → confirm once. Includes the `xattr` one-liner as a power-user alternative and links to `/install` for full detail. The intent is to set expectations *before* the user meets the dialog, without opening the page with an apology.

**FAQ** gains an honest *"Is it safe if it's not notarized?"* entry — no paid Apple Developer account, source is public and auditable, updates are EdDSA-signed independently of Apple. The two notarization claims are removed.

**Nav and footer** gain Docs, Install, Changelog, and Privacy links, and the corrected GitHub URL.

## Work item 3: `/install`

Three phases, matching how a user actually experiences it.

**Before installing.** macOS 26.4 Tahoe minimum. Download only from the official Releases page. What "un-notarized" means and why it is the case (no $99/yr Apple Developer account) — framed as a cost decision, not a red flag.

**Installing.** Open the DMG, drag to Applications.

**After installing — first launch.** The exact Gatekeeper wording users will see (*"Macget can't be opened because Apple cannot check it for malicious software"*), then: click **Done** → System Settings → Privacy & Security → scroll → **Open Anyway** → confirm. Then the power-user path:

```bash
xattr -dr com.apple.quarantine /Applications/Macget.app
```

with a plain-English explanation of what that command does. Instructing people to strip quarantine attributes without explaining the mechanism trains bad habits; the page explains that the flag is what triggers the check, and that removing it is a decision to trust this specific app.

Closes with verifying the install worked, how Sparkle handles every subsequent update (no re-download from the site), and how to uninstall.

## Work item 4: `/privacy`

Written from the code, not from a template. The app has no telemetry, no analytics, no accounts, and no backend — so the policy's job is to be specific enough to be credible.

**Local data.** `queue.json`, `settings.json`, `host_caps.json`, the `incoming/` handoff directory, and partial files, all under `~/Library/Application Support/Macget/`. Download credentials live in the **macOS Keychain**.

**Network contact.** Only: (a) hosts you explicitly download from; (b) Sparkle's appcast fetch to GitHub Pages, which necessarily observes an IP address and User-Agent; (c) media sites contacted by yt-dlp **when media extraction is enabled — it is off by default** (`mediaExtractionEnabled: false`).

**Browser extension — its own section.** The extension requests `downloads`, `cookies`, `webRequest`, `tabs`, `nativeMessaging`, `storage`, and `<all_urls>`. That is a broad set and users deserve the reason: cookies are read for the captured download's URL so that logged-in downloads work, and the payload travels over **local native messaging** into `~/Library/Application Support/Macget/incoming/` — never to a remote server. Stating this plainly is what makes the rest of the policy believable.

**The website.** Static, hosted on Vercel, no cookies, no analytics.

Includes an effective date and the contact address already published in `SECURITY.md`.

## Work item 5: `/changelog`

Renders `CHANGELOG.md`, copied in by the prebuild step. Version anchors are linkable.

## Work item 6: `/docs` — 15 pages, labeled v1.2.0

**Getting Started** — Introduction · Installation · First Launch & Gatekeeper · Updating
**Using MacGet** — Adding Downloads · Media Downloads (yt-dlp) · Authenticated Downloads · Browser Extension · Priorities & Scheduling · Organizing Downloads · Verifying Checksums · Settings Reference
**How It Works** — Engine Pipeline · Adaptive Concurrency · Resume Semantics
**Reference** — File Locations & Troubleshooting

Content derives from `README.md`, `CHANGELOG.md`, and `docs/architecture.md`, **verified against the Swift source** before publication.

**Released-only rule.** Docs describe the shipping v1.2.0 build. Work present on `main` but not in the released DMG is either omitted or explicitly marked *Unreleased*. Confirmed by the user: **quiet-hours scheduling is not released** and must be marked Unreleased or omitted, despite `scheduleEnabled` / `scheduleStartMinutes` / `scheduleEndMinutes` existing in `AppSettings.swift`. The same check applies to every media sub-option before it is documented as available.

The Settings Reference is built by reading `AppSettings.swift` directly, including each setting's real default and clamp range (e.g. `requestTimeoutSeconds` defaults to 30, clamped 5–300; `maxRetriesPerChunk` defaults to 5, clamped 1–10).

## Work item 7: SEO

Runs in parallel with the content work; every new page ships with its metadata rather than being retrofitted.

**Canonical origin.** `metadataBase = https://macget.suryansh.work`. Every route declares `alternates.canonical`.

**Per-route metadata.** Unique title and description per page — no inherited duplicates, which is the most common cause of pages being crawled but not indexed. Fumadocs pages generate theirs per MDX file.

**`app/sitemap.ts`** enumerates the four marketing routes plus every docs page, read from the fumadocs source so new pages are listed automatically.

**`app/robots.ts`** allows crawling and points at the sitemap in production. On preview deployments (`VERCEL_ENV !== "production"`) it emits `noindex`, so preview URLs never compete with production.

**Open Graph images.** A branded OG image via `opengraph-image` using the existing wordmark, with per-page variants where they add value. This also repairs the currently broken `summary_large_image` Twitter card, which declares a large-image format while supplying no image.

**Structured data (JSON-LD).** `SoftwareApplication` on the landing page (name, operating system, `DeveloperApplication` category, price 0, license) — this is what drives rich results for app queries. `FAQPage` on the landing FAQ. `BreadcrumbList` on docs pages.

**Duplicate-content consolidation.** `site/index.html` on GitHub Pages is an older landing page for the same product, currently competing with the real site and still claiming the app is notarized. It gains a `noindex` meta tag and a canonical pointing at `https://macget.suryansh.work/`.

> `site/appcast.xml` must remain at its exact current GitHub Pages URL. Every installed copy of MacGet polls that `SUFeedURL`; moving it silently breaks auto-updates for existing users. Only `index.html` is touched.

---

## Verification

Implementation is not complete until all of the following pass:

1. `bun run build`, `bun run typecheck`, `bun run lint` — clean.
2. `bun audit` — no advisories in `next`; no new production-dependency advisories introduced by fumadocs.
3. **No `REPLACE_ME` anywhere** in the built output.
4. **No occurrence of "notarized"** on the site except where it explains the app is *not* notarized.
5. Every internal link resolves; every external link points at the real repo.
6. `/sitemap.xml` and `/robots.txt` render, and the sitemap contains all four marketing routes plus every docs page.
7. Every route returns a unique `<title>`, description, and canonical.
8. Documented settings defaults and clamp ranges match `AppSettings.swift`.
9. No feature is documented as available unless it is in the released v1.2.0 build.

## Risks

| Risk | Mitigation |
|---|---|
| Next 16 migration breaks the build | Gated: migrate and verify before any content work. Rollback is one commit. |
| Fumadocs CSS bleeds into marketing pages | Scope its stylesheet to the `/docs` route group; visually verify the landing page after mounting. |
| Fumadocs adds vulnerable transitive deps | Re-run `bun audit` after install; it is a production dependency. |
| Docs drift from the app | Content derives from repo files; the changelog page is generated; version is one constant. |
| Documenting unreleased features | Explicit released-only rule, verified per feature against v1.2.0. |
