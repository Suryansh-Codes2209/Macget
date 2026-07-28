# MacGet Browser Capture Extension

Hands downloads you start in your browser to Macget, including the cookies/referrer
needed for logged-in downloads. Works with Chrome, Edge, Brave, and Firefox.

## How it works

```
Browser download starts
  → extension collects {url, cookies, referrer, user-agent, filename, size}
  → sends it to the native-messaging host (MacgetCaptureHost, bundled in Macget.app)
  → host drops it as JSON into ~/Library/Application Support/Macget/incoming/
  → Macget ingests it and downloads with its multi-threaded engine
The browser's own download is cancelled only AFTER Macget acknowledges, so a
missing/disabled host never makes a download disappear.
```

## One-time setup

1. **In Macget:** Settings → Browser integration → turn on **“Auto-capture downloads
   from the browser extension.”** This installs the native-messaging host manifests
   for every supported browser and starts watching the inbox.
2. **Install the extension** (below). Keep Macget installed at a stable location —
   the host path is re-stamped each launch, so moving `Macget.app` and relaunching
   is fine, but the manifests point at wherever Macget last ran.

### Chrome / Edge / Brave (unpacked)

1. Go to `chrome://extensions` (or `edge://extensions`, `brave://extensions`).
2. Enable **Developer mode**.
3. **Load unpacked** → select the `chromium/` folder.
4. The extension ID must be `knccbiljmilfmhfellkfbdmilpbdkgni` (pinned by the
   `key` in `manifest.json`; the host manifest only trusts this ID).

### Firefox (temporary add-on)

1. Run `./build.sh` once to sync shared files into `firefox/`.
2. Go to `about:debugging#/runtime/this-firefox`.
3. **Load Temporary Add-on** → select `firefox/manifest.json`.
   (Temporary add-ons are removed when Firefox restarts; for a permanent install,
   sign the `dist/macget-firefox.zip` via addons.mozilla.org.)

## Using it

**Toolbar popup** — connection state, the master capture toggle, this-tab actions,
and the last 8 captures. The connection state comes from an actual ping to the
native host, so “Not connected” means the plumbing is genuinely broken, not that a
checkbox is off.

**Right-click menus** — “Download link with MacGet” on a link, plus image, video,
and audio targets. Right-clicking the page offers “Send this page's video to
MacGet,” which hands the page URL to Macget's yt-dlp extractor. Anything you ask
for by hand skips the size and jumplink filters — those exist to judge downloads
that started on their own.

**Video button** — hover a video player and a MacGet button appears in the corner.
It survives fullscreen and reports whether the handoff actually worked.

**Options page** (toolbar popup → *All settings*, or the extension's Options) has
capture, filtering, and video-button settings, plus a **Diagnostics** section: check
the connection, see the extension ID and host name, and read the last error verbatim.
Start there when a download isn't being captured.

## Layout

```
chromium/            single source of truth for everything but manifest.json
  heuristics.js      pure logic: jumplink classification, host matching, formatting
  background.js      capture orchestration, health, badge, notifications, menus
  content.js         in-page video button + user-gesture reporting
  popup.html/.js     toolbar popup
  options.html/.js   settings page
  theme.css          shared tokens and controls
firefox/             built by build.sh; only manifest.json is hand-maintained
test/                node --test suites over heuristics.js
```

`heuristics.js` is loaded three ways, which is why it defines globals rather than
using ES modules: `importScripts()` from Chrome's service worker, the
`background.scripts` array on Firefox, and `require()` from the Node tests.

## Building / packaging

```sh
./build.sh   # runs tests, syncs chromium/ into firefox/, writes dist/macget-{chromium,firefox}.zip
node --test "test/*.test.js"   # tests on their own
```

Adding a file to `chromium/` means adding it to `SHARED` in `build.sh`, or Firefox
will silently ship without it.

## Testing

`heuristics.js` is the only file with no browser API access, and it is where the
subtle bugs live — host-suffix matching, jumplink classification, buffer bounds.
It is covered by `test/heuristics.test.js`.

Everything else needs a real browser. Manual matrix:

| Area | Check |
|---|---|
| Popup — connected | With Macget running and integration on, the pill reads **Active** and the hero glows amber. |
| Popup — not connected | Quit Macget / turn integration off → pill reads **Not connected**, hero glows red, **Check again** is offered. A started download stays in the browser. |
| Popup — paused | Toggle capture off → pill reads **Paused**; downloads stay in the browser. |
| Recent list | Capture something → it appears with host and relative time. A capture attempted while disconnected appears tagged **Not sent**. |
| Context menus | Right-click a link, an image, a `<video>`, and page background — each sends and flashes the badge. |
| Badge | ✓ flashes green after a capture; a red ! persists while the host is unreachable; both vanish when the badge option is off. |
| Notifications | One per capture; the "isn't connected" warning appears at most once per 10 minutes. |
| Video button | Hover a player → button appears in the configured corner. Go fullscreen → it is still there. With Macget quit, clicking reports **Macget not connected**. |
| Worker sleep (the regression this guards) | `chrome://serviceworker-internals` → **Stop** the worker → start a download in a **background** tab → it must be **captured**, not silently dropped. |
| Options | Every control persists across a reload; Diagnostics → **Check connection** reflects Macget actually running or not. |

## Notes & limits

- **Cookies** are read for the download URL and sent so authenticated downloads work.
  Macget keeps them in memory for the transfer and **never writes them to disk**
  (`queue.json` is redacted). Some sites with extra anti-bot protection may still
  fail — those fall back to downloading in the browser.
- **The popup cannot show download progress.** `MacgetCaptureHost` is a one-shot
  process that writes a file and exits, so there is no channel for Macget to report
  back over. The Recent list says what was *sent*, not how far along it is.
- **The connection check needs a current Macget build.** The `kind:"ping"` branch
  lives in `MacgetCaptureHost/main.swift`. An older host drops the ping into the
  inbox instead, where `CaptureInbox` fails to decode it and discards it with a log
  line — harmless, and the ping still proves the host binary exists.
- The Chromium extension ID is pinned via a public `key` in the manifest. The matching
  private key (used only to publish a `.crx`/store build) is kept out of the repo.
- Safari is not supported yet — it requires a Safari App Extension bundled and signed
  with an Apple Developer team.
