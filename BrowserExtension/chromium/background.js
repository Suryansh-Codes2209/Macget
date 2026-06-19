// Macget Download Capture — background service worker / event page.
//
// On a new browser download we collect the URL plus the context Macget needs to
// re-fetch it (cookies, referrer, user-agent), hand it to the native-messaging
// host, and ONLY cancel the browser's own download once the host acknowledges.
// That ordering means a missing/disabled host never makes a download vanish.
//
// Uses the promise-based API root (`browser` on Firefox, `chrome` on Chrome MV3)
// so a single file works across Chrome, Edge, Brave, and Firefox.

const api = globalThis.browser || globalThis.chrome;
const HOST = "com.suryansh.macget";

const DEFAULTS = { enabled: true, denylist: [], minSizeBytes: 0 };

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
