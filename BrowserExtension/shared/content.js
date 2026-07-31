// MacGet content script — one job: report trusted user gestures to the
// background, which uses gesture recency to tell real downloads apart from
// drive-by / popunder "jumplinks".
//
// It reads nothing from the page. No DOM is inspected, no page JS is touched,
// no data leaves the tab — the only thing sent is "a real click happened here,
// now". That is deliberately the entire surface of this file.
//
// Runs in the isolated world, top frame only.

(() => {
  "use strict";
  const api = globalThis.browser || globalThis.chrome;
  if (!api || !api.runtime || window.top !== window) return;

  let lastSent = 0;

  function markGesture(e) {
    if (!e || !e.isTrusted) return;
    const now = Date.now();
    if (now - lastSent < 400) return; // throttle chatter
    lastSent = now;
    // Fire-and-forget. The background sends no reply, which on Firefox settles
    // as a rejected promise — swallow it rather than leaving unhandled
    // rejections on every click of every page.
    try {
      const pending = api.runtime.sendMessage({ type: "macget-gesture" });
      if (pending && typeof pending.catch === "function") pending.catch(() => {});
    } catch (_) {}
  }

  window.addEventListener("pointerdown", markGesture, true);
  window.addEventListener("keydown", markGesture, true);
})();
