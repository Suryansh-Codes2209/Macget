// Macget Download Capture — background service worker / event page.
//
// On a new browser download we collect the URL plus the context Macget needs to
// re-fetch it (cookies, referrer, user-agent), hand it to the native-messaging
// host, and ONLY cancel the browser's own download once the host acknowledges.
// That ordering means a missing/disabled host never makes a download vanish.
//
// Two safeguards prevent feedback storms: download pages that auto-retry after a
// cancellation can otherwise fire onCreated in a tight loop, spawning a host
// process each time and crashing the browser.
//   1. Per-URL dedupe — the same URL is handed off at most once per DEDUPE_MS.
//   2. Circuit breaker — if too many captures happen in BREAKER_WINDOW_MS, we
//      turn capture OFF and stop, so a runaway can never fork-bomb the machine.
//
// Uses the promise-based API root (`browser` on Firefox, `chrome` on Chrome MV3)
// so a single file works across Chrome, Edge, Brave, and Firefox.

const api = globalThis.browser || globalThis.chrome;
const HOST = "com.suryansh.macget";

const DEFAULTS = { enabled: true, denylist: [], minSizeBytes: 0 };

// Dedupe: url -> last-handoff timestamp.
const recentByUrl = new Map();
const DEDUPE_MS = 15000;

// Circuit breaker: cap handoffs per rolling window.
const BREAKER_WINDOW_MS = 10000;
const BREAKER_MAX = 25;
let windowStart = Date.now();
let windowCount = 0;

async function getConfig() {
  try {
    return await api.storage.local.get(DEFAULTS);
  } catch (_) {
    return DEFAULTS;
  }
}

function hostnameOf(url) {
  try { return new URL(url).hostname; } catch (_) { return ""; }
}

function isCapturable(url) {
  return /^https?:\/\//i.test(url || "");
}

function seenRecently(url, now) {
  // prune stale entries so the map can't grow unbounded
  for (const [u, t] of recentByUrl) {
    if (now - t > DEDUPE_MS) recentByUrl.delete(u);
  }
  return recentByUrl.has(url);
}

// Returns false (and disables capture) if we're in a runaway burst.
async function breakerAllows(now) {
  if (now - windowStart > BREAKER_WINDOW_MS) {
    windowStart = now;
    windowCount = 0;
  }
  windowCount += 1;
  if (windowCount > BREAKER_MAX) {
    console.error(
      `Macget capture: ${windowCount} downloads in ${BREAKER_WINDOW_MS / 1000}s — ` +
      "looks like a retry loop. Turning capture OFF. Re-enable it in the extension " +
      "options once the source page has stopped re-downloading."
    );
    try { await api.storage.local.set({ enabled: false }); } catch (_) {}
    return false;
  }
  return true;
}

async function cookieHeaderFor(url) {
  try {
    const cookies = await api.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch (_) {
    return "";
  }
}

api.downloads.onCreated.addListener(async (item) => {
  const cfg = await getConfig();
  if (!cfg.enabled) return;

  const url = item.finalUrl || item.url;
  if (!isCapturable(url)) return; // skip blob:/data:/extension: — Macget can't re-fetch those

  const host = hostnameOf(url);
  if (Array.isArray(cfg.denylist) && cfg.denylist.some((d) => d && host.endsWith(d))) return;

  const size = item.totalBytes && item.totalBytes > 0 ? item.totalBytes : (item.fileSize || 0);
  if (cfg.minSizeBytes > 0 && size > 0 && size < cfg.minSizeBytes) return;

  const now = Date.now();
  if (seenRecently(url, now)) return;          // same URL already handed off — ignore the retry
  if (!(await breakerAllows(now))) return;      // runaway burst — capture disabled
  recentByUrl.set(url, now);                     // mark before the async gap so concurrent events dedupe

  const cookie = await cookieHeaderFor(url);
  const payload = {
    url,
    filename: item.filename ? item.filename.split(/[\\/]/).pop() : undefined,
    referer: item.referrer || undefined,
    userAgent: navigator.userAgent,
    cookie: cookie || undefined,
    mimeType: item.mime || undefined,
    totalBytes: size > 0 ? size : undefined,
    origin: host || undefined,
  };

  let response;
  try {
    response = await api.runtime.sendNativeMessage(HOST, payload);
  } catch (e) {
    console.warn("Macget capture host unavailable:", e && e.message);
    return; // leave the browser download intact
  }

  if (response && response.ok) {
    try { await api.downloads.cancel(item.id); } catch (_) { /* may have finished */ }
    try { await api.downloads.erase({ id: item.id }); } catch (_) { /* best-effort cleanup */ }
  }
});
