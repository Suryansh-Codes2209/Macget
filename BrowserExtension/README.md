# MacGet Browser Capture Extension

Hands downloads you start in your browser to Macget, including the cookies/referrer
needed for logged-in downloads. Works with Chrome, Edge, Brave, and Firefox.

## Chrome and Firefox are not the same extension

The Chrome build captures **file downloads only**. It has no video overlay, no
media context menus, no stream detection, and no path to Macget's extractor —
that code is not merely disabled, it is not in the package.

The Chrome Web Store rejected v1.2 under its Prohibited Products policy for
facilitating downloads of copyrighted media from YouTube, an item-level
rejection. Firefox's add-on policies permit that class of extension, so the
Firefox build keeps it.

| | Chrome / Edge / Brave | Firefox |
|---|---|---|
| Capture browser downloads | ✅ | ✅ |
| Link / image context menus | ✅ | ✅ |
| Jumplink filtering | ✅ | ✅ |
| Cookies for authenticated downloads | ✅ | ✅ |
| Video overlay button | ❌ | ✅ |
| Media context menus, "Send video" | ❌ | ✅ |
| HLS/DASH detection, extractor handoff | ❌ | ✅ |
| `webRequest` permission | ❌ | ✅ |

Macget itself keeps media extraction on every platform — paste a page URL into
the app. Only the Chrome *extension* drops it.

**Do not upload a Chrome package until the appeal on case 2-7571000041635
resolves.** Republishing a removed item is itself a policy violation and
escalates to the developer account.

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

### Chrome / Edge / Brave (Web Store)

**Currently unavailable.** The listing at
`chromewebstore.google.com/detail/ldmhmgglgemkoogpokfcgplbpfokcejl` was removed —
see the policy note above. Install unpacked in the meantime.

### Chrome / Edge / Brave (unpacked)

1. Run `./build.sh` to assemble `build/chromium/`.
2. Go to `chrome://extensions` (or `edge://extensions`, `brave://extensions`).
3. Enable **Developer mode**.
4. **Load unpacked** → select the `build/chromium/` folder.
5. The extension ID must be `knccbiljmilfmhfellkfbdmilpbdkgni` (pinned by the
   `key` in `manifest.json`).

`NativeMessagingInstaller.chromiumExtensionIDs` lists both the old Web Store ID
and the unpacked ID; the host manifest trusts those two and nothing else. If a
new Web Store listing is ever approved, **its ID must be added there** or capture
fails silently with no user-visible error.

### Firefox (temporary add-on)

1. Run `./build.sh` to assemble `build/firefox/`.
2. Go to `about:debugging#/runtime/this-firefox`.
3. **Load Temporary Add-on** → select `build/firefox/manifest.json`.
   (Temporary add-ons are removed when Firefox restarts; for a permanent install,
   sign the `dist/macget-firefox.zip` via addons.mozilla.org.)

## Using it

**Toolbar popup** — connection state, the master capture toggle, this-tab actions,
and the last 8 captures. The connection state comes from an actual ping to the
native host, so “Not connected” means the plumbing is genuinely broken, not that a
checkbox is off.

**Right-click menus** — “Download link with MacGet” on a link, plus image targets.
On Firefox, also video and audio targets and “Send this page's video to MacGet,”
which hands the page URL to Macget's yt-dlp extractor. Anything you ask for by
hand skips the size and jumplink filters — those exist to judge downloads that
started on their own.

**Video button** *(Firefox only)* — hover a video player and a MacGet button
appears in the corner. It survives fullscreen and reports whether the handoff
actually worked.

**Options page** (toolbar popup → *All settings*, or the extension's Options) has
capture and filtering settings, video-button settings on Firefox, plus a
**Diagnostics** section: check the connection, see the extension ID and host name,
and read the last error verbatim. Start there when a download isn't being captured.

## Layout

```
shared/              media-free core. Ships to every browser.
  heuristics.js      pure logic: jumplink classification, host matching, formatting
  background.js      capture orchestration, health, badge, notifications, menus
  content.js         user-gesture reporting, and nothing else
  popup.html/.js     toolbar popup
  options.html/.js   settings page
  theme.css          shared tokens and controls
media/               FIREFOX ONLY. Never copied into the Chrome package.
  media.js           media menus/messages, HLS-DASH sniffing, captureMedia()
  content-video.js   the in-page video overlay
  media-ui.js        wires the two HTML fragments below
  popup-media.html   "Send video" button, spliced into shared/popup.html
  options-media.html "Video button" settings, spliced into shared/options.html
targets/             the one file that differs per browser
  chromium/manifest.json
  firefox/manifest.json
test/                node --test: heuristics + the Chrome no-media guard
build/               generated. build/chromium/ and build/firefox/ are loadable.
```

`heuristics.js` is loaded three ways, which is why it defines globals rather than
using ES modules: `importScripts()` from Chrome's service worker, the
`background.scripts` array on Firefox, and `require()` from the Node tests.

`media.js` registers itself through extension points the core exposes
(`MACGET_MENUS`, `MACGET_MESSAGE_HANDLERS`, `MACGET_EXTRA_DEFAULTS`,
`MACGET_TAB_CLEANUP`, `MACGET_OPTION_SECTIONS`) instead of the core branching on
a media kind. That is why `shared/` reads as a download-capture extension with no
removed feature — because it is one. It costs `media.js` a duplicated
dedupe/breaker/history wrapper around its own payload; that duplication is
deliberate.

## Building / packaging

```sh
./build.sh                       # assembles build/, verifies, writes dist/*.zip
node --test "test/*.test.js"     # both suites; the guard needs build.sh run first
node --test test/heuristics.test.js   # pure-logic tests alone
```

Quote the glob. `node --test test/` resolves the directory as a module path and
fails with `MODULE_NOT_FOUND` rather than scanning it.

`build.sh` copies `shared/` into both targets and `media/` into Firefox only,
splices the `<!--MEDIA-SECTION-->` marker in the two HTML files, then runs
`test/no-media-in-chrome.test.js` against the assembled Chrome package and
**fails the build** on any media identifier it finds. Adding a core file means
adding it to `CORE_JS` in `build.sh`, or both targets ship without it.

Note the direction of the HTML splice: it inserts into a media-free base rather
than cutting from a full one. If it ever breaks, Chrome stays clean and Firefox
loses a settings panel — the failure mode points the safe way.

## Testing

`heuristics.js` is the only file with no browser API access, and it is where the
subtle bugs live — host-suffix matching, jumplink classification, buffer bounds.
It is covered by `test/heuristics.test.js`.

`test/no-media-in-chrome.test.js` covers the policy guarantee: it walks the
assembled `build/chromium/` and fails on any media identifier, on `webRequest` in
the manifest, or on any content script beyond the gesture reporter. `build.sh`
runs it on every build.

Everything else needs a real browser. Manual matrix:

| Area | Check |
|---|---|
| Popup — connected | With Macget running and integration on, the pill reads **Active** and the hero glows amber. |
| Popup — not connected | Quit Macget / turn integration off → pill reads **Not connected**, hero glows red, **Check again** is offered. A started download stays in the browser. |
| Popup — paused | Toggle capture off → pill reads **Paused**; downloads stay in the browser. |
| Recent list | Capture something → it appears with host and relative time. A capture attempted while disconnected appears tagged **Not sent**. |
| Context menus | Right-click a link and an image — each sends and flashes the badge. On Firefox also a `<video>` and the page background. On Chrome those two entries must **not** exist. |
| Badge | ✓ flashes green after a capture; a red ! persists while the host is unreachable; both vanish when the badge option is off. |
| Notifications | One per capture; the "isn't connected" warning appears at most once per 10 minutes. |
| Video button (Firefox) | Hover a player → button appears in the configured corner. Go fullscreen → it is still there. With Macget quit, clicking reports **Macget not connected**. |
| Video button (Chrome) | Hover a player on any site → **no** button appears. The popup has no *Send video*, and Options has no *Video button* section. |
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
