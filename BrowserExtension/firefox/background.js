// Macget Download Capture — background service worker / event page.
//
// Three responsibilities:
//   1. Capture browser file downloads (downloads.onCreated) and hand them to the
//      native-messaging host, cancelling the browser copy only after the host acks.
//   2. Capture media (video) on user request from the content script's in-page
//      button — sent to the host as a `kind:"media"` payload for yt-dlp.
//   3. Filter movie-proxy "jumplinks": popunder/redirect/shortener downloads that
//      fire without a real user gesture are dropped instead of captured.
//
// Storm safeguards on the file path: per-URL dedupe + a circuit breaker.
//
// Promise-based API root (`browser`/`chrome`) so one file works across
// Chrome, Edge, Brave, and Firefox.

const api = globalThis.browser || globalThis.chrome;
const HOST = "com.suryansh.macget";

const DEFAULTS = {
  enabled: true,
  denylist: [],
  minSizeBytes: 0,
  jumplinkFilterEnabled: true,
  gestureWindowMs: 2000,
};

// Dedupe: url -> last-handoff timestamp.
const recentByUrl = new Map();
const DEDUPE_MS = 15000;

// Circuit breaker: cap handoffs per rolling window.
const BREAKER_WINDOW_MS = 10000;
const BREAKER_MAX = 25;
let windowStart = Date.now();
let windowCount = 0;

// Live, in-memory signals (lost when an MV3 worker sleeps; refilled by events).
const lastGestureByTab = new Map();   // tabId -> timestamp of last trusted gesture
const sniffedByTab = new Map();       // tabId -> Set of HLS/DASH manifest URLs

// ---- jumplink heuristics ---------------------------------------------------
const SHORTENER_HOSTS = [
  "bit.ly", "t.co", "tinyurl.com", "cutt.ly", "ow.ly", "is.gd", "buff.ly",
  "rb.gy", "shorturl.at", "rebrand.ly", "linktr.ee", "adf.ly", "shrtfly.com",
  "ouo.io", "exe.io", "gplinks.in", "za.gl", "clk.sh",
];
// Common ad/redirect networks movie-proxy sites bounce downloads through.
const PROXY_AD_HOSTS = [
  "doubleclick.net", "popads.net", "popcash.net", "propellerads.com",
  "adsterra.com", "hilltopads.net", "clickadu.com", "juicyads.com",
  "exoclick.com", "trafficjunky.net", "mgid.com", "revcontent.com",
];
const REDIRECT_RE = /([?&](url|u|go|to|dest|destination|redirect|out|target|link)=)|\/(redirect|out|away|goto|jump|click|linkout)(\/|\?|$)/i;

function matchesHost(host, list) {
  return list.some((h) => host === h || host.endsWith("." + h));
}

function looksLikeJumplink(url, referrer) {
  const host = hostnameOf(url);
  if (!host) return false;
  if (matchesHost(host, SHORTENER_HOSTS)) return true;
  if (matchesHost(host, PROXY_AD_HOSTS)) return true;
  if (REDIRECT_RE.test(url)) return true;
  return false;
}

// True when this auto-started download looks like a drive-by / popunder jumplink.
async function shouldDropAsJumplink(item, cfg) {
  if (cfg.jumplinkFilterEnabled === false) return false;
  const url = item.finalUrl || item.url;

  // High-confidence: shortener / ad-redirect host or redirect-shaped URL.
  if (looksLikeJumplink(url, item.referrer)) {
    console.debug("Macget: dropped jumplink (denylist/redirect):", url);
    return true;
  }

  const tabId = item.tabId;
  if (tabId == null || tabId < 0) return false;

  const window = cfg.gestureWindowMs || 2000;
  const last = lastGestureByTab.get(tabId) || 0;
  if (Date.now() - last <= window) return false; // a real click preceded it

  // No recent gesture. If the tab was spawned by another (popunder) or isn't the
  // foreground tab, treat the download as an unsolicited jumplink.
  try {
    const tab = await api.tabs.get(tabId);
    if (tab && (tab.openerTabId != null || tab.active === false)) {
      console.debug("Macget: dropped drive-by/popunder download:", url);
      return true;
    }
  } catch (_) {}
  return false;
}

// ---- shared helpers --------------------------------------------------------
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
  for (const [u, t] of recentByUrl) {
    if (now - t > DEDUPE_MS) recentByUrl.delete(u);
  }
  return recentByUrl.has(url);
}

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

// ---- file downloads --------------------------------------------------------
api.downloads.onCreated.addListener(async (item) => {
  const cfg = await getConfig();
  if (!cfg.enabled) return;

  const url = item.finalUrl || item.url;
  if (!isCapturable(url)) return; // skip blob:/data:/extension: — Macget can't re-fetch those

  const host = hostnameOf(url);
  if (Array.isArray(cfg.denylist) && cfg.denylist.some((d) => d && host.endsWith(d))) return;

  if (await shouldDropAsJumplink(item, cfg)) return;

  const size = item.totalBytes && item.totalBytes > 0 ? item.totalBytes : (item.fileSize || 0);
  if (cfg.minSizeBytes > 0 && size > 0 && size < cfg.minSizeBytes) return;

  const now = Date.now();
  if (seenRecently(url, now)) return;          // same URL already handed off — ignore the retry
  if (!(await breakerAllows(now))) return;      // runaway burst — capture disabled
  recentByUrl.set(url, now);                     // mark before the async gap so concurrent events dedupe

  const cookie = await cookieHeaderFor(url);
  const payload = {
    kind: "file",
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

// ---- media (video) downloads ----------------------------------------------
async function handleMediaRequest(msg, sender) {
  const pageUrl = msg.pageUrl;
  if (!isCapturable(pageUrl)) return;

  const tabId = sender && sender.tab ? sender.tab.id : undefined;
  const manifests = (tabId != null && sniffedByTab.has(tabId))
    ? Array.from(sniffedByTab.get(tabId)) : [];
  const cookie = await cookieHeaderFor(pageUrl);

  const payload = {
    kind: "media",
    url: pageUrl,                 // the app validates this as the page URL
    pageURL: pageUrl,
    title: msg.title || undefined,
    manifestURLs: manifests.length ? manifests : undefined,
    referer: pageUrl,
    userAgent: navigator.userAgent,
    cookie: cookie || undefined,
    origin: hostnameOf(pageUrl) || undefined,
  };

  try {
    await api.runtime.sendNativeMessage(HOST, payload);
  } catch (e) {
    console.warn("Macget media host unavailable:", e && e.message);
  }
}

api.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || !msg.type) return;
  if (msg.type === "macget-gesture") {
    if (sender && sender.tab && sender.tab.id != null) {
      lastGestureByTab.set(sender.tab.id, Date.now());
    }
    return;
  }
  if (msg.type === "macget-media") {
    handleMediaRequest(msg, sender);
  }
});

// ---- HLS/DASH sniffing -----------------------------------------------------
const MANIFEST_RE = /\.(m3u8|mpd)(\?|$)/i;
try {
  api.webRequest.onBeforeRequest.addListener(
    (details) => {
      if (details.type === "main_frame") {
        // New page load in this tab — reset its sniffed manifests.
        if (details.tabId >= 0) sniffedByTab.delete(details.tabId);
        return;
      }
      if (details.tabId < 0 || !MANIFEST_RE.test(details.url)) return;
      let set = sniffedByTab.get(details.tabId);
      if (!set) { set = new Set(); sniffedByTab.set(details.tabId, set); }
      set.add(details.url);
      if (set.size > 20) set.delete(set.values().next().value); // cap memory
    },
    { urls: ["<all_urls>"] }
  );
} catch (e) {
  console.warn("Macget: webRequest sniffing unavailable:", e && e.message);
}

api.tabs.onRemoved.addListener((tabId) => {
  sniffedByTab.delete(tabId);
  lastGestureByTab.delete(tabId);
});
