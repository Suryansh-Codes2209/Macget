# Chrome-safe extension split — design

**Date:** 2026-07-31
**Status:** approved, pending implementation plan

## Problem

The Chrome Web Store rejected `MacGet Download Capture`
(`ldmhmgglgemkoogpokfcgplbpfokcejl`, v1.2) on 2026-07-30 under the Prohibited
Products policy: *"Providing unauthorised download of copyrighted content or
media on YouTube."* The stated corrective action is "None" — the rejection is
scoped to the item, not the version.

The extension's media path is what triggered it. That path is not one feature but
five surfaces, all reachable from `<all_urls>`:

| Surface | Location (pre-split) |
| --- | --- |
| In-page overlay button anchored to the largest `<video>` | `chromium/content.js` (whole file) |
| Context menu "Download media with MacGet" (video/audio) | `background.js:481` |
| Context menu "Send this page's video to MacGet" (page) | `background.js:482` |
| Popup "Send video" | `popup.js:207`, `popup.html:138` |
| HLS/DASH manifest sniffing → `manifestURLs` for yt-dlp | `background.js:65`, `:431`, `:575-594` |

Supporting code: the `kind: "media"` branch of `captureURL` (`background.js:444`),
the `macget-media` and `macget-video-prefs` message handlers (`:540`, `:558`),
and the `showVideoButton` / `videoButtonCorner` / `videoButtonHiddenHosts`
settings.

Removing only the overlay leaves four of the five intact.

## Goal

Chrome gets a build whose *source contains no media-extraction code at all* —
a property provable by grepping the shipped package, not merely asserted.
Firefox (AMO permits this class of extension) keeps the full feature set from a
shared core, so bug fixes are written once.

Explicitly out of scope: the macOS app keeps yt-dlp media extraction. Chrome Web
Store policy governs the extension, not the desktop application.

## Trim depth

Decided: **trim to the media boundary.** Remove every media path and the
`webRequest` sniffer. *Keep* the gesture content script (so the jumplink filter
retains its gesture branch) and *keep* `cookies` (so authenticated file
downloads still work).

The rejection was about functionality, not permission breadth, so a deeper trim
buys review comfort at a real cost in capability. Permission delta is exactly
one: `webRequest` is dropped.

```
permissions: downloads, nativeMessaging, storage, cookies, tabs,
             contextMenus, notifications          # webRequest removed
host_permissions: ["<all_urls>"]                  # unchanged (cookies.getAll)
content_scripts: gesture reporter only
```

## Approaches considered

**A — media code in its own files; the Chrome package omits them.** Chosen.

**B — one source tree, build-time stripping via `// #if MEDIA` markers.**
Rejected: fails *open*. A marker typo, or a refactor that moves code outside the
markers, ships media code to Chrome silently.

**C — two independent source trees.** Rejected: every core fix gets made twice.
That drift is exactly what the existing `build.sh` sync step was written to
prevent.

## Architecture

```
BrowserExtension/
  shared/                    # media-free core, single source of truth
    heuristics.js            # pure predicates (unchanged)
    background.js            # file capture, jumplink filter, health, history
    content.js               # gesture reporter only (~25 lines)
    popup.html  popup.js  options.html  options.js  theme.css  icons/
  media/                     # Firefox-only. Nothing here reaches Chrome.
    media.js                 # media context menus, macget-media handler,
                             # webRequest sniffer, captureMedia()
    content-video.js         # the overlay
    popup-media.html         # the "Send video" button fragment
    options-media.html       # the "Video button" settings fragment
    media-ui.js              # wires both fragments
  targets/chromium/manifest.json
  targets/firefox/manifest.json
  test/heuristics.test.js
  test/no-media-in-chrome.test.js
  build.sh
  build/                     # gitignored output: build/chromium/, build/firefox/
```

### `media.js` duplicates the capture wrapper rather than hooking into core

`shared/background.js` must contain no media-shaped seam — no `kind === "media"`
branch, no optional `decorate` callback, nothing that reads as a feature someone
removed. `media.js` therefore defines its own `captureMedia()` carrying its own
dedupe / breaker / history / notify wrapper (~20 duplicated lines), calling only
the core globals `sendToMacget`, `recordHistory`, `flashBadge`, `notify`,
`getConfig`, `breakerAllows`.

Chrome MV3 `importScripts` and Firefox `background.scripts` share one global
scope, so no module plumbing is needed. The duplication is the price of the
guarantee; the deliverable is provable absence, and reviewers grep source rather
than infer intent.

### HTML fragments are inserted, not stripped

`popup.html` and `options.html` in `shared/` carry a literal `<!--MEDIA-SECTION-->`
line. `build.sh` substitutes the corresponding fragment for Firefox and deletes
the line for Chrome.

This is a text transform, which approach B was rejected for — the difference is
direction. It *adds to* a correct-by-default base rather than *cutting from* a
full one. If the transform breaks, Chrome stays clean and Firefox loses a
settings panel. The failure mode points the safe way.

### Load order

- Chrome: `service_worker: background.js`, which `importScripts("heuristics.js")` as today.
- Firefox: `background.scripts: [heuristics.js, background.js, media.js]`.

`media.js` pushes its entries onto the `MENUS` array at load time. Safe, because
`installMenus()` runs only on `onInstalled` / `onStartup`.

### Settings ownership

`showVideoButton`, `videoButtonCorner`, and `videoButtonHiddenHosts` move out of
`shared/background.js`'s `DEFAULTS` and into `media/media.js`'s own defaults
object, merged over the core config at read time on Firefox only.

## Enforcement

`test/no-media-in-chrome.test.js` walks every file in `build/chromium/` and fails
on any hit against a denylist:

```
m3u8   mpd   yt-dlp   "media"   showVideoButton   macget-video-prefs
sendVideo   webRequest   extractor
```

`build.sh` already refuses to package when `node --test` fails, so the guarantee
is enforced by the build rather than documented in a README.

## Testing

- `heuristics.test.js` — unchanged. `heuristics.js` has no media code.
- `no-media-in-chrome.test.js` — new; the guard above.
- Manual, `build/chromium/` loaded unpacked: a file download still captures and
  cancels only after host ack; a redirect-shaped URL is still dropped by the
  jumplink filter; no overlay appears on a YouTube watch page.
- Manual, `build/firefox/`: overlay still appears and still sends.

## Known follow-ups, deliberately not in scope

- **Do not submit to the Web Store until the appeal on case 2-7571000041635
  resolves.** Republishing a removed item is itself a policy violation and
  escalates to the developer account.
- `NativeMessagingInstaller.swift:21` still lists the banned store ID. Harmless —
  existing installs keep working — but any newly approved listing needs its ID
  added there or capture fails silently with no user-visible error.
- The unpacked dev ID `knccbiljmilfmhfellkfbdmilpbdkgni`, pinned by the manifest
  `key`, is unaffected. `README.md`'s "Load unpacked → select the `chromium/`
  folder" becomes `build/chromium/`.
- `BrowserExtension/README.md` and the site docs page must state the Chrome /
  Firefox capability difference rather than describing one extension.
