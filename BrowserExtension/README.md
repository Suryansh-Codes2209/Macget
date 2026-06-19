# Macget Browser Capture Extension

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

## Extension options

Click the toolbar icon (or the extension’s Options) to:
- Turn capture on/off in the browser.
- Skip files smaller than N MB (0 = capture everything).
- Add domains to never capture (one per line).

## Building / packaging

```sh
./build.sh   # syncs shared JS into firefox/ and writes dist/macget-{chromium,firefox}.zip
```

`background.js`, `options.html`, and `options.js` live in `chromium/` as the single
source of truth; `build.sh` copies them into `firefox/`. Only `manifest.json` differs
per browser.

## Notes & limits

- **Cookies** are read for the download URL and sent so authenticated downloads work.
  Macget keeps them in memory for the transfer and **never writes them to disk**
  (`queue.json` is redacted). Some sites with extra anti-bot protection may still
  fail — those fall back to downloading in the browser.
- The Chromium extension ID is pinned via a public `key` in the manifest. The matching
  private key (used only to publish a `.crx`/store build) is kept out of the repo.
- Safari is not supported yet — it requires a Safari App Extension bundled and signed
  with an Apple Developer team.
