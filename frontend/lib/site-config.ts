export const siteConfig = {
  name: "MacGet",
  binary: "Macget",
  tagline: "A native macOS download manager that doesn't fight your network.",
  heroHeadline: ["Download.", "In parallel."],
  heroSub:
    "MacGet splits every file across up to 16 chunks, resumes across restarts, and adapts to throttled hosts — all in a native SwiftUI app built for macOS Tahoe.",
  minOS: "macOS Tahoe 26.4",
  version: "1.0",
  // TODO: replace REPLACE_ME with the real GitHub username before release
  repoUrl: "https://github.com/REPLACE_ME/macget",
  downloadUrl: "https://github.com/REPLACE_ME/macget/releases/latest",
  licenseUrl: "https://github.com/REPLACE_ME/macget/blob/main/LICENSE",
  disclaimer:
    "MacGet is not affiliated with or endorsed by Tonec Inc. or Internet Download Manager.",
  nav: [
    { label: "Features", href: "#features" },
    { label: "How it works", href: "#how" },
    { label: "FAQ", href: "#faq" },
  ],
  features: [
    {
      title: "Up to 16 parallel chunks",
      blurb:
        "HTTP-Range requests split each file across as many threads as the host allows. The engine clamps to ≥64 KB per chunk to avoid wasting connections.",
      icon: "Layers",
    },
    {
      title: "Resume across restarts",
      blurb:
        "Partial files persist with per-chunk progress recorded. If-Range guards against silent corruption when a file changes mid-download.",
      icon: "RotateCw",
    },
    {
      title: "Adapts to throttled hosts",
      blurb:
        "Demotes parallelism when servers push back. Caps persist per-host, so the second download to the same origin starts smarter.",
      icon: "Activity",
    },
    {
      title: "Native SwiftUI, App Nap-resistant",
      blurb:
        "Built for macOS Tahoe 26.4. Keeps streaming when minimized. Hardened Runtime, signed and notarized.",
      icon: "Apple",
    },
    {
      title: "Three input paths",
      blurb:
        "Clipboard watcher catches copied URLs at 1 Hz. NSServices and drag-and-drop cover everything else.",
      icon: "Clipboard",
    },
    {
      title: "MIT licensed, zero telemetry",
      blurb:
        "Open source. No analytics. No remote logging. Your queue and settings live in ~/Library/Application Support/Macget.",
      icon: "ShieldCheck",
    },
  ],
  pipeline: [
    {
      step: "Probe",
      detail:
        "HEAD with GET-range fallback. Records ETag, Last-Modified, and whether the host honors byte-range requests.",
    },
    {
      step: "Plan",
      detail:
        "Up to 16 chunks, ≥64 KB each. Clamped to per-host caps the engine has previously learned.",
    },
    {
      step: "Stream",
      detail:
        "Parallel HTTP-Range fetches over a single shared URLSession. Smart retry on transient errors, fail-fast on permanent ones.",
    },
    {
      step: "Finalize",
      detail:
        "Atomic move from .macget-partial to the resolved unique filename. Sparkle handles its own update channel separately.",
    },
  ],
  stats: [
    { label: "Parallel chunks", value: "16", caption: "max per file" },
    { label: "Telemetry", value: "0", caption: "no analytics, no logging" },
    { label: "License", value: "MIT", caption: "open source forever" },
  ],
  faq: [
    {
      q: "Why another download manager?",
      a: "Most chew battery, ignore Range support, or fight macOS power management. Macget uses native URLSession, persists state cleanly, and adapts to hosts instead of hammering them.",
    },
    {
      q: "Apple Silicon?",
      a: "Yes — built native, Universal binary signed and notarized. Minimum macOS is Tahoe 26.4.",
    },
    {
      q: "What if a server doesn't support Range?",
      a: "Macget detects this in the probe and falls back to a single-stream download. No corruption, no pretending parallelism is happening.",
    },
    {
      q: "Is the app sandboxed?",
      a: "No. App Sandbox is intentionally off — Macget is not destined for the Mac App Store. Hardened Runtime is on; updates use Sparkle's EdDSA signatures.",
    },
    {
      q: "How do updates work?",
      a: "Sparkle auto-update. The appcast is hosted on the project's GitHub Pages and signed with a private EdDSA key.",
    },
    {
      q: "Does it touch my data?",
      a: "No telemetry, no analytics, no remote logging. Queue and settings live entirely in ~/Library/Application Support/Macget on your machine.",
    },
  ],
} as const;

export type SiteConfig = typeof siteConfig;
