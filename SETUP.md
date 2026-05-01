# MacGet — Step-by-step setup

Follow each step in order. Don't skip.

---

## Step 1 — Install Xcode

1. Open the **Mac App Store**.
2. Search for **Xcode**. Click **Get** (it's free, ~12 GB download — takes a while).
3. After install completes, open **Xcode** once from Applications.
4. Accept the license agreement.
5. When prompted, install additional required components.

---

## Step 2 — Verify Xcode command-line tools

Open **Terminal** and run:

```bash
xcode-select --install
```

If it says "already installed", you're good. If it opens a dialog, click Install.

---

## Step 3 — Create a new Xcode project

1. In Xcode, click **File → New → Project…** (or `⇧⌘N`).
2. Choose **macOS** at the top, then **App**, then **Next**.
3. Fill in exactly:
   - **Product Name:** `MacGet`
   - **Team:** None (leave for now)
   - **Organization Identifier:** `com.suryansh`
   - **Bundle Identifier:** auto-fills as `com.suryansh.MacGet`
   - **Interface:** **SwiftUI**
   - **Language:** **Swift**
   - **Storage:** None
   - **Include Tests:** ✅ check this
4. Click **Next**.
5. Save the project to **`~/Desktop/MacGet-build`** (a temporary location).
6. Uncheck "Create Git repository on my Mac" (you already have one).
7. Click **Create**.

---

## Step 4 — Quit Xcode completely

1. **Xcode → Quit Xcode** (or `⌘Q`).
2. Wait until it's fully closed.

---

## Step 5 — Replace generated source with the repo files

Open **Terminal** and paste these commands one by one:

```bash
PROJ=~/Desktop/MacGet-build
REPO=/Users/suryansh/Documents/Projects/MacGet
```

```bash
rm -rf "$PROJ/MacGet" "$PROJ/MacGetTests"
```

```bash
ln -s "$REPO/MacGet" "$PROJ/MacGet"
ln -s "$REPO/MacGetTests" "$PROJ/MacGetTests"
```

```bash
ls -la "$PROJ"
```

You should see `MacGet -> /Users/suryansh/...` and `MacGetTests -> /Users/suryansh/...` as symlinks.

---

## Step 6 — Reopen the project in Xcode

1. In Finder, navigate to `~/Desktop/MacGet-build`.
2. Double-click **`MacGet.xcodeproj`**.
3. The left sidebar will show files in **red** (Xcode lost them when we replaced the folder). That's fine.

---

## Step 7 — Re-add the source files to Xcode

1. In Xcode's left sidebar, **right-click on the project root** (`MacGet` at the very top, blue icon).
2. Click **Add Files to "MacGet"…**.
3. Navigate to `~/Desktop/MacGet-build/`.
4. Select the **`MacGet`** folder (the symlink).
5. At the bottom of the dialog:
   - **Copy items if needed:** ❌ uncheck
   - **Create groups:** ✅ select (not "Create folder references")
   - **Add to targets:** ✅ MacGet
6. Click **Add**.
7. Repeat for the **`MacGetTests`** folder, but for **Add to targets** select **MacGetTests** only (not MacGet).
8. The red files should now turn black/blue.

---

## Step 8 — Configure build settings

1. In the left sidebar, click the **project root** (top blue icon).
2. In the middle pane, select the **MacGet target** (under TARGETS).
3. Click the **Build Settings** tab.
4. At the top, click **All** and **Combined**.
5. In the search bar at the top right, search for each setting below and set its value:

| Search for | Value |
|---|---|
| `macOS Deployment Target` | `26.4` |
| `Generate Info.plist File` | `No` |
| `Info.plist File` | `MacGet/Resources/Info.plist` |
| `Code Signing Entitlements` | `MacGet/Resources/MacGet.entitlements` |
| `Enable Hardened Runtime` | `Yes` |
| `Swift Language Version` | `Swift 5` |

---

## Step 9 — Configure signing & capabilities

1. Still on the **MacGet target**, click the **Signing & Capabilities** tab.
2. Under **Signing**:
   - **Team:** "Sign to Run Locally" (you'll change this when you enroll in Apple Developer Program)
3. If you see an **App Sandbox** capability, click the **×** to remove it.
4. Click **+ Capability** (top left).
5. Search **Hardened Runtime** → double-click to add it.
6. Under Hardened Runtime, expand **Runtime Exceptions** and check ✅ **Disable Library Validation**.

---

## Step 10 — Build (skip Sparkle for now)

1. At the top of Xcode, make sure the scheme is set to **MacGet** and destination is **My Mac**.
2. Press **⌘B** (Product → Build).
3. Wait for "Build Succeeded".

If you see errors, paste them in chat and I'll fix.

---

## Step 11 — Run

1. Press **⌘R** (Product → Run).
2. The MacGet window opens.
3. Click the **+** button in the toolbar.
4. Paste a test URL: `https://speed.hetzner.de/100MB.bin`
5. Click **Add**.
6. Watch it download in 8 parallel threads.
7. When done, ⌘-click the row → **Show in Finder**.

---

## Step 12 — Run the unit tests

1. Press **⌘U** (Product → Test).
2. All tests in `ChunkPlannerTests`, `SpeedMeterTests`, `FilenameResolverTests` should pass.

---

## Step 13 — (Later) Add Sparkle for auto-updates

Skip this until you're ready to ship v1.0.0.

1. **File → Add Package Dependencies…**
2. Paste: `https://github.com/sparkle-project/Sparkle`
3. Dependency Rule: **Up to Next Major Version**, starting `2.6.0`
4. Click **Add Package**, then **Add Package** again on the next screen (target = MacGet).
5. Open **`MacGet/Resources/Info.plist`** in Xcode.
6. Edit `SUFeedURL` → replace `YOUR-GITHUB-USERNAME` with your real GitHub username.
7. Generate Sparkle keys (one-time):
   ```bash
   cd ~/Library/Developer/Xcode/DerivedData/MacGet-*/SourcePackages/artifacts/sparkle/Sparkle/bin
   ./generate_keys
   ```
   Copy the public key it prints. **Back up the private key (in your login Keychain) somewhere safe.**
8. In Info.plist, paste the public key into `SUPublicEDKey`.
9. Build & run again — auto-updates are now wired up.

---

## Step 14 — (Later) Ship a notarized DMG

When you're ready to publish v1.0.0:

1. Enroll in **Apple Developer Program** at https://developer.apple.com/programs/ ($99/yr).
2. Create a **Developer ID Application** certificate, install in Keychain.
3. In Xcode → Signing & Capabilities → set your Team to your Developer ID team.
4. Run:
   ```bash
   xcrun notarytool store-credentials "macget-notary" \
       --apple-id "you@example.com" \
       --team-id "YOUR-TEAM-ID" \
       --password "<app-specific-password from appleid.apple.com>"
   ```
5. Install create-dmg:
   ```bash
   brew install create-dmg
   ```
6. From the repo root, run:
   ```bash
   ./scripts/release.sh
   ```
7. Upload the DMG from `dist/` to a GitHub Release.
8. Push `site/` to GitHub Pages.

---

## Troubleshooting

**"Build failed" with red errors in Xcode:** Open the Issue Navigator (⌘5), click the error, see the line. Most likely a missing import or a Swift version mismatch. Paste the error in chat.

**App opens but won't connect to the internet:** Check Step 9 — App Sandbox must be **OFF**.

**"Unidentified developer" warning when running:** Normal during development. Right-click the app → Open. Once you sign with Developer ID + notarize, this goes away for end users.

**Tests fail to find `@testable import MacGet`:** Click the test target → Build Phases → make sure `Host Application` is set to MacGet.

**Files appear red in Xcode after a `git pull`:** They probably moved on disk. Right-click → Delete (Remove Reference, not Move to Trash) → re-add via Step 7.
