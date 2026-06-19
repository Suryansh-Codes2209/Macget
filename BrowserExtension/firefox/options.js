// Options/popup logic. Persists to storage.local; the background script reads
// the same keys on each download. Uses the promise-based API root so the same
// file works on Chrome, Edge, Brave, and Firefox.

const api = globalThis.browser || globalThis.chrome;
const DEFAULTS = { enabled: true, denylist: [], minSizeBytes: 0 };

const $ = (id) => document.getElementById(id);

let toastTimer;
function flashSaved() {
  const t = $("saved");
  t.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 1100);
}

function reflectStatus(enabled) {
  const pill = $("statusPill");
  pill.textContent = enabled ? "Active" : "Off";
  pill.classList.toggle("off", !enabled);
}

async function load() {
  const cfg = await api.storage.local.get(DEFAULTS);
  $("enabled").checked = !!cfg.enabled;
  $("minSize").value = cfg.minSizeBytes > 0 ? Math.round(cfg.minSizeBytes / (1024 * 1024)) : 0;
  $("denylist").value = (cfg.denylist || []).join("\n");
  reflectStatus(!!cfg.enabled);
}

async function save() {
  const mb = parseInt($("minSize").value, 10);
  const denylist = $("denylist").value
    .split("\n")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  await api.storage.local.set({
    enabled: $("enabled").checked,
    minSizeBytes: Number.isFinite(mb) && mb > 0 ? mb * 1024 * 1024 : 0,
    denylist,
  });
  reflectStatus($("enabled").checked);
  flashSaved();
}

// Keep the pill live if the background circuit-breaker flips `enabled` off.
api.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.enabled) {
    $("enabled").checked = !!changes.enabled.newValue;
    reflectStatus(!!changes.enabled.newValue);
  }
});

document.addEventListener("DOMContentLoaded", load);
["enabled", "minSize", "denylist"].forEach((id) => {
  document.getElementById(id).addEventListener("change", save);
});
