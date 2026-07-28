// MacGet options page. Persists to storage.local; the background worker reads
// the same keys on each capture. Uses the promise-based API root so one file
// works on Chrome, Edge, Brave, and Firefox.

const api = globalThis.browser || globalThis.chrome;
const HOST_NAME = "com.suryansh.macget";

const DEFAULTS = {
  enabled: true,
  denylist: [],
  minSizeBytes: 0,
  jumplinkFilterEnabled: true,
  gestureWindowMs: 2000,
  notificationsEnabled: true,
  badgeEnabled: true,
  showVideoButton: true,
  videoButtonCorner: "top-right",
  videoButtonHiddenHosts: [],
};

const $ = (id) => document.getElementById(id);

// ---- helpers ----------------------------------------------------------------

let toastTimer;
function flashSaved() {
  const t = $("saved");
  t.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 1100);
}

/** One host per line, trimmed, lowercased, de-duplicated, blanks dropped. */
function parseHostList(text) {
  const seen = new Set();
  return text
    .split("\n")
    .map((s) => s.trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, ""))
    .filter((s) => s && !seen.has(s) && seen.add(s));
}

function reflectStatus(enabled, health) {
  const pill = $("statusPill");
  const hero = $("hero");
  let state = "connected";
  let label = "Active";

  if (!enabled) {
    state = "paused";
    label = "Paused";
  } else if (health && health.state === "unreachable") {
    state = "unreachable";
    label = "Not connected";
  }

  hero.dataset.state = state;
  pill.textContent = label;
  pill.classList.toggle("off", state === "paused");
  pill.classList.toggle("bad", state === "unreachable");
}

// ---- load / save ------------------------------------------------------------

async function load() {
  const cfg = await api.storage.local.get(DEFAULTS);

  $("enabled").checked = !!cfg.enabled;
  $("minSize").value = cfg.minSizeBytes > 0 ? Math.round(cfg.minSizeBytes / (1024 * 1024)) : 0;
  $("notifications").checked = cfg.notificationsEnabled !== false;
  $("badge").checked = cfg.badgeEnabled !== false;

  $("jumplinkFilter").checked = cfg.jumplinkFilterEnabled !== false;
  $("gestureWindow").value = Number.isFinite(cfg.gestureWindowMs) ? cfg.gestureWindowMs : 2000;
  $("denylist").value = (cfg.denylist || []).join("\n");

  $("showVideoButton").checked = cfg.showVideoButton !== false;
  $("videoCorner").value = cfg.videoButtonCorner || "top-right";
  $("videoHidden").value = (cfg.videoButtonHiddenHosts || []).join("\n");

  const manifest = api.runtime.getManifest();
  $("version").textContent = manifest.version;
  $("factHost").textContent = HOST_NAME;
  $("factId").textContent = api.runtime.id;

  reflectStatus(!!cfg.enabled, null);
  refreshHealthFacts(false);
}

async function save() {
  const mb = parseInt($("minSize").value, 10);
  const gesture = parseInt($("gestureWindow").value, 10);

  await api.storage.local.set({
    enabled: $("enabled").checked,
    minSizeBytes: Number.isFinite(mb) && mb > 0 ? mb * 1024 * 1024 : 0,
    notificationsEnabled: $("notifications").checked,
    badgeEnabled: $("badge").checked,

    jumplinkFilterEnabled: $("jumplinkFilter").checked,
    gestureWindowMs: Number.isFinite(gesture) && gesture >= 0 ? gesture : 2000,
    denylist: parseHostList($("denylist").value),

    showVideoButton: $("showVideoButton").checked,
    videoButtonCorner: $("videoCorner").value,
    videoButtonHiddenHosts: parseHostList($("videoHidden").value),
  });

  reflectStatus($("enabled").checked, lastHealth);
  flashSaved();
}

// ---- diagnostics ------------------------------------------------------------

let lastHealth = null;

function renderHealthFacts(health) {
  lastHealth = health;
  const result = $("pingResult");
  const error = $("factError");

  if (!health || health.state === "unknown") {
    result.textContent = "Not checked yet.";
    result.className = "diag-result";
  } else if (health.state === "connected") {
    const v = health.hostVersion ? ` (host v${health.hostVersion})` : "";
    result.textContent = `Connected${v}.`;
    result.className = "diag-result ok";
  } else {
    result.textContent = "Not connected.";
    result.className = "diag-result bad";
  }

  if (health && health.lastError) {
    error.textContent = health.lastError;
    error.className = "";
  } else {
    error.textContent = "None";
    error.className = "muted";
  }

  reflectStatus($("enabled").checked, health);
}

async function refreshHealthFacts(force) {
  try {
    const health = await api.runtime.sendMessage({ type: "macget-health", force: !!force });
    renderHealthFacts(health);
  } catch (_) {
    renderHealthFacts({
      state: "unreachable",
      lastError: "The extension's background worker isn't responding. Reload the extension.",
    });
  }
}

$("ping").addEventListener("click", async (e) => {
  const button = e.currentTarget;
  button.disabled = true;
  $("pingResult").textContent = "Checking…";
  $("pingResult").className = "diag-result";
  try {
    await refreshHealthFacts(true);
  } finally {
    button.disabled = false;
  }
});

$("clearHistory").addEventListener("click", async () => {
  await api.storage.local.set({ history: [] });
  flashSaved();
});

// ---- wiring -----------------------------------------------------------------

// The circuit breaker can flip `enabled` off from the background; keep up.
api.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.enabled) {
    $("enabled").checked = !!changes.enabled.newValue;
    reflectStatus(!!changes.enabled.newValue, lastHealth);
  }
  if (changes.health && changes.health.newValue) renderHealthFacts(changes.health.newValue);
});

const FIELDS = [
  "enabled", "minSize", "notifications", "badge",
  "jumplinkFilter", "gestureWindow", "denylist",
  "showVideoButton", "videoCorner", "videoHidden",
];
FIELDS.forEach((id) => $(id).addEventListener("change", save));

document.addEventListener("DOMContentLoaded", load);
