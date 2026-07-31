// MacGet extension — pure logic, no browser APIs.
//
// Everything here is a plain function over plain data. That is the point: this
// is the part of the extension where the subtle bugs live (host-suffix matching,
// jumplink classification, buffer bounds), and keeping it free of `chrome`/
// `browser` access is what makes it testable under `node --test`.
//
// Loaded three ways, which is why it defines globals rather than using ES modules:
//   Chrome   — importScripts("heuristics.js") from the MV3 service worker
//   Firefox  — first entry in manifest background.scripts
//   Node     — require()d by test/, via the module.exports guard at the bottom

"use strict";

// ---- jumplink corpora -------------------------------------------------------
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

const REDIRECT_RE =
  /([?&](url|u|go|to|dest|destination|redirect|out|target|link)=)|\/(redirect|out|away|goto|jump|click|linkout)(\/|\?|$)/i;

// ---- URL predicates ---------------------------------------------------------

/** Hostname of `url`, or "" when it does not parse. */
function hostnameOf(url) {
  try {
    return new URL(url).hostname;
  } catch (_) {
    return "";
  }
}

/**
 * Suffix-aware host match. `sub.bit.ly` matches `bit.ly`; `evil-bit.ly` does
 * not — the boundary dot is required, otherwise any host merely *ending* in the
 * listed string would be blocked.
 */
function matchesHost(host, list) {
  if (!host || !Array.isArray(list)) return false;
  const h = host.toLowerCase();
  return list.some((entry) => {
    if (!entry) return false;
    const e = String(entry).toLowerCase().replace(/^\.+/, "");
    return h === e || h.endsWith("." + e);
  });
}

/** Only http(s) is capturable — Macget cannot re-fetch blob:/data:/extension:. */
function isCapturable(url) {
  return /^https?:\/\//i.test(url || "");
}

/** High-confidence drive-by shapes: shortener host, ad network, redirect URL. */
function looksLikeJumplink(url) {
  const host = hostnameOf(url);
  if (!host) return false;
  if (matchesHost(host, SHORTENER_HOSTS)) return true;
  if (matchesHost(host, PROXY_AD_HOSTS)) return true;
  return REDIRECT_RE.test(url);
}

/** True when the user has explicitly denylisted this host. */
function isDenied(host, denylist) {
  return matchesHost(host, denylist || []);
}

/**
 * Best-effort filename from a URL, for capture paths that have no download item
 * to read one from (context menus). Returns undefined rather than a guess when
 * the path has no usable last segment — Macget's own resolver is better at this
 * than we are, and an empty string would override it.
 */
function filenameFromUrl(url) {
  try {
    const path = new URL(url).pathname;
    const last = decodeURIComponent(path.split("/").filter(Boolean).pop() || "");
    return last && last !== "/" ? last : undefined;
  } catch (_) {
    return undefined;
  }
}

// ---- history ----------------------------------------------------------------

/**
 * Prepend `entry` to `list` and clamp to `cap`, newest first. Returns a new
 * array; never mutates the input, so callers can write it straight back to
 * storage without aliasing surprises.
 */
function pushHistory(list, entry, cap) {
  const limit = Number.isFinite(cap) && cap > 0 ? cap : 20;
  const next = [entry].concat(Array.isArray(list) ? list : []);
  return next.slice(0, limit);
}

// ---- display formatters -----------------------------------------------------

function formatBytes(n) {
  if (!Number.isFinite(n) || n <= 0) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = n;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i += 1;
  }
  const rounded = value >= 100 || i === 0 ? Math.round(value) : Math.round(value * 10) / 10;
  return `${rounded} ${units[i]}`;
}

/** Compact relative time for the recent-captures list. */
function relativeTime(then, now) {
  const delta = Math.max(0, (now || 0) - (then || 0));
  const sec = Math.floor(delta / 1000);
  if (sec < 45) return "just now";
  const min = Math.floor(sec / 60);
  if (min < 60) return `${Math.max(1, min)}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  return day < 7 ? `${day}d ago` : `${Math.floor(day / 7)}w ago`;
}

// Node test harness only; browsers ignore this and use the globals above.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    SHORTENER_HOSTS,
    PROXY_AD_HOSTS,
    REDIRECT_RE,
    hostnameOf,
    matchesHost,
    isCapturable,
    looksLikeJumplink,
    isDenied,
    filenameFromUrl,
    pushHistory,
    formatBytes,
    relativeTime,
  };
}
