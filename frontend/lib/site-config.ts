const REPO = "https://github.com/Suryansh-Codes2209/Macget";

/**
 * The published listing. The store also accepts a `/detail/<slug>/<id>` form,
 * but the bare id is what redirects reliably and is what the app's Help menu
 * opens (`AppDelegate.openExtensionPage`) — keep the two in sync.
 */
const CHROME_WEB_STORE =
  "https://chromewebstore.google.com/detail/ldmhmgglgemkoogpokfcgplbpfokcejl";

const LINKEDIN = "https://www.linkedin.com/company/macget-app";

export const siteConfig = {
  name: "MacGet",
  binary: "Macget",
  tagline: "A native macOS download manager that doesn't fight your network.",
  heroHeadline: ["Download.", "In parallel."],
  heroSub:
    "MacGet splits every file across up to 16 chunks, learns what each host will tolerate, and resumes across restarts — a native SwiftUI app for macOS Tahoe.",
  minOS: "macOS Tahoe 26.4",
  version: "1.3.0",

  /** Canonical origin. Used for metadataBase, canonical tags, and the sitemap. */
  url: "https://macget.suryansh.work",

  repoUrl: REPO,
  downloadUrl: `${REPO}/releases/latest`,
  releasesUrl: `${REPO}/releases`,
  licenseUrl: `${REPO}/blob/main/LICENSE`,
  issuesUrl: `${REPO}/issues`,
  securityUrl: `${REPO}/blob/main/SECURITY.md`,
  chromeWebStoreUrl: CHROME_WEB_STORE,
  linkedinUrl: LINKEDIN,
  contactEmail: "suryansh.codes2001@gmail.com",

  disclaimer:
    "MacGet is not affiliated with or endorsed by Tonec Inc. or Internet Download Manager.",

  nav: [
    { label: "Features", href: "/#features" },
    { label: "Inspector", href: "/#inspector" },
    { label: "How it works", href: "/#how" },
    { label: "Docs", href: "/docs" },
    { label: "Install", href: "/install" },
    { label: "Changelog", href: "/changelog" },
  ],

  footerNav: [
    {
      title: "Product",
      links: [
        { label: "Features", href: "/#features" },
        { label: "Inspector", href: "/#inspector" },
        { label: "Browser capture", href: "/#extension" },
        { label: "How it works", href: "/#how" },
        { label: "Changelog", href: "/changelog" },
        { label: "FAQ", href: "/#faq" },
      ],
    },
    {
      title: "Documentation",
      links: [
        { label: "Docs home", href: "/docs" },
        { label: "Installation", href: "/install" },
        { label: "Browser extension", href: "/docs/browser-extension" },
        { label: "Settings reference", href: "/docs/settings-reference" },
      ],
    },
    {
      title: "Project",
      links: [
        { label: "GitHub", href: REPO, external: true },
        { label: "Chrome Web Store", href: CHROME_WEB_STORE, external: true },
        { label: "LinkedIn", href: LINKEDIN, external: true },
        { label: "Releases", href: `${REPO}/releases`, external: true },
        { label: "Report an issue", href: `${REPO}/issues`, external: true },
        { label: "MIT License", href: `${REPO}/blob/main/LICENSE`, external: true },
      ],
    },
    {
      title: "Legal",
      links: [
        { label: "Privacy Policy", href: "/privacy" },
        { label: "Security policy", href: `${REPO}/blob/main/SECURITY.md`, external: true },
      ],
    },
  ],

  features: [
    {
      title: "Up to 16 parallel chunks",
      blurb:
        "HTTP-Range requests split each file across as many connections as the host allows. Work-stealing hands finished workers the next outstanding piece, so one slow chunk never holds up the file.",
      icon: "Layers",
    },
    {
      title: "Watch it happen, live",
      blurb:
        "An inspector panel charts throughput over a rolling 30-second window and draws the file as its actual pieces — cells filling in file order, the ones a worker holds pulsing. One bar creeping right looks the same whether you have 1 connection or 16; this doesn't.",
      icon: "Gauge",
    },
    {
      title: "Adapts to throttled hosts",
      blurb:
        "When a host refuses connections while the rest keep delivering, the engine halves its workers instead of hammering — and a dropped Wi-Fi link, where everything fails at once, is deliberately not counted against the server. The learned cap persists for that host for 7 days, so the next download starts smart without one bad night slowing it forever.",
      icon: "Activity",
    },
    {
      title: "Resume across restarts",
      blurb:
        "Per-chunk progress is persisted. Quit mid-download and reopen — it picks up where it left off. If-Range validators catch a file that changed underneath you instead of corrupting it.",
      icon: "RotateCw",
    },
    {
      title: "Video and audio via yt-dlp",
      blurb:
        "Media links route to a bundled yt-dlp + ffmpeg extractor with a quality and container picker. Opt-in — ordinary links always download as plain HTTP files.",
      icon: "Clapperboard",
    },
    {
      title: "Books from open catalogs",
      blurb:
        "Browse and search Project Gutenberg and the Internet Archive without leaving the app, then send a book straight to the queue. Add any OPDS feed too \u2014 including your own Calibre server.",
      icon: "BookOpen",
    },
    {
      title: "BitTorrent, on your terms",
      blurb:
        "Magnet links and .torrent files download in the same queue as everything else. Off by default, and seeding stops at a ratio and time limit you set. MacGet never searches for or indexes torrents.",
      icon: "ArrowUpDown",
    },
    {
      title: "Downloads behind a login",
      blurb:
        "Basic, Digest, and NTLM challenges are answered from credentials you store once. They live in the macOS Keychain, not in a config file.",
      icon: "KeyRound",
    },
    {
      title: "Capture from your browser",
      blurb:
        "A Chrome, Edge, Brave, and Firefox extension hands downloads to MacGet over local native messaging — cookies and referrer included, so logged-in downloads keep working.",
      icon: "Chrome",
    },
    {
      title: "Verified, not just downloaded",
      blurb:
        "SHA-256 and MD5 are checked at finalize, before the partial file is promoted. A mismatch fails the download and keeps the partial rather than handing you a bad file.",
      icon: "ShieldCheck",
    },
    {
      title: "Yours to schedule",
      blurb:
        "Global speed cap, per-download priorities, configurable timeouts and retries, HTTP/HTTPS proxy support, and auto-sort into category folders when a download lands.",
      icon: "SlidersHorizontal",
    },
    {
      title: "MIT licensed, zero telemetry",
      blurb:
        "No analytics, no remote logging, no account. Your queue and settings never leave ~/Library/Application Support/Macget.",
      icon: "Lock",
    },
  ],

  /**
   * The browser-capture section. `payload` mirrors the fields the extension
   * actually sends (`BrowserExtension/chromium/background.js` → `captureItem`),
   * so it stays a manifest rather than a marketing list. If a field is added or
   * dropped there, change it here too.
   */
  extension: {
    payload: [
      {
        field: "url",
        note: "The file's own address — not the page you were reading.",
      },
      {
        field: "cookie",
        note: "Scoped to that URL's domain, so a file behind a login still downloads.",
      },
      {
        field: "referer",
        note: "Hotlink protection sees the page you came from and lets it through.",
      },
      {
        field: "userAgent",
        note: "Your browser's, verbatim. The request looks the same as the one it replaces.",
      },
      {
        field: "filename",
        note: "The name your browser resolved, not the id sitting in the URL.",
      },
      {
        field: "size",
        note: "The queue shows the real total before the first byte lands.",
      },
    ],
    browsers: ["Chrome", "Edge", "Brave", "Firefox"],
  },

  pipeline: [
    {
      step: "Probe",
      detail:
        "HEAD with a ranged-GET fallback, because some servers 405 on HEAD. Records size, ETag, Last-Modified, and whether byte ranges are honored at all.",
    },
    {
      step: "Plan",
      detail:
        "Split into pieces of ~8 MB, up to 16 workers, each chunk at least 64 KB. Clamped to whatever cap the engine already learned for this host.",
    },
    {
      step: "Stream",
      detail:
        "Parallel range requests over one shared URLSession, HTTP/3 where offered. Transient errors back off and retry; permanent ones fail fast instead of burning attempts.",
    },
    {
      step: "Finalize",
      detail:
        "Verify the checksum if one was given, then move the partial into place under a unique name — and into a category folder if auto-sort is on.",
    },
  ],

  stats: [
    { label: "Parallel chunks", value: "16", caption: "max per file" },
    { label: "Telemetry", value: "0", caption: "no analytics, no logging" },
    { label: "License", value: "MIT", caption: "open source forever" },
  ],

  /**
   * First-launch steps shown inline under the download CTA. MacGet ships
   * un-notarized, so this is the difference between a user who expects
   * Gatekeeper and a user who thinks the app is broken.
   */
  firstLaunch: [
    {
      title: "macOS will warn you once",
      detail:
        "“Macget can't be opened because Apple cannot check it for malicious software.” Expected — the build isn't notarized. Click Done.",
    },
    {
      title: "Open Anyway",
      detail:
        "System Settings → Privacy & Security. Scroll to the message about Macget and click Open Anyway, then confirm.",
    },
    {
      title: "That's it, forever",
      detail:
        "macOS remembers. Every later launch — and every Sparkle auto-update — opens normally with no prompt.",
    },
  ],

  faq: [
    {
      q: "Why another download manager?",
      a: "Most either ignore Range support, or open every connection they can and get throttled for it. MacGet discovers what each host actually tolerates at runtime and adapts, using native URLSession and persisting state properly across launches.",
    },
    {
      q: "Is it safe if it isn't notarized?",
      a: "MacGet is distributed free and un-notarized because notarization requires a paid Apple Developer account. That's a cost decision, not a security one: the source is public and auditable, the build has Hardened Runtime enabled, and every auto-update is verified against an EdDSA signature before it installs. The tradeoff is a one-time Gatekeeper prompt on first launch — the install guide walks through it.",
    },
    {
      q: "Apple Silicon?",
      a: "Yes — Apple silicon only (arm64), no Intel build. Minimum macOS is Tahoe 26.4.",
    },
    {
      q: "What if a server doesn't support Range?",
      a: "The probe detects it and falls back to a single stream. No corruption, and no pretending parallelism is happening when it isn't.",
    },
    {
      q: "How do updates work?",
      a: "Sparkle. MacGet checks a signed appcast on a schedule and can install updates itself — you don't come back here to re-download. Every update is EdDSA-signed and the signature is checked before installing, independently of Apple notarization.",
    },
    {
      q: "Does it collect anything?",
      a: "No. No analytics, no telemetry, no remote logging, no account, and no server of ours to send anything to. Your queue, settings, and learned host limits stay in ~/Library/Application Support/Macget. The privacy policy spells out the few cases where MacGet touches the network at all.",
    },
    {
      q: "Is the app sandboxed?",
      a: "No — App Sandbox is intentionally off, since MacGet isn't destined for the Mac App Store. Hardened Runtime is on.",
    },
  ],
} as const;

export type SiteConfig = typeof siteConfig;
