const REPO = "https://github.com/Suryansh-Codes2209/Macget";

/**
 * The published listing. The store also accepts a `/detail/<slug>/<id>` form,
 * but the bare id is what redirects reliably and is what the app's Help menu
 * opens (`AppDelegate.openExtensionPage`) — keep the two in sync.
 */
const CHROME_WEB_STORE =
  "https://chromewebstore.google.com/detail/ldmhmgglgemkoogpokfcgplbpfokcejl";

const LINKEDIN = "https://www.linkedin.com/company/macget-app";

/**
 * The person, not the product. `LINKEDIN` above is the MacGet company page —
 * these are the maintainer's own profiles, and the two are deliberately kept
 * apart so the footer and the JSON-LD `author` don't cross-link the wrong one.
 */
const MAINTAINER = {
  name: "Suryansh Chaudhary",
  githubUrl: "https://github.com/Suryansh-Codes2209",
  xUrl: "https://x.com/Suryansh_2001",
  linkedinUrl: "https://www.linkedin.com/in/suryansh-chaudhary-2209/",
} as const;

export const siteConfig = {
  name: "MacGet",
  binary: "Macget",
  tagline: "A native macOS download manager that doesn't fight your network.",
  heroHeadline: ["Download.", "In parallel."],
  heroSub:
    "MacGet is a free, open-source download manager for Mac. It pulls each file over up to 16 connections at once, backs off when a server pushes back, and resumes after a restart.",
  minOS: "macOS Tahoe 26.4",
  version: "1.4.0",

  /** Canonical origin. Used for metadataBase, canonical tags, and the sitemap. */
  url: "https://macget.suryansh.work",

  repoUrl: REPO,
  downloadUrl: `${REPO}/releases/latest`,

  /**
   * MacGet ships through its own tap, not homebrew/cask — the latter requires
   * 225 stars / 90 forks / 90 watchers for a self-submission, and forbids the
   * quarantine-stripping postflight an un-notarized build needs. Keep this in
   * sync with the tap repo name (Suryansh-Codes2209/homebrew-macget).
   */
  brewCommand: "brew install --cask suryansh-codes2209/macget/macget",
  tapUrl: "https://github.com/Suryansh-Codes2209/homebrew-macget",
  releasesUrl: `${REPO}/releases`,
  licenseUrl: `${REPO}/blob/main/LICENSE`,
  issuesUrl: `${REPO}/issues`,
  securityUrl: `${REPO}/blob/main/SECURITY.md`,
  chromeWebStoreUrl: CHROME_WEB_STORE,
  linkedinUrl: LINKEDIN,
  contactEmail: "suryansh.codes2001@gmail.com",
  maintainer: MAINTAINER,

  disclaimer:
    "MacGet is not affiliated with or endorsed by Tonec Inc. or Internet Download Manager.",

  nav: [
    { label: "Features", href: "/#features" },
    { label: "Inspector", href: "/#inspector" },
    { label: "Bonding", href: "/#bonding" },
    { label: "Docs", href: "/docs" },
    { label: "Changelog", href: "/changelog" },
    { label: "Install", href: "/install" },
  ],

  footerNav: [
    {
      title: "Product",
      links: [
        { label: "Watch the tour", href: "/#film" },
        { label: "Features", href: "/#features" },
        { label: "Inspector", href: "/#inspector" },
        { label: "Connection bonding", href: "/#bonding" },
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

  /**
   * Chapters of `public/macget-launch.mp4`, in seconds. Read off the film
   * itself — if the video is re-cut, re-time these or the chapter rail seeks
   * to the wrong scene.
   */
  film: {
    src: "/macget-launch.mp4",
    poster: "/macget-launch-poster.jpg",
    duration: 61.5,
    chapters: [
      { at: 0, label: "The problem" },
      { at: 9.5, label: "16 parallel chunks" },
      { at: 15, label: "Live queue" },
      { at: 21.5, label: "Inspector" },
      { at: 27, label: "Throttled hosts" },
      { at: 32, label: "Bonding" },
      { at: 37.5, label: "Resume" },
      { at: 43, label: "Everything else" },
    ],
  },

  /**
   * The three engine behaviours the page leads with. `points` are concrete
   * facts from the engine (see CLAUDE.md ▸ The download pipeline) — keep them
   * true rather than punchy.
   */
  engine: [
    {
      id: "parallel",
      title: "One file, up to 16 connections",
      summary:
        "MacGet asks the server for different byte ranges at the same time and writes each piece straight into place.",
      points: [
        "Files are cut into ~8 MB pieces, so a worker that finishes early takes the next one instead of waiting.",
        "Near the end, the biggest unfinished piece is split in half so the last few megabytes don't crawl.",
        "Servers that don't support ranges get one honest connection, not a fake speedup.",
      ],
    },
    {
      id: "adaptive",
      title: "Backs off when a server pushes back",
      summary:
        "Downloads start at full speed. If a host starts refusing connections while still serving others, MacGet halves its worker count instead of hammering.",
      points: [
        "A Wi-Fi drop, where everything fails at once, is not blamed on the server.",
        "The limit it learns for that host is remembered for 7 days, then forgotten.",
        "You can see and clear learned limits in Settings ▸ Network.",
      ],
    },
    {
      id: "resume",
      title: "Quit anytime. It picks up where it stopped.",
      summary:
        "Progress is saved per piece, so a restart, a crash or a closed lid costs you nothing already downloaded.",
      points: [
        "If the file changed on the server, MacGet notices (If-Range) and restarts cleanly instead of stitching two versions together.",
        "SHA-256 or MD5 checksums are verified before the file is moved into place.",
        "The unfinished file stays hidden next to its destination until it's complete.",
      ],
    },
  ],

  /** The secondary feature list. One sentence each — the docs carry the rest. */
  more: [
    {
      title: "Video and audio",
      blurb: "Paste a video page and pick quality and format. Uses the bundled yt-dlp and ffmpeg.",
      tag: "Opt-in",
      icon: "Clapperboard",
    },
    {
      title: "Free ebooks",
      blurb: "Search Project Gutenberg, the Internet Archive or your own Calibre/OPDS server, and queue a book in one click.",
      icon: "BookOpen",
    },
    {
      title: "BitTorrent",
      blurb: "Magnets and .torrent files in the same queue, with seeding limits you set. MacGet never searches for torrents.",
      tag: "Off by default",
      icon: "ArrowUpDown",
    },
    {
      title: "Downloads behind a login",
      blurb: "Basic, Digest and NTLM credentials are stored once, in the macOS Keychain.",
      icon: "KeyRound",
    },
    {
      title: "Speed limits and priorities",
      blurb: "A global speed cap, per-download priority, retries, timeouts and HTTP/HTTPS proxies.",
      icon: "SlidersHorizontal",
    },
    {
      title: "Sorted on arrival",
      blurb: "Finished files can move into category folders automatically, with name clashes resolved as “(2)”, “(3)”.",
      icon: "FolderTree",
    },
    {
      title: "Copy a link, get a prompt",
      blurb: "MacGet notices a download link on your clipboard and offers to grab it.",
      icon: "Clipboard",
    },
    {
      title: "Updates itself",
      blurb: "Sparkle checks for new versions and verifies each update's EdDSA signature before installing.",
      icon: "RefreshCw",
    },
  ],

  /**
   * The browser extension. `payload` mirrors the fields the extension actually
   * sends (`BrowserExtension/chromium/background.js` → `captureItem`). If a
   * field is added or dropped there, change it here too.
   */
  extension: {
    payload: ["url", "cookie", "referer", "userAgent", "filename", "size"],
    browsers: ["Chrome", "Edge", "Brave", "Firefox"],
  },

  /**
   * The connection-bonding section. Mirrors `Macget/Engine/Bonding/` — keep the
   * claims here in step with the "Connection bonding" notes in CLAUDE.md.
   */
  bonding: {
    links: [
      { name: "Wi-Fi", kind: "en0", share: 0.58 },
      { name: "iPhone (USB)", kind: "en7", share: 0.42 },
    ],
    devices: ["Wi-Fi", "Ethernet", "iPhone over USB", "Android over USB", "USB / Thunderbolt adapters"],
    facts: [
      {
        title: "No tuning",
        detail:
          "Both links pull the next piece as soon as they're free, so the faster one naturally carries more.",
      },
      {
        title: "A bad link only removes itself",
        detail:
          "If a server rejects your phone's connection, that link sits out and the download carries on over the others.",
      },
      {
        title: "One switch",
        detail:
          "Off by default. Turn it on from the Connections button in the toolbar. Any proxy turns it off, so it never bypasses one.",
      },
    ],
  },

  pipeline: [
    {
      step: "Check the server",
      detail: "Size, change markers, and whether it accepts byte ranges at all.",
    },
    {
      step: "Plan the pieces",
      detail: "~8 MB pieces, up to 16 workers, within any limit learned for this host.",
    },
    {
      step: "Download in parallel",
      detail: "Workers steal pieces, retry with backoff, and fail fast on permanent errors.",
    },
    {
      step: "Verify and finish",
      detail: "Checksum if you gave one, then move it into place under a unique name.",
    },
  ],

  /**
   * MacGet ships un-notarized, so a DMG install meets a Gatekeeper dialog that
   * reads like a malware alert. These steps set that expectation up front.
   */
  firstLaunch: [
    "Open MacGet. macOS says it can't check it for malicious software — click Done.",
    "Go to System Settings ▸ Privacy & Security and click Open Anyway next to Macget.",
    "That's it. Later launches and auto-updates open normally.",
  ],

  faq: [
    {
      q: "Why another download manager?",
      a: "Most either ignore byte-range support or open every connection they can and get throttled for it. MacGet opens as many connections as help, backs off on evidence when a host objects, and keeps its progress properly across launches.",
    },
    {
      q: "Is it safe if it isn't notarized?",
      a: "Notarization needs a paid Apple Developer account, so MacGet skips it — a cost decision, not a security one. The source is public, the build uses Hardened Runtime, and every auto-update is checked against an EdDSA signature before it installs. You'll see one Gatekeeper prompt on first launch; installing with Homebrew avoids it.",
    },
    {
      q: "Which Macs does it run on?",
      a: "Apple silicon Macs on macOS Tahoe 26.4 or later. There is no Intel build.",
    },
    {
      q: "What if a server doesn't support byte ranges?",
      a: "MacGet detects it before downloading and uses a single connection. No corruption, and no pretending parallelism is happening when it isn't.",
    },
    {
      q: "How do updates work?",
      a: "MacGet checks a signed feed on a schedule and installs updates itself, so you never come back here to re-download. Each update's EdDSA signature is checked before it installs.",
    },
    {
      q: "Does it collect anything?",
      a: "No. No analytics, telemetry, remote logging or account. Your queue, settings and learned host limits stay in ~/Library/Application Support/Macget. The privacy policy lists the few times MacGet touches the network at all.",
    },
    {
      q: "Is the app sandboxed?",
      a: "No — MacGet isn't headed for the Mac App Store, so App Sandbox is off. Hardened Runtime is on.",
    },
  ],
} as const;

export type SiteConfig = typeof siteConfig;
