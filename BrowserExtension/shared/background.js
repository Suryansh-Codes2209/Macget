// MacGet Download Capture — background service worker / event page.
//
// Responsibilities:
//   1. Capture browser file downloads (downloads.onCreated) and hand them to the
//      native-messaging host, cancelling the browser copy only after the host acks.
//   2. Capture single targets on demand — context menus (link/image) and the
//      popup's this-tab action.
//   3. Filter movie-proxy "jumplinks": popunder/redirect/shortener downloads that
//      fire without a real user gesture are dropped instead of captured.
//   4. Report health. The host is pinged, the result drives the toolbar badge and
//      the popup's connection state, and every failure is recorded rather than
//      logged and forgotten.
//
// This file is the shared core and ships to every browser. It handles files the
// user downloads and nothing else — it has no page-scraping, no stream
// detection, and no site-specific behaviour. Features that go beyond that live
// in ../media/ and are packaged for Firefox only; see BrowserExtension/README.md.
//
// Storm safeguards on the file path: per-URL dedupe + a circuit breaker.
//
// Promise-based API root (`browser`/`chrome`) so one file works across
// Chrome, Edge, Brave, and Firefox. Pure predicates live in heuristics.js —
// Chrome pulls it in with importScripts, Firefox lists it in background.scripts.

if (typeof importScripts === "function" && typeof looksLikeJumplink === "undefined") {
  importScripts("heuristics.js");
}

const api = globalThis.browser || globalThis.chrome;
const HOST = "com.suryansh.macget";

// Settings the user controls. Deliberately excludes `history` — this object is
// read on every single download, and history is written far less often than it
// is read past.
const DEFAULTS = {
  enabled: true,
  denylist: [],
  minSizeBytes: 0,
  jumplinkFilterEnabled: true,
  gestureWindowMs: 2000,
  notificationsEnabled: true,
  badgeEnabled: true,
};

// Optional feature modules loaded after this file (Firefox only) register extra
// setting defaults here, so getConfig() reads them without core knowing what
// they are.
const EXTRA_DEFAULTS = (globalThis.MACGET_EXTRA_DEFAULTS = globalThis.MACGET_EXTRA_DEFAULTS || {});

const HISTORY_KEY = "history";
const HISTORY_CAP = 20;

// Dedupe: url -> last-handoff timestamp.
const recentByUrl = new Map();
const DEDUPE_MS = 15000;

// Circuit breaker: cap handoffs per rolling window.
const BREAKER_WINDOW_MS = 10000;
const BREAKER_MAX = 25;
let windowStart = Date.now();
let windowCount = 0;

// When this worker instance started. Used to fail the gesture filter open right
// after a cold start — see shouldDropAsJumplink.
const WORKER_STARTED_AT = Date.now();
const GESTURE_GRACE_MS = 10000;

const HEALTH_TTL_MS = 30000;
const UNREACHABLE_NOTIFY_EVERY_MS = 10 * 60 * 1000;
const BADGE_FLASH_MS = 3000;

// ---- session-backed state --------------------------------------------------
// An MV3 service worker is evicted aggressively. Anything the capture decision
// depends on has to survive that eviction, so it lives in storage.session
// (cleared when the browser closes, never written to disk) with an in-memory
// mirror for speed.

const sessionArea = api.storage.session || api.storage.local;

/** tabId -> timestamp of the last trusted user gesture in that tab. */
let lastGestureByTab = new Map();
let gestureFlushTimer = null;

const gesturesReady = (async () => {
  try {
    const stored = await sessionArea.get({ gestures: {} });
    for (const [tabId, ts] of Object.entries(stored.gestures || {})) {
      lastGestureByTab.set(Number(tabId), ts);
    }
  } catch (_) { /* first run, or session storage unavailable */ }
})();

function noteGesture(tabId) {
  lastGestureByTab.set(tabId, Date.now());
  // Content scripts throttle to one message per 400ms per tab; debounce the
  // write so a busy page does not thrash session storage.
  if (gestureFlushTimer) return;
  gestureFlushTimer = setTimeout(async () => {
    gestureFlushTimer = null;
    const cutoff = Date.now() - 60 * 60 * 1000;
    const out = {};
    for (const [id, ts] of lastGestureByTab) {
      if (ts >= cutoff) out[id] = ts; else lastGestureByTab.delete(id);
    }
    try { await sessionArea.set({ gestures: out }); } catch (_) {}
  }, 1000);
}

// ---- health ----------------------------------------------------------------

let health = { state: "unknown", checkedAt: 0, lastError: null, hostVersion: null };

async function publishHealth() {
  try { await sessionArea.set({ health }); } catch (_) {}
  await refreshBadge();
}

/**
 * Ask the host whether it is there. The host answers a `kind:"ping"` message
 * without writing an inbox file and without launching Macget — opening the
 * popup must not start the app.
 *
 * An older host that predates the ping branch will drop the message into the
 * inbox instead; Macget's CaptureInbox fails to decode it as a CaptureRequest
 * and discards it with a log line, so the ping is still safe (and still proves
 * the host binary exists, which is what we are asking).
 */
async function pingHost(force) {
  const now = Date.now();
  if (!force && health.state !== "unknown" && now - health.checkedAt < HEALTH_TTL_MS) {
    return health;
  }
  try {
    const reply = await api.runtime.sendNativeMessage(HOST, { kind: "ping" });
    health = {
      state: "connected",
      checkedAt: now,
      lastError: null,
      hostVersion: reply && reply.version ? reply.version : null,
    };
  } catch (e) {
    health = {
      state: "unreachable",
      checkedAt: now,
      lastError: (e && e.message) || String(e),
      hostVersion: null,
    };
  }
  await publishHealth();
  return health;
}

/**
 * Send one payload to the host. The single choke point for native messaging:
 * every capture path goes through here, so health, badge, and error recording
 * stay consistent no matter which path fired.
 */
async function sendToMacget(payload) {
  try {
    const response = await api.runtime.sendNativeMessage(HOST, payload);
    if (health.state !== "connected") {
      health = { state: "connected", checkedAt: Date.now(), lastError: null, hostVersion: health.hostVersion };
      await publishHealth();
    } else {
      health.checkedAt = Date.now();
    }
    return { ok: !!(response && response.ok), response };
  } catch (e) {
    const message = (e && e.message) || String(e);
    health = { state: "unreachable", checkedAt: Date.now(), lastError: message, hostVersion: null };
    await publishHealth();
    await notifyUnreachable();
    console.warn("MacGet: native host unavailable:", message);
    return { ok: false, error: message };
  }
}

// ---- badge -----------------------------------------------------------------

const action = api.action || api.browserAction;
let badgeFlashTimer = null;

async function setBadge(text, color) {
  if (!action) return;
  try {
    await action.setBadgeText({ text });
    if (text && color) await action.setBadgeBackgroundColor({ color });
  } catch (_) {}
}

/** Steady-state badge: red "!" while the host is unreachable, otherwise clear. */
async function refreshBadge() {
  const cfg = await getConfig();
  if (!cfg.badgeEnabled) return setBadge("", null);
  if (badgeFlashTimer) return; // a flash is showing; it will settle back here
  if (health.state === "unreachable") return setBadge("!", "#D0342C");
  return setBadge("", null);
}

/**
 * Flash a capture confirmation. setTimeout does not survive worker eviction, so
 * a flash can in principle outlive its timer — refreshBadge() runs on worker
 * start, which settles any badge left stranded that way.
 */
async function flashBadge(ok) {
  const cfg = await getConfig();
  if (!cfg.badgeEnabled) return;
  await setBadge(ok ? "✓" : "!", ok ? "#1A9D4B" : "#D0342C");
  if (badgeFlashTimer) clearTimeout(badgeFlashTimer);
  badgeFlashTimer = setTimeout(async () => {
    badgeFlashTimer = null;
    await refreshBadge();
  }, BADGE_FLASH_MS);
}

// ---- notifications ---------------------------------------------------------

async function notify(title, message) {
  const cfg = await getConfig();
  if (!cfg.notificationsEnabled || !api.notifications) return;
  try {
    await api.notifications.create({
      type: "basic",
      iconUrl: api.runtime.getURL("icons/icon-128.png"),
      title,
      message,
    });
  } catch (_) {}
}

/**
 * "Macget isn't connected", at most once per 10 minutes. Without the rate limit
 * a dead host would fire one notification per download on a page full of them.
 */
async function notifyUnreachable() {
  let last = 0;
  try {
    const stored = await sessionArea.get({ unreachableNotifiedAt: 0 });
    last = stored.unreachableNotifiedAt || 0;
  } catch (_) {}
  const now = Date.now();
  if (now - last < UNREACHABLE_NOTIFY_EVERY_MS) return;
  try { await sessionArea.set({ unreachableNotifiedAt: now }); } catch (_) {}
  await notify(
    "MacGet isn't connected",
    "The download stayed in your browser. Turn on Browser integration in Macget → Settings."
  );
}

// ---- history ---------------------------------------------------------------

// Read-modify-write serialised through a promise chain: two downloads finishing
// at once would otherwise interleave and lose an entry.
let historyChain = Promise.resolve();

function recordHistory(entry) {
  historyChain = historyChain.then(async () => {
    try {
      const stored = await api.storage.local.get({ [HISTORY_KEY]: [] });
      const next = pushHistory(stored[HISTORY_KEY], entry, HISTORY_CAP);
      await api.storage.local.set({ [HISTORY_KEY]: next });
    } catch (_) {}
  });
  return historyChain;
}

// ---- shared helpers --------------------------------------------------------

async function getConfig() {
  const wanted = Object.assign({}, DEFAULTS, EXTRA_DEFAULTS);
  try {
    return await api.storage.local.get(wanted);
  } catch (_) {
    return wanted;
  }
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
      `MacGet capture: ${windowCount} downloads in ${BREAKER_WINDOW_MS / 1000}s — ` +
      "looks like a retry loop. Turning capture OFF."
    );
    try { await api.storage.local.set({ enabled: false }); } catch (_) {}
    await notify(
      "MacGet turned capture off",
      "A page tried to start more than 25 downloads in 10 seconds. Turn capture back on in the MacGet popup once it stops."
    );
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

// ---- jumplink filter -------------------------------------------------------

/** True when this auto-started download looks like a drive-by / popunder jumplink. */
async function shouldDropAsJumplink(item, cfg) {
  if (cfg.jumplinkFilterEnabled === false) return false;
  const url = item.finalUrl || item.url;

  // High-confidence: shortener / ad-redirect host or redirect-shaped URL. This
  // branch needs no gesture history, so it stays authoritative at all times.
  if (looksLikeJumplink(url)) {
    console.debug("MacGet: dropped jumplink (denylist/redirect):", url);
    return true;
  }

  const tabId = item.tabId;
  if (tabId == null || tabId < 0) return false;

  // Everything below infers intent from gesture history, which a freshly-woken
  // worker does not have. Failing closed there would silently eat downloads the
  // user actually asked for, so within the grace window we fail OPEN: capture it
  // and let the user cancel, rather than drop it and say nothing.
  if (Date.now() - WORKER_STARTED_AT < GESTURE_GRACE_MS) return false;

  await gesturesReady;
  const window = cfg.gestureWindowMs || 2000;
  const last = lastGestureByTab.get(tabId) || 0;
  if (Date.now() - last <= window) return false; // a real click preceded it

  // No recent gesture. If the tab was spawned by another (popunder) or isn't the
  // foreground tab, treat the download as an unsolicited jumplink.
  try {
    const tab = await api.tabs.get(tabId);
    if (tab && (tab.openerTabId != null || tab.active === false)) {
      console.debug("MacGet: dropped drive-by/popunder download:", url);
      return true;
    }
  } catch (_) {}
  return false;
}

// ---- file downloads --------------------------------------------------------

api.downloads.onCreated.addListener(async (item) => {
  const cfg = await getConfig();
  if (!cfg.enabled) return;

  const url = item.finalUrl || item.url;
  if (!isCapturable(url)) return; // skip blob:/data:/extension: — Macget can't re-fetch those

  const host = hostnameOf(url);
  if (isDenied(host, cfg.denylist)) return;

  if (await shouldDropAsJumplink(item, cfg)) return;

  const size = item.totalBytes && item.totalBytes > 0 ? item.totalBytes : (item.fileSize || 0);
  if (cfg.minSizeBytes > 0 && size > 0 && size < cfg.minSizeBytes) return;

  const now = Date.now();
  if (seenRecently(url, now)) return;          // same URL already handed off — ignore the retry
  if (!(await breakerAllows(now))) return;      // runaway burst — capture disabled
  recentByUrl.set(url, now);                     // mark before the async gap so concurrent events dedupe

  const filename = item.filename ? item.filename.split(/[\\/]/).pop() : filenameFromUrl(url);
  const cookie = await cookieHeaderFor(url);
  const payload = {
    kind: "file",
    url,
    filename: filename || undefined,
    referer: item.referrer || undefined,
    userAgent: navigator.userAgent,
    cookie: cookie || undefined,
    mimeType: item.mime || undefined,
    totalBytes: size > 0 ? size : undefined,
    origin: host || undefined,
  };

  const result = await sendToMacget(payload);

  await recordHistory({
    kind: "file",
    url,
    filename: filename || url,
    host,
    at: Date.now(),
    ok: result.ok,
    bytes: size > 0 ? size : undefined,
  });

  if (result.ok) {
    // Cancel the browser's copy only now — a missing or disabled host must never
    // make a download disappear.
    try { await api.downloads.cancel(item.id); } catch (_) { /* may have finished */ }
    try { await api.downloads.erase({ id: item.id }); } catch (_) { /* best-effort cleanup */ }
    await flashBadge(true);
    await notify("Sent to MacGet", filename || host || url);
  } else {
    await flashBadge(false);
  }
});

// ---- on-demand single-target capture ---------------------------------------

/**
 * Capture one URL the user explicitly asked for (context menu, popup button).
 * Skips the size filter and the jumplink filter — both exist to judge downloads
 * that started on their own, and this one did not.
 */
async function captureURL(url, { referer, tabId } = {}) {
  if (!isCapturable(url)) {
    return { ok: false, error: "MacGet can only download http and https links." };
  }

  const now = Date.now();
  if (!(await breakerAllows(now))) {
    return { ok: false, error: "Capture is off — too many downloads at once." };
  }
  recentByUrl.set(url, now);

  const host = hostnameOf(url);
  const cookie = await cookieHeaderFor(url);
  const filename = filenameFromUrl(url);

  const payload = {
    kind: "file",
    url,
    filename,
    referer: referer || undefined,
    userAgent: navigator.userAgent,
    cookie: cookie || undefined,
    origin: host || undefined,
  };

  const result = await sendToMacget(payload);

  await recordHistory({
    kind: "file",
    url,
    filename: filename || url,
    host,
    at: Date.now(),
    ok: result.ok,
  });

  if (result.ok) {
    await flashBadge(true);
    await notify("Sent to MacGet", filename || host || url);
    return { ok: true };
  }
  await flashBadge(false);
  return {
    ok: false,
    error: result.error
      ? "MacGet isn't connected. Turn on Browser integration in Macget → Settings."
      : "Macget refused the download.",
  };
}

// ---- context menus ---------------------------------------------------------

// Feature modules loaded after this file may push their own entries before
// installMenus() first runs (it fires only on onInstalled / onStartup).
const MENUS = (globalThis.MACGET_MENUS = globalThis.MACGET_MENUS || []);
MENUS.push(
  { id: "macget-link", title: "Download link with MacGet", contexts: ["link"] },
  { id: "macget-image", title: "Download image with MacGet", contexts: ["image"] }
);

/**
 * Chrome's contextMenus.removeAll takes a callback and returns undefined;
 * Firefox's returns a Promise and ignores the callback. Handling only one of
 * those means the menus never appear on the other browser, so handle both and
 * guard against being run twice.
 */
function installMenus() {
  if (!api.contextMenus) return;
  let created = false;
  const create = () => {
    if (created) return;
    created = true;
    for (const m of MENUS) {
      try { api.contextMenus.create(m); } catch (_) {}
    }
  };
  try {
    const pending = api.contextMenus.removeAll(create);
    if (pending && typeof pending.then === "function") pending.then(create, create);
  } catch (_) {
    create();
  }
}

api.runtime.onInstalled.addListener(installMenus);
if (api.runtime.onStartup) api.runtime.onStartup.addListener(installMenus);

/** Menu id -> handler, for entries a feature module added to MENUS. */
const MENU_HANDLERS = (globalThis.MACGET_MENU_HANDLERS = globalThis.MACGET_MENU_HANDLERS || {});

if (api.contextMenus) {
  api.contextMenus.onClicked.addListener(async (info, tab) => {
    const tabId = tab && tab.id != null ? tab.id : undefined;
    const custom = MENU_HANDLERS[info.menuItemId];
    if (custom) {
      await custom(info, tab, tabId);
      return;
    }
    const target = info.linkUrl || info.srcUrl;
    if (!target) return;
    await captureURL(target, { referer: info.pageUrl, tabId });
  });
}

// ---- messaging -------------------------------------------------------------

/**
 * message type -> (msg, sender, sendResponse, tabId) => truthy for an async
 * reply, matching the onMessage contract. Feature modules register here.
 */
const MESSAGE_HANDLERS = (globalThis.MACGET_MESSAGE_HANDLERS = globalThis.MACGET_MESSAGE_HANDLERS || {});

api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || !msg.type) return;
  const tabId = sender && sender.tab ? sender.tab.id : undefined;

  switch (msg.type) {
    case "macget-gesture":
      if (tabId != null) noteGesture(tabId);
      return; // no reply needed

    case "macget-capture-url":
      captureURL(msg.url, { referer: msg.referer, tabId: msg.tabId })
        .then(sendResponse)
        .catch((e) => sendResponse({ ok: false, error: String(e) }));
      return true; // async reply

    case "macget-health":
      pingHost(msg.force === true)
        .then(sendResponse)
        .catch(() => sendResponse(health));
      return true;

    default: {
      const handler = MESSAGE_HANDLERS[msg.type];
      return handler ? handler(msg, sender, sendResponse, tabId) : undefined;
    }
  }
});

// Tab teardown. Feature modules append their own per-tab cleanup here.
const TAB_CLEANUP = (globalThis.MACGET_TAB_CLEANUP = globalThis.MACGET_TAB_CLEANUP || []);

api.tabs.onRemoved.addListener((tabId) => {
  lastGestureByTab.delete(tabId);
  for (const fn of TAB_CLEANUP) {
    try { fn(tabId); } catch (_) {}
  }
});

// ---- startup ---------------------------------------------------------------
// Settle any badge stranded by a worker eviction mid-flash, then take a first
// health reading so the popup has something real to show when it opens.
refreshBadge();
pingHost(true);
