// MacGet media UI wiring — FIREFOX ONLY. Never packaged for Chrome.
//
// Loaded by both popup-media.html and options-media.html, which build.sh splices
// into the shared pages. It runs BEFORE popup.js / options.js (its <script> sits
// mid-body, theirs at the end), so it registers into the extension points those
// scripts read at startup rather than calling into them.
//
// Guarded per page by an element that only exists there, so one file serves both.

"use strict";

(() => {
  const $ = (id) => document.getElementById(id);

  // ---- popup: the "Send video" action + the Recent-list glyph ---------------

  if ($("sendVideo")) {
    const glyphs = (globalThis.MACGET_KIND_GLYPHS = globalThis.MACGET_KIND_GLYPHS || {});
    const classes = (globalThis.MACGET_KIND_CLASSES = globalThis.MACGET_KIND_CLASSES || {});

    glyphs.media = '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M6 4.2v7.6a.5.5 0 0 0 .76.43l6.1-3.8a.5.5 0 0 0 0-.86l-6.1-3.8A.5.5 0 0 0 6 4.2Z"/></svg>';
    classes.media = " video";

    // runAction is declared by popup.js, which has not executed yet — resolved
    // at click time, by which point it has.
    $("sendVideo").addEventListener("click", (e) => {
      runAction(
        e.currentTarget,
        (tab) => ({ type: "macget-media", pageUrl: tab.url, title: tab.title }),
        "Sending the video on this page…"
      );
    });
  }

  // ---- options: the "Video button" settings section ------------------------

  if ($("showVideoButton")) {
    const sections = (globalThis.MACGET_OPTION_SECTIONS = globalThis.MACGET_OPTION_SECTIONS || []);

    sections.push({
      defaults: {
        showVideoButton: true,
        videoButtonCorner: "top-right",
        videoButtonHiddenHosts: [],
      },

      load(cfg) {
        $("showVideoButton").checked = cfg.showVideoButton !== false;
        $("videoCorner").value = cfg.videoButtonCorner || "top-right";
        $("videoHidden").value = (cfg.videoButtonHiddenHosts || []).join("\n");
      },

      // parseHostList comes from options.js; this runs on save, well after it loads.
      collect() {
        return {
          showVideoButton: $("showVideoButton").checked,
          videoButtonCorner: $("videoCorner").value,
          videoButtonHiddenHosts: parseHostList($("videoHidden").value),
        };
      },

      fields: ["showVideoButton", "videoCorner", "videoHidden"],
    });
  }
})();
