// MacGet popup — connection state, the master toggle, this-tab actions, and
// what was captured recently.
//
// Settings other than the master toggle live in the options page. This surface
// answers one question first: is MacGet actually working right now?

const api = globalThis.browser || globalThis.chrome;
const $ = (id) => document.getElementById(id);

const STATUS_COPY = {
  checking: {
    pill: "Checking",
    title: "Checking connection",
    desc: "Asking Macget whether it's listening.",
    retry: false,
  },
  connected: {
    pill: "Active",
    title: "Connected to Macget",
    desc: "Downloads you start are handed to the app.",
    retry: false,
  },
  paused: {
    pill: "Paused",
    title: "Capture is paused",
    desc: "Downloads stay in your browser until you turn capture back on.",
    retry: false,
  },
  unreachable: {
    pill: "Not connected",
    title: "Macget isn't connected",
    desc: "Downloads stay in your browser. In Macget, open Settings → Browser integration and turn on auto-capture.",
    retry: true,
  },
};

// ---- status -----------------------------------------------------------------

function renderStatus(state) {
  const copy = STATUS_COPY[state] || STATUS_COPY.checking;

  $("hero").dataset.state = state === "checking" ? "connected" : state;
  $("statusCard").dataset.state = state;

  const pill = $("statusPill");
  pill.textContent = copy.pill;
  pill.classList.toggle("off", state === "paused" || state === "checking");
  pill.classList.toggle("bad", state === "unreachable");

  $("statusTitle").textContent = copy.title;
  $("statusDesc").textContent = copy.desc;
  $("retry").hidden = !copy.retry;
}

/** The toggle wins: a paused extension is paused whatever the host says. */
function resolveState(enabled, health) {
  if (!enabled) return "paused";
  if (!health || health.state === "unknown") return "checking";
  return health.state === "connected" ? "connected" : "unreachable";
}

let lastEnabled = true;
let lastHealth = null;

function repaint() {
  renderStatus(resolveState(lastEnabled, lastHealth));
}

async function refreshHealth(force) {
  try {
    const health = await api.runtime.sendMessage({ type: "macget-health", force: !!force });
    if (health) lastHealth = health;
  } catch (_) {
    lastHealth = { state: "unreachable", lastError: "The extension's background worker isn't responding." };
  }
  repaint();
}

// ---- recent -----------------------------------------------------------------

// kind -> glyph markup / extra CSS class. A feature module loaded earlier in the
// page can register its own before this runs; `file` is the fallback.
const GLYPHS = (globalThis.MACGET_KIND_GLYPHS = globalThis.MACGET_KIND_GLYPHS || {});
const KIND_CLASSES = (globalThis.MACGET_KIND_CLASSES = globalThis.MACGET_KIND_CLASSES || {});

GLYPHS.file = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2v8"/><path d="M4.5 7 8 10.5 11.5 7"/><path d="M3 13h10"/></svg>';

function renderRecent(history) {
  const list = $("recentList");
  const empty = $("recentEmpty");
  list.textContent = "";

  const entries = Array.isArray(history) ? history.slice(0, 8) : [];
  empty.hidden = entries.length > 0;

  const now = Date.now();
  for (const entry of entries) {
    const li = document.createElement("li");

    const glyph = document.createElement("span");
    glyph.className = "glyph" + (entry.ok === false ? " failed" : (KIND_CLASSES[entry.kind] || ""));
    glyph.innerHTML = GLYPHS[entry.kind] || GLYPHS.file;
    li.appendChild(glyph);

    const body = document.createElement("div");
    body.className = "entry";

    const name = document.createElement("div");
    name.className = "entry-name";
    name.textContent = entry.filename || entry.url || "";
    name.title = entry.url || "";
    body.appendChild(name);

    const meta = document.createElement("div");
    meta.className = "entry-meta";
    if (entry.ok === false) {
      const tag = document.createElement("span");
      tag.className = "failed-tag";
      tag.textContent = "Not sent";
      meta.appendChild(tag);
      meta.appendChild(document.createTextNode(" · "));
    }
    const parts = [entry.host, formatBytes(entry.bytes), relativeTime(entry.at, now)].filter(Boolean);
    meta.appendChild(document.createTextNode(parts.join(" · ")));
    body.appendChild(meta);

    li.appendChild(body);
    list.appendChild(li);
  }
}

async function loadRecent() {
  try {
    const stored = await api.storage.local.get({ history: [] });
    renderRecent(stored.history);
  } catch (_) {
    renderRecent([]);
  }
}

// ---- this-tab actions -------------------------------------------------------

let noteTimer = null;

function showNote(text, kind) {
  const note = $("actionNote");
  note.textContent = text;
  note.className = "action-note" + (kind ? " " + kind : "");
  clearTimeout(noteTimer);
  if (kind) noteTimer = setTimeout(() => { note.textContent = ""; note.className = "action-note"; }, 4000);
}

async function activeTab() {
  const tabs = await api.tabs.query({ active: true, currentWindow: true });
  return tabs && tabs[0];
}

/** Run one capture action, keeping the button disabled until it resolves. */
async function runAction(button, buildMessage, pendingText) {
  const tab = await activeTab();
  if (!tab || !isCapturable(tab.url)) {
    showNote("This page can't be captured — MacGet handles http and https only.", "bad");
    return;
  }
  button.disabled = true;
  showNote(pendingText);
  try {
    const result = await api.runtime.sendMessage(buildMessage(tab));
    if (result && result.ok) {
      showNote("Sent to MacGet.", "ok");
      loadRecent();
    } else {
      showNote((result && result.error) || "MacGet didn't take it.", "bad");
    }
  } catch (e) {
    showNote("The extension's background worker isn't responding.", "bad");
  } finally {
    button.disabled = false;
    refreshHealth(false);
  }
}

// ---- wiring -----------------------------------------------------------------

async function load() {
  try {
    const cfg = await api.storage.local.get({ enabled: true });
    lastEnabled = !!cfg.enabled;
  } catch (_) {
    lastEnabled = true;
  }
  $("enabled").checked = lastEnabled;
  repaint();
  await Promise.all([refreshHealth(false), loadRecent()]);
}

$("enabled").addEventListener("change", async () => {
  lastEnabled = $("enabled").checked;
  repaint();
  try { await api.storage.local.set({ enabled: lastEnabled }); } catch (_) {}
  if (lastEnabled) refreshHealth(true);
});

$("retry").addEventListener("click", async () => {
  renderStatus("checking");
  await refreshHealth(true);
});

$("sendUrl").addEventListener("click", (e) => {
  runAction(
    e.currentTarget,
    (tab) => ({ type: "macget-capture-url", url: tab.url, tabId: tab.id }),
    "Sending this URL…"
  );
});

$("openOptions").addEventListener("click", () => {
  if (api.runtime.openOptionsPage) api.runtime.openOptionsPage();
  else window.open(api.runtime.getURL("options.html"));
  window.close();
});

// Stay live while open: the circuit breaker can flip `enabled`, and a capture
// finishing in the background should land in the list without a reopen.
api.storage.onChanged.addListener((changes, area) => {
  if (changes.enabled) {
    lastEnabled = !!changes.enabled.newValue;
    $("enabled").checked = lastEnabled;
    repaint();
  }
  if (changes.history) renderRecent(changes.history.newValue);
  if (changes.health && changes.health.newValue) {
    lastHealth = changes.health.newValue;
    repaint();
  }
});

document.addEventListener("DOMContentLoaded", load);
