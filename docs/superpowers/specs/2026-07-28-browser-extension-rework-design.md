# Browser Extension Rework — Design

**Date:** 2026-07-28
**Scope:** `BrowserExtension/` (chromium + firefox) and a ~15-line addition to `MacgetCaptureHost/main.swift`.

## Problem

The extension captures downloads correctly, but it is **mute**. Its single UI surface is a
settings form that doubles as the toolbar popup, and the "Active" pill it shows reflects a
checkbox — not whether Macget is reachable. When the native-messaging host is missing or
browser integration is off in the app, `sendNativeMessage` throws, the download silently
falls through to the browser, and the only trace is a `console.warn` nobody reads.

Three further defects:

1. **MV3 worker sleep loses `lastGestureByTab`.** When the service worker naps and wakes, the
   gesture map is empty. A legitimate download started in a background tab then matches the
   "no recent gesture + tab not active" branch of `shouldDropAsJumplink` and is **silently
   dropped**. The filter fails closed; it should fail open.
2. **`content.js` installs a permanent `setInterval(reposition, 800)` on every page** the user
   visits, whether or not a video exists.
3. The in-page button is inline-styled, so a page's `!important` rules can break it, and it
   does not survive fullscreen.

There is also no context-menu capture, no toolbar badge, and no notification — so a download
manager extension gives the user no signal that it did anything.

## Constraints (discovered, not assumed)

- **Firefox MV3 uses `background.scripts` (an array); Chrome MV3 uses `background.service_worker`
  (a single file).** Both are classic, non-module contexts. `background.js` must therefore stay
  a self-contained classic script for `build.sh`'s shared-source model to keep working. Shared
  code is loaded via `importScripts()` on Chrome and an extra array entry on Firefox — not ES
  modules.
- **The activity feed can only ever be extension-local history.** `MacgetCaptureHost` is a
  one-shot process that writes a file and exits; there is no persistent port for Macget to
  report progress back over. The popup shows "sent to Macget", never a progress percentage.
- **`CaptureInbox.scan()` discards undecodable JSON with a log line** (`CaptureInbox.swift:80`).
  A ping message reaching an *old* host therefore degrades safely: it lands in the inbox, fails
  to decode as a `CaptureRequest`, and is deleted.
- `build.sh` strips the `key` field when packaging for the Web Store. Any new file added to
  `chromium/` must be added to the `SHARED` list so it reaches `firefox/`.

## File layout

`chromium/` remains the single source of truth.

```
chromium/
  manifest.json          + "contextMenus", "notifications" permissions
  heuristics.js     NEW  pure predicates — jumplink classification, host matching, formatting
  background.js          orchestration only; loads heuristics.js
  content.js             redesigned in-page video button
  popup.html/.js    NEW  toolbar popup: connection status + activity + master toggle
  options.html/.js       now a full-width settings page (was the popup)
  theme.css         NEW  shared design tokens + card/switch/stepper/toast primitives
  icons/
test/               NEW  node --test suites over heuristics.js
```

`heuristics.js` exists to make the subtle logic testable. It defines globals in a browser
context and appends a `module.exports` guard for Node:

```js
if (typeof module !== "undefined" && module.exports) module.exports = { ... };
```

Chrome's service worker reaches it with `importScripts("heuristics.js")`; Firefox lists it
first in `background.scripts`; `node --test` requires it directly.

## Components

### `heuristics.js` (pure, tested)

| Export | Responsibility |
|---|---|
| `matchesHost(host, list)` | suffix-aware host matching |
| `looksLikeJumplink(url)` | shortener / ad-network / redirect-shaped URL |
| `hostnameOf(url)` | safe URL parse, `""` on failure |
| `isCapturable(url)` | http(s) only — excludes `blob:`/`data:` Macget cannot re-fetch |
| `pushHistory(list, entry, cap)` | ring buffer, newest first, bounded |
| `formatBytes(n)` | display helper |
| `relativeTime(then, now)` | display helper |

No `chrome`/`browser` API access anywhere in this file — that is what makes it testable.

### `background.js`

Existing responsibilities (downloads capture, media requests, manifest sniffing) plus:

**Health.** `pingHost()` sends `{kind:"ping"}` and caches the result for 30s in memory, mirrored
into `storage.session` so the popup reads it without a round trip. Result is one of
`connected` / `unreachable`, with the thrown message retained verbatim as `lastError`.

**Gesture persistence and fail-open.** `lastGestureByTab` is mirrored into `storage.session`,
which survives worker sleep within a browsing session. Additionally, the worker records its
own start time; within `GESTURE_GRACE_MS` (10s) of a cold start, `shouldDropAsJumplink` returns
`false` for the gesture-based branch regardless of what the map says. The high-confidence
branch (shortener / ad host / redirect-shaped URL) is unaffected and still drops.

> Rationale: dropping a download the user actually asked for is a worse failure than capturing
> a jumplink the user can cancel. The filter must fail open.

**Badge.** `✓` in green flashed for 3s after a successful handoff; `!` in red held while the
host is unreachable; cleared otherwise. Suppressed when the badge option is off.

**Notifications.** One on successful capture (`"Sent to Macget — <filename>"`), one on
unreachable host. The unreachable notification is rate-limited to once per 10 minutes so a
dead host cannot spam a notification per download. On by default; toggleable in options.

**History.** A 20-entry ring buffer in `storage.local` under `history`. Entry shape:
`{ kind, url, filename, host, at, ok }`. Written after every handoff attempt, success or
failure — a failed capture is exactly what the user wants to see in the list.

**Context menus.** Registered on `runtime.onInstalled`:

| Context | Title | Payload |
|---|---|---|
| `link` | Download link with Macget | `kind:"file"`, `linkUrl` |
| `image` | Download image with Macget | `kind:"file"`, `srcUrl` |
| `video`, `audio` | Download media with Macget | `kind:"file"`, `srcUrl` |
| `page` | Send this page's video to Macget | `kind:"media"`, `pageUrl` |

All single-target — no link harvesting. Each goes through the same cookie/referer collection
and the same dedupe + circuit breaker as an `onCreated` capture.

**Message replies.** `onMessage` handlers now return a result (`{ok, error}`) so the content
script and popup can show real outcomes instead of firing into the void.

### `popup.html` / `popup.js` — 360px

- Hero: icon, wordmark, live status pill.
- **Status row**, three states from the real ping:
  - `Connected` — host answered
  - `Paused` — capture toggle is off
  - `Not connected` — shows the remedy inline ("Turn on Browser integration in Macget →
    Settings") plus a **Retry** button that forces a fresh ping.
- Master **Capture downloads** toggle — the only setting in the popup.
- **This tab**: "Send video on this page" and "Send page URL to Macget".
- **Recent**: last 8 history entries — favicon, filename, host, relative time, kind badge.
  Empty state copy rather than a blank panel.
- Footer: "All settings →" opens the options page via `runtime.openOptionsPage()`.

### `options.html` / `options.js` — `max-width: 720px`, centered

| Section | Contents |
|---|---|
| Capture | enable, skip-smaller-than (MB), notifications, badge |
| Filtering | jumplink filter, gesture window (ms), denylist textarea |
| Video | show in-page button, button corner, per-site hide list |
| Diagnostics | **Ping host** button showing the raw reply, extension ID, host name, `lastError` verbatim |
| About | version, link to the MacGet site |

Diagnostics exists because every support question about this extension is "why didn't it
capture", and today that answer lives only in `console.warn`.

### `content.js`

- **Shadow DOM** host element, so page `!important` rules cannot restyle the button.
- Real SVG download glyph plus a "MacGet" label; hover-reveals over the player, dimmed
  otherwise.
- Anchoring via `ResizeObserver` on the video and `IntersectionObserver` for visibility —
  **replacing the unconditional `setInterval(reposition, 800)`**. A `MutationObserver` on
  `document.body` handles SPA player swaps (YouTube), so the `yt-navigate-finish` special case
  can go.
- `fullscreenchange` re-parents the shadow host into `document.fullscreenElement` so the button
  survives fullscreen.
- States: idle → sending → `Sent` / `Macget not connected`, driven by the background's reply.
- Honors the "show in-page button" option and the per-site hide list.
- The gesture reporter is unchanged.

### `MacgetCaptureHost/main.swift`

After reading the message, before writing anything:

```
if the decoded JSON's "kind" == "ping":
    writeAck({ok: true, version: 1})
    exit(0)          // no inbox file, no launchApp()
```

Deliberately does **not** call `launchApp()` — launching Macget because the user opened the
popup would be obnoxious. The ping reports only that the host binary exists and is executable,
which is the fact the extension cannot otherwise determine. Whether the app is currently
running is not reported and does not matter: the drop-directory design means a non-running app
still receives captures on next launch.

## Data flow

```
downloads.onCreated ─┐
context menu click  ─┼─→ collect cookies+referer → dedupe → breaker → sendNativeMessage
content-script msg  ─┘                                                      │
                                                            ┌──────────────┴──────────────┐
                                                         ok │                              │ throw
                                              cancel+erase browser copy            record lastError
                                              badge ✓ · notify · history           badge ! · notify (rate-limited)
                                                                                   history entry {ok:false}
                                                                    leave the browser download intact
```

`popup.js` reads `storage.session` health + `storage.local` history on open, and subscribes to
`storage.onChanged` so it stays live while open.

## Error handling

- A thrown `sendNativeMessage` **never** cancels the browser download. This existing ordering
  invariant is preserved everywhere, including on the new context-menu path.
- The circuit breaker's behavior is unchanged (25 handoffs / 10s disables capture), but it now
  also fires a notification explaining why capture switched off — currently it only logs.
- Denylist entries are trimmed and lowercased on save; invalid lines are shown inline in
  options rather than silently dropped.
- `storage.session` is unavailable on older engines; all reads fall back to in-memory state.

## Testing

**`node --test` over `heuristics.js`** — jumplink classification (shortener hosts, ad hosts,
redirect-shaped URLs, and the negative cases that must *not* match), suffix host matching
including the `evil-bit.ly` non-match, ring-buffer bounds and ordering, and the formatters.
This is where the subtle bugs live and it is testable without a browser.

**Manual QA matrix in `BrowserExtension/README.md`** for the paths that require a real browser:
popup states with the host present/absent, context menu on each target type, badge and
notification behavior, fullscreen video button, and the worker-sleep gesture case
(`chrome://serviceworker-internals` → stop the worker → start a background-tab download →
confirm it is captured, not dropped).

## Out of scope

- Link harvesting / "capture all links on page" (explicitly deferred).
- Safari — still requires a signed Safari App Extension.
- Any reverse channel reporting download progress from Macget back to the browser.
- Reducing the `<all_urls>` + `webRequest` permission surface; both are still required for
  cookie collection and HLS/DASH manifest sniffing.
