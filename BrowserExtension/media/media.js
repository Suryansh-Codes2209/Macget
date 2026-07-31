// MacGet media capture — FIREFOX ONLY. Never packaged for Chrome.
//
// Loaded after shared/background.js, in the same global scope, so it can call
// the core helpers directly (sendToMacget, recordHistory, flashBadge, notify,
// getConfig, breakerAllows, recentByUrl, cookieHeaderFor, hostnameOf).
//
// It registers itself through the core's extension points rather than the core
// branching on a media kind:
//
//   MACGET_EXTRA_DEFAULTS   extra settings keys getConfig() should read
//   MACGET_MENUS            context menu entries, appended before installMenus()
//   MACGET_MENU_HANDLERS    id -> click handler
//   MACGET_MESSAGE_HANDLERS type -> onMessage handler
//   MACGET_TAB_CLEANUP      per-tab teardown
//
// The core has no media-shaped seam and no idea this file exists. That is
// deliberate: the Chrome package must contain no extraction code, and absence
// is easier to prove than intent. See docs/superpowers/specs/
// 2026-07-31-chrome-safe-extension-split-design.md.

"use strict";

// ---- settings ---------------------------------------------------------------

Object.assign(globalThis.MACGET_EXTRA_DEFAULTS, {
  showVideoButton: true,
  videoButtonCorner: "top-right",
  videoButtonHiddenHosts: [],
});

// ---- HLS/DASH sniffing ------------------------------------------------------
// Best-effort hints for the extractor, kept per tab.

const sniffedByTab = new Map();
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
  console.warn("MacGet: webRequest sniffing unavailable:", e && e.message);
}

globalThis.MACGET_TAB_CLEANUP.push((tabId) => sniffedByTab.delete(tabId));

// ---- capture ----------------------------------------------------------------

/**
 * Send one page to Macget for extraction.
 *
 * Carries its own dedupe / breaker / history / notify wrapper rather than
 * sharing the core's captureURL. The duplication is the point: it keeps every
 * media-specific line inside this file.
 */
async function captureMedia(pageUrl, { title, tabId } = {}) {
  if (!isCapturable(pageUrl)) {
    return { ok: false, error: "MacGet can only download http and https links." };
  }

  const now = Date.now();
  if (!(await breakerAllows(now))) {
    return { ok: false, error: "Capture is off — too many downloads at once." };
  }
  recentByUrl.set(pageUrl, now);

  const host = hostnameOf(pageUrl);
  const cookie = await cookieHeaderFor(pageUrl);
  const manifests = (tabId != null && sniffedByTab.has(tabId))
    ? Array.from(sniffedByTab.get(tabId))
    : [];

  const payload = {
    kind: "media",
    url: pageUrl,
    pageURL: pageUrl,
    title: title || undefined,
    referer: pageUrl,
    userAgent: navigator.userAgent,
    cookie: cookie || undefined,
    origin: host || undefined,
  };
  if (manifests.length) payload.manifestURLs = manifests;

  const result = await sendToMacget(payload);

  await recordHistory({
    kind: "media",
    url: pageUrl,
    filename: title || pageUrl,
    host,
    at: Date.now(),
    ok: result.ok,
  });

  if (result.ok) {
    await flashBadge(true);
    await notify("Sent to MacGet", title || host || pageUrl);
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

// ---- registration -----------------------------------------------------------

globalThis.MACGET_MENUS.push(
  { id: "macget-media", title: "Download media with MacGet", contexts: ["video", "audio"] },
  { id: "macget-page", title: "Send this page's video to MacGet", contexts: ["page"] }
);

Object.assign(globalThis.MACGET_MENU_HANDLERS, {
  "macget-media": (info, tab, tabId) =>
    captureMedia(info.pageUrl, { title: tab && tab.title, tabId }),
  "macget-page": (info, tab, tabId) =>
    captureMedia(info.pageUrl, { title: tab && tab.title, tabId }),
});

Object.assign(globalThis.MACGET_MESSAGE_HANDLERS, {
  "macget-media": (msg, sender, sendResponse, tabId) => {
    captureMedia(msg.pageUrl, { title: msg.title, tabId })
      .then(sendResponse)
      .catch((e) => sendResponse({ ok: false, error: String(e) }));
    return true; // async reply
  },

  "macget-video-prefs": (msg, sender, sendResponse) => {
    getConfig()
      .then((cfg) => sendResponse({
        showVideoButton: cfg.showVideoButton !== false,
        corner: cfg.videoButtonCorner || "top-right",
        hidden: matchesHost(msg.host || "", cfg.videoButtonHiddenHosts || []),
      }))
      .catch(() => sendResponse({ showVideoButton: true, corner: "top-right", hidden: false }));
    return true;
  },
});
