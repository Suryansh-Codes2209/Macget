# MacGet

A free, open-source multi-threaded download manager for macOS.

- **Up to 20 parallel HTTP-Range threads per file** for faster downloads on cooperative servers
- **Pause / resume / cancel**, with state that survives app restarts
- **Persistent queue** — close the app, reopen, downloads continue from where they left off
- **Native SwiftUI** — looks and feels like a real Mac app
- **Free forever, MIT licensed** — no ads, no telemetry, no payments

> MacGet is **not affiliated with or endorsed by** Tonec Inc. or Internet Download Manager. It is an independent free alternative.

---

## Status

**Pre-release / under construction.** The codebase is being built up phase-by-phase per [the architecture plan](docs/architecture.md). Once Phase 6 (notarized DMG) is done, v1.0.0 will be tagged.

---

## For users — Install (once v1.0.0 is released)

1. Download `MacGet-1.0.0.dmg` from the [Releases page](https://github.com/YOUR-GITHUB-USERNAME/macget/releases/latest).
2. Open the DMG, drag MacGet into your Applications folder.
3. Launch from Applications. (No "unidentified developer" warning — the app is signed and notarized by Apple.)
4. Paste a URL → pick a folder → start downloading.

**Minimum macOS:** 26.4 Tahoe.

---

## For the maintainer — How to open and build this in Xcode

You're starting from a folder of Swift source files, not an Xcode project. Follow these steps **once** to get a working Xcode project, then you only edit the Swift files going forward.

### Step 1 — Install Xcode

Open the Mac App Store, search for **Xcode**, install it (it's a ~12 GB download, free). After install, open Xcode once and accept the license agreement.

### Step 2 — Create a new Xcode project

1. **Xcode → File → New → Project…**
2. Choose template: **macOS → App**, click Next.
3. Fill in:
   - **Product Name:** `MacGet`
   - **Team:** *(leave None for now; you'll set this when you enroll in the Apple Developer Program — see "Releasing")*
   - **Organization Identifier:** `com.suryansh` (or whatever reverse-domain prefix you prefer)
   - **Bundle Identifier:** auto-fills as `com.suryansh.MacGet` — that's fine
   - **Interface:** **SwiftUI**
   - **Language:** **Swift**
   - **Storage:** None
   - **Include Tests:** ☑ checked
4. Click Next, then **save the project to a TEMPORARY location** (e.g., `~/Desktop/MacGet-temp`). You'll throw this away in step 4.

### Step 3 — Replace Xcode's boilerplate with the source files in this repo

Xcode's wizard creates `MacGet/MacGetApp.swift`, `ContentView.swift`, etc. We're going to swap them for the files in this repository.

1. **Quit Xcode.**
2. In Finder, open the temporary `~/Desktop/MacGet-temp/MacGet/` folder. Delete the `MacGet/` *subfolder* (the one with `MacGetApp.swift`, `ContentView.swift`, `Assets.xcassets`, `MacGet.entitlements`, etc).
3. Copy the `MacGet/` folder from THIS repository (the one at `/Users/suryansh/Documents/Projects/MacGet/MacGet/`) into the same place.
4. Reopen the project in Xcode. Some files will show in red (Xcode "lost" them).
5. **Right-click the project root in Xcode's left sidebar → Add Files to "MacGet"… → select the `MacGet/` folder → make sure "Create groups" is selected and "Copy items if needed" is OFF** (you don't want to duplicate files; they're already on disk where Xcode wants them).
6. Repeat for `MacGetTests/`.

### Step 4 — Move everything into the canonical location

You don't *have* to keep the project at `~/Desktop/MacGet-temp`. Quit Xcode, move the entire `MacGet-temp` folder to wherever you want (suggested: `/Users/suryansh/Documents/Projects/MacGet-build/`), and reopen the `.xcodeproj`. Xcode tracks files by relative path; moves are fine.

> Tip: long-term, the `.xcodeproj` lives in your repo right next to the `MacGet/` folder. The reason we keep the source files in `/Users/suryansh/Documents/Projects/MacGet/MacGet/` (this repo) is so they're under git. The `.xcodeproj` itself can also be committed.

### Step 5 — Add the Sparkle dependency (for auto-updates)

1. **Xcode → File → Add Package Dependencies…**
2. Paste the URL: `https://github.com/sparkle-project/Sparkle`
3. Dependency Rule: **Up to Next Major Version**, version `2.6.0` (or newer).
4. Click "Add Package", then on the next screen, make sure the **Sparkle** library is checked for the **MacGet** target. Click "Add Package".

### Step 6 — Configure Info.plist and entitlements

1. In Xcode's left sidebar click the project root → select the **MacGet** target → **Info** tab.
2. Add these custom keys (right-click → Add Row):
   - `SUFeedURL` (String) = `https://YOUR-GITHUB-USERNAME.github.io/macget/appcast.xml`
   - `SUEnableInstallerLauncherService` (Boolean) = YES
   - `SUPublicEDKey` (String) = *(leave empty for now; fill in when you set up Sparkle keys later)*
   - `NSAppTransportSecurity` (Dictionary) → expand → add child `NSAllowsArbitraryLoads` (Boolean) = YES *(needed because we download arbitrary HTTP URLs)*
3. **Signing & Capabilities** tab → click **+ Capability** → search and add **Hardened Runtime**. Under it, expand "Runtime Exceptions" and check **Disable Library Validation** (Sparkle needs this).
4. **Remove App Sandbox** if it's there (we are NOT shipping to the Mac App Store).

### Step 7 — Build and run

Hit **⌘R** (Product → Run). The MacGet window should appear. Try pasting a download URL and clicking Add.

---

## Project layout

```
MacGet/                    ← repo root
├── MacGet/                ← Swift source (drag this into Xcode)
│   ├── MacGetApp.swift    ← @main app entry
│   ├── App/               ← AppDelegate, environment
│   ├── Models/            ← Download, Chunk, Status, Settings
│   ├── Persistence/       ← JSON queue store
│   ├── Engine/            ← ★ multi-threaded download engine (the core)
│   │   ├── DownloadEngine.swift
│   │   ├── DownloadCoordinator.swift
│   │   ├── ChunkWorker.swift
│   │   ├── RangeProbe.swift
│   │   ├── ChunkPlanner.swift
│   │   ├── FileWriter.swift
│   │   ├── SpeedMeter.swift
│   │   └── URLSessionFactory.swift
│   ├── Services/          ← Clipboard watcher, filename resolver, disk check, settings
│   ├── Updater/           ← Sparkle wrapper
│   ├── ViewModels/        ← @Observable view models
│   ├── Views/             ← SwiftUI views
│   ├── Resources/         ← Assets.xcassets, Info.plist
│   └── Supporting/        ← os.Logger setup
├── MacGetTests/           ← unit + integration tests
├── scripts/
│   └── release.sh         ← one-command release: build → DMG → notarize → staple
├── site/
│   └── index.html         ← landing page (deploy via GitHub Pages)
├── LICENSE                ← MIT
├── README.md              ← you are here
└── .gitignore
```

The "★ engine" folder is where the interesting work lives. Everything else is glue.

---

## Learning Swift from zero

If you've never written Swift before, do these in order before touching the engine code:

1. **Apple [Swift Tour](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/guidedtour/)** — 1 day, just skim
2. **[100 Days of SwiftUI](https://www.hackingwithswift.com/100/swiftui)** by Paul Hudson — Days 1–60 minimum (free)
3. **[Swift Concurrency by Example](https://www.hackingwithswift.com/quick-start/concurrency)** — async/await, actors, task groups (the engine uses all of these)
4. **[Apple URLSession docs](https://developer.apple.com/documentation/foundation/urlsession)** + Donny Wals's URLSession articles

Realistic time: 6–8 weeks part-time, 2–3 weeks full-time before you can read the engine code fluently.

---

## Releasing (when you're ready)

1. **One-time:** Enroll in the [Apple Developer Program](https://developer.apple.com/programs/) ($99/yr, individual). Generate a "Developer ID Application" certificate, install in Keychain.
2. **One-time:** Generate Sparkle EdDSA keys with Sparkle's `bin/generate_keys`, copy the public key into Info.plist's `SUPublicEDKey`. **Back up the private key offline.**
3. **One-time:** `xcrun notarytool store-credentials "macget-notary"` to save your Apple ID + app-specific password in Keychain.
4. **Per release:** bump version in Xcode → run `scripts/release.sh` → push the new DMG to GitHub Releases → update `appcast.xml` on GitHub Pages.

See `scripts/release.sh` for the exact commands.

---

## Contributing

Issues and PRs welcome. The `Engine/` directory is the high-stakes code; please include unit tests for any change there.

---

## License

MIT. See [LICENSE](LICENSE).

If MacGet saves you time, consider [buying me a coffee](https://www.buymeacoffee.com/YOUR-USERNAME) — but it's totally optional. Free is free.
