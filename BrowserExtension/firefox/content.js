// MacGet content script. Two jobs:
//   1. Overlay a "MacGet" button on the main <video> so the user can send the
//      current page to Macget for yt-dlp extraction (YouTube + generic sites).
//   2. Report trusted user gestures to the background script, which uses gesture
//      recency to tell real downloads apart from drive-by / popunder "jumplinks".
//
// Isolated-world script: it never touches page JS, only the DOM + runtime messaging.
//
// The button lives in a closed shadow root so page styles — including
// `!important` rules — cannot reach it, and it re-parents into the fullscreen
// element so it survives going fullscreen.
//
// Anchoring is observer-driven. The previous version ran a 800ms setInterval on
// every page whether or not a video existed; now a page with no video installs
// no timer at all, and the slow safety tick only runs while a video is actually
// on screen (it catches layout moves that fire no event, which observers alone
// would miss).

(() => {
  "use strict";
  const api = globalThis.browser || globalThis.chrome;
  if (!api || !api.runtime || window.top !== window) return; // top frame only

  // ---- user-gesture signal -------------------------------------------------
  let lastGestureSent = 0;
  function markGesture(e) {
    if (!e || !e.isTrusted) return;
    const now = Date.now();
    if (now - lastGestureSent < 400) return; // throttle chatter
    lastGestureSent = now;
    try { api.runtime.sendMessage({ type: "macget-gesture" }); } catch (_) {}
  }
  window.addEventListener("pointerdown", markGesture, true);
  window.addEventListener("keydown", markGesture, true);

  // ---- preferences ---------------------------------------------------------
  let prefs = { showVideoButton: true, corner: "top-right", hidden: false };

  // ---- the button ----------------------------------------------------------
  const STYLE = `
    :host { all: initial; }
    .btn {
      position: fixed;
      z-index: 2147483647;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 7px 11px;
      border: 0;
      border-radius: 9px;
      font: 600 12px/1 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      color: #3a2103;
      background: linear-gradient(180deg, #f7c45e, #f0a64e);
      box-shadow: 0 2px 10px rgba(30, 15, 0, .45), inset 0 0 0 .5px rgba(255,255,255,.4);
      cursor: pointer;
      opacity: 0;
      transform: translateY(-3px);
      transition: opacity .18s ease, transform .18s ease, background .2s ease;
      pointer-events: none;
      white-space: nowrap;
    }
    .btn.visible { opacity: .95; transform: none; pointer-events: auto; }
    .btn.visible:hover { opacity: 1; }
    .btn:focus-visible { outline: 2px solid #fff; outline-offset: 2px; }
    .btn.sent { background: linear-gradient(180deg, #4cd471, #1a9d4b); color: #fff; }
    .btn.failed { background: linear-gradient(180deg, #ef6a5f, #d0342c); color: #fff; }
    .btn.busy { opacity: .75; }
    .btn svg { width: 13px; height: 13px; flex: none; }
    @media (prefers-reduced-motion: reduce) {
      .btn { transition: none; }
    }
  `;

  const ICONS = {
    idle: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2.5v7"/><path d="M4.75 6.5 8 9.75 11.25 6.5"/><path d="M3 13h10"/></svg>',
    sent: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m3.5 8.5 3 3 6-7"/></svg>',
    failed: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M8 4v5"/><path d="M8 11.5v.5"/></svg>',
  };

  let host = null;       // the shadow host element
  let root = null;       // the closed shadow root
  let button = null;
  let video = null;      // the video we are currently anchored to

  let resetTimer = null;
  let lastSentAt = 0;

  function buildButton() {
    host = document.createElement("div");
    host.setAttribute("data-macget", "");
    // The host itself must not affect page layout.
    host.style.setProperty("all", "initial", "important");
    host.style.setProperty("position", "static", "important");

    root = host.attachShadow({ mode: "closed" });

    const style = document.createElement("style");
    style.textContent = STYLE;
    root.appendChild(style);

    button = document.createElement("button");
    button.type = "button";
    button.className = "btn";
    button.setAttribute("aria-label", "Send this video to MacGet");
    setLabel("idle", "MacGet");

    button.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      requestDownload();
    }, true);
    button.addEventListener("pointerenter", () => { hoveringButton = true; showButton(); });
    button.addEventListener("pointerleave", () => { hoveringButton = false; scheduleHide(); });
    button.addEventListener("focus", showButton);

    root.appendChild(button);
    (document.body || document.documentElement).appendChild(host);
  }

  function setLabel(state, text) {
    button.classList.remove("sent", "failed", "busy");
    if (state === "sent") button.classList.add("sent");
    if (state === "failed") button.classList.add("failed");
    if (state === "busy") button.classList.add("busy");
    button.innerHTML = "";
    const icon = document.createElement("span");
    icon.innerHTML = ICONS[state === "busy" ? "idle" : state] || ICONS.idle;
    button.appendChild(icon.firstChild);
    button.appendChild(document.createTextNode(text));
  }

  function flash(state, text, ms) {
    setLabel(state, text);
    clearTimeout(resetTimer);
    resetTimer = setTimeout(() => setLabel("idle", "MacGet"), ms);
  }

  async function requestDownload() {
    const now = Date.now();
    if (now - lastSentAt < 1500) return; // guard double-clicks
    lastSentAt = now;

    setLabel("busy", "Sending…");
    try {
      const result = await api.runtime.sendMessage({
        type: "macget-media",
        pageUrl: location.href,
        title: document.title || undefined,
      });
      if (result && result.ok) flash("sent", "Sent", 1800);
      else flash("failed", "Macget not connected", 3200);
    } catch (_) {
      flash("failed", "Macget not connected", 3200);
    }
  }

  // ---- anchoring -----------------------------------------------------------

  /** Largest visible <video> on the page (handles YouTube + generic players). */
  function findMainVideo() {
    let best = null;
    let bestArea = 0;
    for (const v of document.querySelectorAll("video")) {
      const r = v.getBoundingClientRect();
      const area = r.width * r.height;
      if (area > bestArea && r.width >= 200 && r.height >= 120) {
        best = v;
        bestArea = area;
      }
    }
    return best;
  }

  let hoveringVideo = false;
  let hoveringButton = false;
  let hideTimer = null;

  function showButton() {
    clearTimeout(hideTimer);
    if (button) button.classList.add("visible");
  }

  function scheduleHide() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (!hoveringVideo && !hoveringButton && button) button.classList.remove("visible");
    }, 400);
  }

  function onVideoEnter() { hoveringVideo = true; showButton(); }
  function onVideoLeave() { hoveringVideo = false; scheduleHide(); }

  const sizeObserver = new ResizeObserver(() => schedule());
  const visibilityObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) onScreen = entry.isIntersecting;
    schedule();
    updateSafetyTick();
  }, { threshold: 0 });

  let onScreen = false;

  function attachTo(next) {
    if (video === next) return;
    if (video) {
      video.removeEventListener("pointerenter", onVideoEnter);
      video.removeEventListener("pointerleave", onVideoLeave);
      sizeObserver.unobserve(video);
      visibilityObserver.unobserve(video);
    }
    video = next;
    hoveringVideo = false;
    if (video) {
      video.addEventListener("pointerenter", onVideoEnter);
      video.addEventListener("pointerleave", onVideoLeave);
      sizeObserver.observe(video);
      visibilityObserver.observe(video);
    } else {
      onScreen = false;
      if (button) button.classList.remove("visible");
    }
    updateSafetyTick();
  }

  function place() {
    if (!button) return;
    const v = findMainVideo();
    attachTo(v);

    if (!v || !prefs.showVideoButton || prefs.hidden) {
      button.style.display = "none";
      return;
    }

    const r = v.getBoundingClientRect();
    const visible = r.bottom > 40 && r.top < window.innerHeight - 10 && r.width >= 200;
    if (!visible) {
      button.style.display = "none";
      return;
    }
    button.style.display = "inline-flex";

    const w = button.offsetWidth || 96;
    const h = button.offsetHeight || 30;
    const pad = 12;
    const corner = prefs.corner || "top-right";

    const top = corner.startsWith("top")
      ? Math.max(8, r.top + pad)
      : Math.min(window.innerHeight - h - 8, r.bottom - h - pad);
    const left = corner.endsWith("right")
      ? Math.min(window.innerWidth - w - 8, r.right - w - pad)
      : Math.max(8, r.left + pad);

    button.style.top = `${Math.round(top)}px`;
    button.style.left = `${Math.round(left)}px`;
  }

  // rAF-coalesced: scroll and resize can fire many times per frame.
  let frame = null;
  function schedule() {
    if (frame != null) return;
    frame = requestAnimationFrame(() => {
      frame = null;
      place();
    });
  }

  // DOM mutations are a different traffic profile: a busy SPA fires thousands,
  // and each place() costs a querySelectorAll("video"). Rate-limit that path to
  // twice a second rather than letting it run every frame.
  let mutationPending = false;
  function scheduleFromMutation() {
    if (mutationPending) return;
    mutationPending = true;
    setTimeout(() => {
      mutationPending = false;
      schedule();
    }, 500);
  }

  // Layout can move a video without firing scroll, resize, or a size change —
  // a collapsing sidebar, for instance. This slow tick covers that, and only
  // runs while a video is actually on screen.
  let safetyTick = null;
  function updateSafetyTick() {
    const wanted = !!video && onScreen;
    if (wanted && safetyTick == null) {
      safetyTick = setInterval(schedule, 1000);
    } else if (!wanted && safetyTick != null) {
      clearInterval(safetyTick);
      safetyTick = null;
    }
  }

  // ---- fullscreen ----------------------------------------------------------
  // A fixed-position element outside the fullscreen subtree is not rendered, so
  // the shadow host has to move into it.
  function onFullscreenChange() {
    if (!host) return;
    const target = document.fullscreenElement || document.body || document.documentElement;
    if (host.parentNode !== target) target.appendChild(host);
    schedule();
  }

  // ---- lifecycle -----------------------------------------------------------

  async function loadPrefs() {
    try {
      const reply = await api.runtime.sendMessage({
        type: "macget-video-prefs",
        host: location.hostname,
      });
      if (reply) prefs = reply;
    } catch (_) { /* keep defaults */ }
    schedule();
  }

  function install() {
    if (host) return;
    buildButton();
    loadPrefs();

    window.addEventListener("scroll", schedule, { capture: true, passive: true });
    window.addEventListener("resize", schedule, { passive: true });
    document.addEventListener("fullscreenchange", onFullscreenChange, true);

    // SPA player swaps (YouTube replaces the <video> on navigation). Routed
    // through the rate-limited scheduler — subtree childList on a busy app can
    // fire thousands of times a second.
    const swaps = new MutationObserver(scheduleFromMutation);
    swaps.observe(document.documentElement, { childList: true, subtree: true });

    schedule();
  }

  // Settings changes should take effect without a reload.
  api.storage.onChanged.addListener((changes) => {
    if (changes.showVideoButton || changes.videoButtonCorner || changes.videoButtonHiddenHosts) {
      loadPrefs();
    }
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", install, { once: true });
  } else {
    install();
  }
})();
