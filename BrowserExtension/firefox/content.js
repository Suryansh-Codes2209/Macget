// Macget content script. Two jobs:
//   1. Overlay a "⬇ Macget" button on the main <video> so the user can send the
//      current page to Macget for yt-dlp extraction (YouTube + generic sites).
//   2. Report trusted user gestures to the background script, which uses gesture
//      recency to tell real downloads apart from drive-by / popunder "jumplinks".
//
// Isolated-world script: it never touches page JS, only the DOM + runtime messaging.
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

  // ---- in-page download button --------------------------------------------
  const BTN_ID = "macget-download-btn";
  let button = null;
  let lastSentAt = 0;

  function buildButton() {
    const b = document.createElement("button");
    b.id = BTN_ID;
    b.type = "button";
    b.textContent = "⬇ Macget";
    b.setAttribute("aria-label", "Download this video with Macget");
    Object.assign(b.style, {
      position: "fixed",
      zIndex: "2147483647",
      display: "none",
      padding: "6px 11px",
      borderRadius: "8px",
      border: "0",
      font: "600 12px/1 -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif",
      color: "#fff",
      background: "linear-gradient(160deg,#0A84FF,#0033B0)",
      boxShadow: "0 2px 10px rgba(0,20,90,.45)",
      cursor: "pointer",
      opacity: "0.92",
    });
    b.addEventListener("mouseenter", () => { b.style.opacity = "1"; });
    b.addEventListener("mouseleave", () => { b.style.opacity = "0.92"; });
    b.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      requestDownload(b);
    }, true);
    return b;
  }

  function requestDownload(b) {
    const now = Date.now();
    if (now - lastSentAt < 1500) return; // guard double-clicks
    lastSentAt = now;
    try {
      api.runtime.sendMessage({
        type: "macget-media",
        pageUrl: location.href,
        title: document.title || undefined,
      });
    } catch (_) {}
    const original = b.textContent;
    b.textContent = "✓ Sent to Macget";
    setTimeout(() => { b.textContent = original; }, 1600);
  }

  // Largest visible <video> on the page (handles YouTube + generic players).
  function findMainVideo() {
    let best = null, bestArea = 0;
    for (const v of document.querySelectorAll("video")) {
      const r = v.getBoundingClientRect();
      const area = r.width * r.height;
      if (area > bestArea && r.width >= 200 && r.height >= 120) { best = v; bestArea = area; }
    }
    return best;
  }

  function reposition() {
    if (!button) return;
    const v = findMainVideo();
    if (!v) { button.style.display = "none"; return; }
    const r = v.getBoundingClientRect();
    const onScreen = r.bottom > 40 && r.top < window.innerHeight - 10 && r.width >= 200;
    if (!onScreen) { button.style.display = "none"; return; }
    button.style.display = "block";
    // Top-right corner of the player.
    button.style.top = Math.max(8, r.top + 10) + "px";
    button.style.left = (r.right - button.offsetWidth - 12) + "px";
  }

  function install() {
    if (button) return;
    button = buildButton();
    (document.body || document.documentElement).appendChild(button);
    reposition();
    setInterval(reposition, 800);
    window.addEventListener("scroll", reposition, true);
    window.addEventListener("resize", reposition, true);
    // YouTube is a SPA — re-anchor after client-side navigations.
    window.addEventListener("yt-navigate-finish", reposition, true);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", install, { once: true });
  } else {
    install();
  }
})();
