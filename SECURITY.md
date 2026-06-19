# Security Policy

## Supported versions

Macget is an actively developed, solo-maintained project. Security fixes land on
the latest release only.

| Version | Supported |
| ------- | --------- |
| Latest release (`main`) | ✅ |
| Older releases | ❌ |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately, in order of preference:

1. **GitHub private advisory** — the [Security tab](https://github.com/Suryansh-Codes2209/Macget/security/advisories) → **Report a vulnerability**.
2. **Email** — suryansh.codes2001@gmail.com with the subject `Macget security`.

Please include: affected version, steps to reproduce, impact, and any proof of
concept. I'll acknowledge within a few days (best-effort for a solo project) and
keep you updated until it's resolved, crediting you in the release notes if you'd like.

## Good to know

- Macget is distributed as a **free, un-notarized** build; the first launch
  requires a one-time Gatekeeper "Open Anyway" (see the README). Only download it
  from the official [Releases page](https://github.com/Suryansh-Codes2209/Macget/releases).
- The app bundles **yt-dlp** and **ffmpeg**, and downloads **Deno** on first use
  of video features. These are third-party tools; report issues in *their*
  upstream projects, but tell me if Macget invokes them unsafely.
- Signing/notarization material is never committed (see `.gitignore`).
