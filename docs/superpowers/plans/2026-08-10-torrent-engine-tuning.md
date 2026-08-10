# Torrent Engine Tuning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise BitTorrent throughput by correcting aria2's peer-discovery ceiling, plumbing peer/encryption/disk settings that were hardwired or missing, and injecting public trackers into non-private torrents.

**Architecture:** All work flows through the existing `AppSettings` → `TorrentEngineOptions` → `Aria2Daemon.arguments` pipeline. `Aria2Daemon.arguments` is `static` and pure, so nearly the whole change is unit-testable without launching a process — that property must survive. Two new pure types are added: `TorrentMetainfo` (a minimal bencode reader that answers "is this torrent private?") and `TorrentTrackers` (the bundled tracker list and the gate that suppresses it).

**Tech Stack:** Swift 6, SwiftUI, XCTest, actors. External process: aria2c 1.37.0 (Homebrew, not bundled).

**Spec:** `docs/superpowers/specs/2026-08-10-torrent-performance-design.md`

**Companion plan:** `docs/superpowers/plans/2026-08-10-torrent-port-mapping.md` implements the inbound-reachability subsystem (`PortMapper`) and the Connectivity UI row. This plan does **not** depend on it and can ship alone. `AppSettings.torrentAutoPortMapping` is added here (Task 1) so both plans share one settings migration; it is unused until the companion plan lands.

## Global Constraints

- **Build/test from the CLI requires `DEVELOPER_DIR`.** The active developer dir is CommandLineTools, so bare `xcodebuild` fails with "tool 'xcodebuild' requires Xcode". Every command in this plan is already prefixed. Never run `sudo xcode-select`.
- **New `.swift` files need no `project.pbxproj` edit.** The project uses Xcode 16 `PBXFileSystemSynchronizedRootGroup`, so files dropped into `Macget/**` or `MacgetTests/` are picked up automatically.
- **Logging:** use `Log.app/engine/ui/net` from `Supporting/Logger+MacGet.swift`, or a `Logger(subsystem: "com.macget", category: …)` as the torrent files already do. Never `print`.
- **New persisted state must stay `Codable` and `Sendable`.**
- **`AppSettings` has a hand-written `init(from:)`** so a `settings.json` written before a field existed still loads. Every new field must be added there with `decodeIfPresent` against a defaults instance, or older installs reset their settings.
- **Naming:** technical identifiers are `Macget`; only human-facing brand text is `MacGet`.
- **aria2 version floor:** 1.37.0. Every flag used here was verified against that binary.
- **Threads/peers clamps:** `torrentMaxPeers` clamps to `1...500`, matching the clamp already inside `TorrentEngineOptions.init`.

**Test command (single class):**
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/<ClassName>
```

**Reading failures:** `xcodebuild` output shows only `Test case '…' failed`, never the assertion text. Get it from the `.xcresult` bundle printed near the end of the log:
```bash
xcrun xcresulttool get test-results tests --path <…>.xcresult --format json
```
then walk `testNodes` for `nodeType: "Failure Message"`. Also note `MacgetTests` emits lowercase `Test case '…' passed` while `MacgetUITests` uses `Test Case '-[…]'` — grep case-insensitively.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Macget/Models/AppSettings.swift` | Modify | Four new persisted torrent fields + clamps + decode |
| `Macget/Engine/Torrent/Aria2Daemon.swift` | Modify | New launch flags; `TorrentEngineOptions` fields; IPv6 address discovery |
| `Macget/Engine/Torrent/TorrentMetainfo.swift` | Create | Minimal bencode reader; extracts the `private` flag |
| `Macget/Engine/Torrent/TorrentTrackers.swift` | Create | Bundled tracker list + injection gate |
| `Macget/Engine/Torrent/TorrentJob.swift` | Modify | Per-download `bt-tracker`; drop trackers when a magnet resolves private |
| `Macget/Views/TorrentSettingsView.swift` | Modify | Performance section + global-speed-limit warning |
| `MacgetTests/TorrentPerformanceSettingsTests.swift` | Create | Settings defaults, clamps, forward-compatible decode |
| `MacgetTests/TorrentTests.swift` | Modify | Extend `Aria2DaemonTests` with the new flag assertions |
| `MacgetTests/TorrentMetainfoTests.swift` | Create | Bencode parsing, including the `pieces` collision regression |
| `MacgetTests/TorrentTrackersTests.swift` | Create | Injection gate |

---

## Task 1: Settings fields

**Files:**
- Modify: `Macget/Models/AppSettings.swift`
- Test: `MacgetTests/TorrentPerformanceSettingsTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `AppSettings.torrentMaxPeers: Int` (default 200, clamp `1...500`), `AppSettings.torrentAddPublicTrackers: Bool` (default `true`), `AppSettings.torrentRequireEncryption: Bool` (default `false`), `AppSettings.torrentAutoPortMapping: Bool` (default `true`). All four are `init` parameters in that order, placed **after** `torrentVerifyOnResume`.

- [ ] **Step 1: Write the failing test**

Create `MacgetTests/TorrentPerformanceSettingsTests.swift`:

```swift
import XCTest
@testable import Macget

final class TorrentPerformanceSettingsTests: XCTestCase {

    func test_defaultsMatchTheDesignedPerformanceProfile() {
        let settings = AppSettings()
        XCTAssertEqual(settings.torrentMaxPeers, 200)
        XCTAssertTrue(settings.torrentAddPublicTrackers)
        XCTAssertFalse(settings.torrentRequireEncryption, "encryption is opt-in: requiring it shrinks the peer pool")
        XCTAssertTrue(settings.torrentAutoPortMapping)
    }

    func test_maxPeersClampsToSupportedRange() {
        XCTAssertEqual(AppSettings(torrentMaxPeers: 0).torrentMaxPeers, 1)
        XCTAssertEqual(AppSettings(torrentMaxPeers: 9_000).torrentMaxPeers, 500)
        XCTAssertEqual(AppSettings(torrentMaxPeers: 250).torrentMaxPeers, 250)
    }

    /// A settings.json written before these fields existed must still load with
    /// everything else intact — the entire reason `init(from:)` is hand-written.
    func test_settingsFileWithoutTheNewKeysLoadsWithDefaults() throws {
        let json = Data(#"{"torrentListenPort":7000,"torrentsEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(settings.torrentListenPort, 7000)
        XCTAssertTrue(settings.torrentsEnabled)
        XCTAssertEqual(settings.torrentMaxPeers, 200)
        XCTAssertTrue(settings.torrentAddPublicTrackers)
        XCTAssertFalse(settings.torrentRequireEncryption)
        XCTAssertTrue(settings.torrentAutoPortMapping)
    }

    func test_roundTripsThroughCodable() throws {
        let original = AppSettings(
            torrentMaxPeers: 321,
            torrentAddPublicTrackers: false,
            torrentRequireEncryption: true,
            torrentAutoPortMapping: false
        )
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.torrentMaxPeers, 321)
        XCTAssertFalse(decoded.torrentAddPublicTrackers)
        XCTAssertTrue(decoded.torrentRequireEncryption)
        XCTAssertFalse(decoded.torrentAutoPortMapping)
    }

    /// A clamp applied in `init` but not in `init(from:)` lets a hand-edited
    /// settings.json smuggle an out-of-range value straight into aria2.
    func test_decodeClampsOutOfRangeMaxPeers() throws {
        let json = Data(#"{"torrentMaxPeers":9000}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: json).torrentMaxPeers, 500)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/TorrentPerformanceSettingsTests
```
Expected: compile failure — `value of type 'AppSettings' has no member 'torrentMaxPeers'`.

- [ ] **Step 3: Add the stored properties**

In `Macget/Models/AppSettings.swift`, immediately after the `torrentVerifyOnResume` declaration (currently ending at line 62):

```swift
    /// Maximum peer connections per torrent. aria2's own default is 55; MacGet
    /// previously hardwired 100 and never let the user reach it. Clamped 1...500.
    var torrentMaxPeers: Int
    /// Inject a bundled list of public trackers into non-private torrents. The
    /// main fix for magnets whose own trackers are dead.
    var torrentAddPublicTrackers: Bool
    /// Refuse peers that won't encrypt. Defeats ISP BitTorrent shaping at the
    /// cost of a smaller peer pool, so it's opt-in.
    var torrentRequireEncryption: Bool
    /// Ask the router to forward `torrentListenPort` via PCP/NAT-PMP.
    var torrentAutoPortMapping: Bool
```

- [ ] **Step 4: Add the init parameters and clamps**

In the same file, add these parameters at the **end** of the `init` signature, after `torrentVerifyOnResume: Bool = false` (add a comma to that line):

```swift
        torrentMaxPeers: Int = 200,
        torrentAddPublicTrackers: Bool = true,
        torrentRequireEncryption: Bool = false,
        torrentAutoPortMapping: Bool = true
```

and these assignments at the end of the `init` body, after `self.torrentVerifyOnResume = torrentVerifyOnResume`:

```swift
        self.torrentMaxPeers = max(1, min(500, torrentMaxPeers))
        self.torrentAddPublicTrackers = torrentAddPublicTrackers
        self.torrentRequireEncryption = torrentRequireEncryption
        self.torrentAutoPortMapping = torrentAutoPortMapping
```

- [ ] **Step 5: Add the decode lines**

At the end of `init(from decoder:)`, after the `torrentVerifyOnResume` line:

```swift
        torrentMaxPeers = max(1, min(500, try c.decodeIfPresent(Int.self, forKey: .torrentMaxPeers) ?? defaults.torrentMaxPeers))
        torrentAddPublicTrackers = try c.decodeIfPresent(Bool.self, forKey: .torrentAddPublicTrackers) ?? defaults.torrentAddPublicTrackers
        torrentRequireEncryption = try c.decodeIfPresent(Bool.self, forKey: .torrentRequireEncryption) ?? defaults.torrentRequireEncryption
        torrentAutoPortMapping = try c.decodeIfPresent(Bool.self, forKey: .torrentAutoPortMapping) ?? defaults.torrentAutoPortMapping
```

`CodingKeys` is compiler-synthesized for `AppSettings` (there is no explicit enum), so the new keys appear automatically. Do not add one.

- [ ] **Step 6: Run test to verify it passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/TorrentPerformanceSettingsTests
```
Expected: PASS (5 tests).

- [ ] **Step 7: Commit**

```bash
git add Macget/Models/AppSettings.swift MacgetTests/TorrentPerformanceSettingsTests.swift
git commit -m "feat(torrent): add peer, tracker, encryption and port-mapping settings"
```

---

## Task 2: Peer-discovery ceiling and peer limit

**Files:**
- Modify: `Macget/Engine/Torrent/Aria2Daemon.swift`
- Test: `MacgetTests/TorrentTests.swift` (extend the existing `Aria2DaemonTests` class, which starts at line 209)

**Interfaces:**
- Consumes: `AppSettings.torrentMaxPeers` from Task 1.
- Produces: `TorrentEngineOptions.init(settings:)` now populates `maxPeers`. No signature change.

This is the highest-value task in the plan. `--bt-request-peer-speed-limit` is the rate above which aria2 **stops looking for more peers**. It is a discovery ceiling, not a bandwidth cap, so raising it costs nothing on a slow link — a slow link never reaches the threshold either way.

- [ ] **Step 1: Write the failing test**

Add to `Aria2DaemonTests` in `MacgetTests/TorrentTests.swift`:

```swift
    /// aria2 stops seeking new peers once a torrent exceeds this rate. The old
    /// value was 10M — about 80 Mbps — so on a gigabit link peer discovery
    /// stopped at 8% of capacity. That is aria2's own 50K dial-up-era default
    /// reproduced ~200x further up the scale. 100M is above any consumer link.
    func test_peerDiscoveryCeilingIsAboveAnyConsumerLink() {
        XCTAssertTrue(args().contains("--bt-request-peer-speed-limit=100M"))
    }

    /// `bt-max-peers` was hardwired at 100: `TorrentEngineOptions.init(settings:)`
    /// never passed `maxPeers`, so the field was unreachable from settings.
    func test_maxPeersComesFromSettingsRatherThanBeingHardwired() {
        XCTAssertTrue(args(TorrentEngineOptions(maxPeers: 321)).contains("--bt-max-peers=321"))
        XCTAssertEqual(AppSettings(torrentMaxPeers: 321).torrentOptions.maxPeers, 321)
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/Aria2DaemonTests
```
Expected: FAIL — `test_peerDiscoveryCeilingIsAboveAnyConsumerLink` (still 10M) and `test_maxPeersComesFromSettingsRatherThanBeingHardwired` (options report 100).

- [ ] **Step 3: Raise the ceiling**

In `Aria2Daemon.arguments`, replace the `--bt-request-peer-speed-limit` line and update the comment block above it:

```swift
            // aria2's defaults are tuned for a much slower era.
            //
            // `--bt-request-peer-speed-limit` is the consequential one: aria2
            // stops looking for more peers once a torrent exceeds it. The
            // default is 50K, which caps discovery at dial-up speed — but 10M
            // is only ~80 Mbps, so it reproduced the same defect on any
            // gigabit link. 100M is above any consumer connection, so aria2
            // keeps hunting until the pipe is genuinely full. It is a
            // discovery ceiling, not a bandwidth cap: a slow link never
            // reaches it either way, so raising it costs nothing there.
            "--bt-max-peers=\(options.maxPeers)",
            "--bt-request-peer-speed-limit=100M",
```

- [ ] **Step 4: Plumb `maxPeers` from settings**

In `TorrentEngineOptions.init(settings:)`, add the `maxPeers` argument (it is currently absent, so the default 100 always won):

```swift
    init(settings: AppSettings) {
        self.init(
            seedRatio: settings.torrentSeedRatio,
            seedMinutes: settings.torrentSeedMinutes,
            listenPort: settings.torrentListenPort,
            dhtEnabled: settings.torrentDHTEnabled,
            maxUploadBytesPerSec: settings.torrentMaxUploadBytesPerSec,
            maxDownloadBytesPerSec: settings.globalSpeedLimitBytesPerSec,
            maxPeers: settings.torrentMaxPeers,
            verifyOnResume: settings.torrentVerifyOnResume
        )
    }
```

Also update the `maxPeers` doc comment on the stored property to reflect that it is now user-controlled:

```swift
    /// Maximum peer connections per torrent, from `AppSettings.torrentMaxPeers`.
    /// aria2's own default is 55, which leaves a healthy swarm underused.
    var maxPeers: Int = 200
```

and change the `init` default to match (`maxPeers: Int = 200`), so a directly-constructed `TorrentEngineOptions()` agrees with `AppSettings()`.

- [ ] **Step 5: Run test to verify it passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/Aria2DaemonTests
```
Expected: PASS, including all pre-existing tests in the class.

- [ ] **Step 6: Commit**

```bash
git add Macget/Engine/Torrent/Aria2Daemon.swift MacgetTests/TorrentTests.swift
git commit -m "fix(torrent): raise peer-discovery ceiling to 100M and plumb max peers"
```

---

## Task 3: IPv6 DHT

**Files:**
- Modify: `Macget/Engine/Torrent/Aria2Daemon.swift`
- Test: `MacgetTests/TorrentTests.swift` (`Aria2DaemonTests`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Aria2Daemon.arguments(port:secret:options:ipv6DHTAddress:)` — the fourth parameter is `String? = nil`, so every existing call site keeps compiling. `Aria2Daemon.globalUnicastIPv6Address() -> String?`.

**There is no `--dht-listen-port6`.** `--dht-listen-port` covers IPv4 DHT, IPv6 DHT, and UDP trackers. Passing a `port6` variant makes aria2 reject the argument and the daemon never starts, breaking torrents entirely. IPv6 DHT is selected by `--enable-dht6` plus `--dht-listen-addr6`, which aria2 documents as needing "a global unicast IPv6 address of the host".

- [ ] **Step 1: Write the failing test**

First change the existing private helper at the top of `Aria2DaemonTests` (line ~211) to accept an address, keeping its default so the other tests are untouched:

```swift
    private func args(_ options: TorrentEngineOptions = .init(), ipv6: String? = nil) -> [String] {
        Aria2Daemon.arguments(port: 12345, secret: "abc", options: options, ipv6DHTAddress: ipv6)
    }
```

Then add:

```swift
    /// IPv6 DHT needs the setting *and* a bind address. With the switch but no
    /// address aria2 still starts, so the flag would silently imply a working
    /// feature — claim neither instead.
    func test_ipv6DHTNeedsBothTheSettingAndAnAddress() {
        let both = args(TorrentEngineOptions(dhtEnabled: true), ipv6: "2001:db8::1")
        XCTAssertTrue(both.contains("--enable-dht6=true"))
        XCTAssertTrue(both.contains("--dht-listen-addr6=2001:db8::1"))

        let noAddress = args(TorrentEngineOptions(dhtEnabled: true), ipv6: nil)
        XCTAssertFalse(noAddress.contains { $0.hasPrefix("--enable-dht6") })
        XCTAssertFalse(noAddress.contains { $0.hasPrefix("--dht-listen-addr6") })

        let dhtOff = args(TorrentEngineOptions(dhtEnabled: false), ipv6: "2001:db8::1")
        XCTAssertFalse(dhtOff.contains { $0.hasPrefix("--enable-dht6") })
        XCTAssertFalse(dhtOff.contains { $0.hasPrefix("--dht-listen-addr6") })
    }

    /// `--dht-listen-port6` does not exist in aria2. Passing it makes aria2
    /// reject the argument, the daemon never starts, and every torrent fails.
    /// This test exists purely to stop it being reintroduced.
    func test_neverEmitsTheNonexistentIPv6DHTPortFlag() {
        let a = args(TorrentEngineOptions(dhtEnabled: true), ipv6: "2001:db8::1")
        XCTAssertFalse(a.contains { $0.hasPrefix("--dht-listen-port6") })
    }

    /// Whatever this machine reports must be a real global unicast address
    /// (2000::/3) or nil — never a link-local, which aria2 rejects as a bind
    /// address. Machines without IPv6 legitimately return nil.
    func test_discoveredIPv6AddressIsGlobalUnicastOrNil() {
        guard let address = Aria2Daemon.globalUnicastIPv6Address() else { return }
        XCTAssertFalse(address.lowercased().hasPrefix("fe80"), "link-local is not bindable for DHT")
        XCTAssertFalse(address.hasPrefix("::1"))
        XCTAssertTrue(address.contains(":"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/Aria2DaemonTests
```
Expected: compile failure — `extra argument 'ipv6DHTAddress' in call` and no member `globalUnicastIPv6Address`.

- [ ] **Step 3: Add the address discovery**

Add to `Aria2Daemon`, in the `// MARK: - Launch configuration` section:

```swift
    /// This host's first global unicast IPv6 address, or nil if it has none.
    ///
    /// `--enable-dht6` is inert without `--dht-listen-addr6`, which aria2
    /// documents as requiring "a global unicast IPv6 address of the host" — not
    /// a range, and not something MacGet can hardcode.
    ///
    /// Temporary/privacy addresses are deliberately *not* filtered out:
    /// distinguishing them needs a `SIOCGIFAFLAG_IN6` ioctl, and a temporary
    /// address binds DHT just as well as a stable one.
    static func globalUnicastIPv6Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let raw = interface.ifa_addr,
                  raw.pointee.sa_family == UInt8(AF_INET6) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var address = UnsafeRawPointer(raw)
                .assumingMemoryBound(to: sockaddr_in6.self).pointee

            // Global unicast is 2000::/3. This single mask also excludes
            // link-local (fe80::/10), unique-local (fc00::/7) and multicast
            // (ff00::/8) — none of which aria2 can bind DHT to.
            guard address.sin6_addr.__u6_addr.__u6_addr8.0 & 0xe0 == 0x20 else { continue }

            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil
            else { continue }
            return String(cString: buffer)
        }
        return nil
    }
```

If the compiler cannot find `getifaddrs`/`IFF_UP`, add `import Darwin` at the top of the file alongside `import Foundation`.

- [ ] **Step 4: Change the arguments signature and the DHT block**

Change the signature:

```swift
    static func arguments(
        port: Int,
        secret: String,
        options: TorrentEngineOptions,
        ipv6DHTAddress: String? = nil
    ) -> [String] {
```

Replace the existing DHT block (currently `if options.dhtEnabled { args.append("--dht-listen-port=…") }`) with:

```swift
        if options.dhtEnabled {
            // One port covers IPv4 DHT, IPv6 DHT and UDP trackers. There is no
            // `--dht-listen-port6`; aria2 rejects it and never starts.
            args.append("--dht-listen-port=\(Self.portRange(from: options.listenPort))")
            if let ipv6DHTAddress {
                args.append("--enable-dht6=true")
                args.append("--dht-listen-addr6=\(ipv6DHTAddress)")
            }
        }
```

- [ ] **Step 5: Pass the discovered address at launch**

In `start(options:)`, change the arguments call:

```swift
        process.arguments = Self.arguments(
            port: port,
            secret: secret,
            options: options,
            ipv6DHTAddress: Self.globalUnicastIPv6Address()
        )
```

The address is captured at launch and does not follow network changes — a Mac that gains IPv6 later picks it up at the next daemon start, exactly as the listening port already behaves.

- [ ] **Step 6: Run test to verify it passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/Aria2DaemonTests
```
Expected: PASS. The pre-existing `test_dhtPortOnlyWhenDHTEnabled` must still pass.

- [ ] **Step 7: Commit**

```bash
git add Macget/Engine/Torrent/Aria2Daemon.swift MacgetTests/TorrentTests.swift
git commit -m "feat(torrent): enable IPv6 DHT when the host has a global address"
```

---

## Task 4: Peer encryption

**Files:**
- Modify: `Macget/Engine/Torrent/Aria2Daemon.swift`
- Test: `MacgetTests/TorrentTests.swift` (`Aria2DaemonTests`)

**Interfaces:**
- Consumes: `AppSettings.torrentRequireEncryption` from Task 1.
- Produces: `TorrentEngineOptions.requireEncryption: Bool` (default `false`), added as an `init` parameter **after** `maxPeers` and before `verifyOnResume`.

- [ ] **Step 1: Write the failing test**

```swift
    /// `arc4` costs nothing: plaintext peers are still accepted, so no peer is
    /// lost, while the handshake stops being trivially identifiable by DPI.
    func test_prefersObfuscatedHandshakeByDefaultWithoutLosingPlaintextPeers() {
        let a = args()
        XCTAssertTrue(a.contains("--bt-min-crypto-level=arc4"))
        XCTAssertFalse(a.contains { $0.hasPrefix("--bt-require-crypto") })
        XCTAssertFalse(a.contains { $0.hasPrefix("--bt-force-encryption") })
    }

    /// Opt-in, because refusing plaintext peers shrinks the pool.
    func test_requiringEncryptionRefusesPlaintextPeers() {
        let a = args(TorrentEngineOptions(requireEncryption: true))
        XCTAssertTrue(a.contains("--bt-require-crypto=true"))
        XCTAssertTrue(a.contains("--bt-force-encryption=true"))
        XCTAssertTrue(a.contains("--bt-min-crypto-level=arc4"))
    }

    func test_encryptionRequirementComesFromSettings() {
        XCTAssertTrue(AppSettings(torrentRequireEncryption: true).torrentOptions.requireEncryption)
        XCTAssertFalse(AppSettings().torrentOptions.requireEncryption)
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/Aria2DaemonTests
```
Expected: compile failure — no member `requireEncryption`.

- [ ] **Step 3: Add the option field**

In `TorrentEngineOptions`, after the `maxPeers` property:

```swift
    /// Refuse peers that won't encrypt. Defeats ISP BitTorrent shaping, at the
    /// cost of dropping every peer that only speaks plaintext.
    var requireEncryption: Bool = false
```

Add `requireEncryption: Bool = false,` to the memberwise `init` signature after `maxPeers: Int = 200,`, and `self.requireEncryption = requireEncryption` to its body after the `maxPeers` assignment.

Add to `init(settings:)`, after `maxPeers:`:

```swift
            requireEncryption: settings.torrentRequireEncryption,
```

- [ ] **Step 4: Add the flags**

In `Aria2Daemon.arguments`, add to the base `args` array (next to the other BitTorrent flags):

```swift
            // Prefer an obfuscated handshake always. Plaintext peers are still
            // accepted at this level, so it costs no peers — it just stops the
            // BitTorrent handshake being a free signature for DPI.
            "--bt-min-crypto-level=arc4",
```

and after the `verifyOnResume` block:

```swift
        // Opt-in: this drops every peer that won't encrypt, so it trades peers
        // for invisibility. Worth it only where an ISP is actively shaping.
        if options.requireEncryption {
            args.append("--bt-require-crypto=true")
            args.append("--bt-force-encryption=true")
        }
```

- [ ] **Step 5: Run test to verify it passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/Aria2DaemonTests
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Macget/Engine/Torrent/Aria2Daemon.swift MacgetTests/TorrentTests.swift
git commit -m "feat(torrent): prefer encrypted handshakes, add opt-in strict mode"
```

---

## Task 5: Disk cache, seed detaching, and the concurrency limit

**Files:**
- Modify: `Macget/Engine/Torrent/Aria2Daemon.swift`
- Test: `MacgetTests/TorrentTests.swift` (`Aria2DaemonTests`)

**Interfaces:**
- Consumes: `AppSettings.maxConcurrentDownloads` (already exists, clamped `1...16`).
- Produces: `TorrentEngineOptions.maxConcurrentDownloads: Int` (default 5), added as an `init` parameter after `requireEncryption`. `mutableGlobalOptions` gains the key `"max-concurrent-downloads"`.

`max-concurrent-downloads` goes in `mutableGlobalOptions` rather than the static flag list because `arguments` already appends every mutable option at launch **and** `applyOptions` pushes them to a live daemon — one declaration gets both.

- [ ] **Step 1: Write the failing test**

```swift
    func test_diskCacheAndMmapAreTunedForModernDisks() {
        let a = args()
        XCTAssertTrue(a.contains("--disk-cache=128M"))
        // Safe specifically because --file-allocation=falloc preallocates; aria2's
        // documented mmap failure mode is unallocated space.
        XCTAssertTrue(a.contains("--enable-mmap=true"))
        XCTAssertTrue(a.contains("--file-allocation=falloc"))
    }

    /// macOS's default soft RLIMIT_NOFILE is 256 and Foundation.Process offers no
    /// clean way to raise it for the child, so a bigger value would simply fail
    /// at open() time on a many-file torrent — worse than the default it replaced.
    func test_leavesMaxOpenFilesAtAria2Default() {
        XCTAssertFalse(args().contains { $0.hasPrefix("--bt-max-open-files") })
    }

    /// A torrent that has finished downloading and is only seeding must stop
    /// occupying a slot, or a completed torrent blocks a queued one.
    func test_seedingTorrentsDoNotOccupyDownloadSlots() {
        XCTAssertTrue(args().contains("--bt-detach-seed-only=true"))
    }

    /// aria2's own default is 5. With more than five active torrents it silently
    /// queued the rest while MacGet's rows claimed they were running at 0 B/s.
    func test_concurrencyLimitTracksTheAppSetting() {
        let options = AppSettings(maxConcurrentDownloads: 9).torrentOptions
        XCTAssertEqual(options.mutableGlobalOptions["max-concurrent-downloads"], "9")
        XCTAssertTrue(Aria2Daemon.arguments(port: 1, secret: "s", options: options)
            .contains("--max-concurrent-downloads=9"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/Aria2DaemonTests
```
Expected: FAIL on disk cache (still 64M), mmap, detach-seed-only, and concurrency.

- [ ] **Step 3: Add the concurrency field**

In `TorrentEngineOptions`, after `requireEncryption`:

```swift
    /// aria2's own default is 5. MacGet's engine allows up to 16 concurrent
    /// downloads, so leaving aria2 at 5 silently queued the rest.
    var maxConcurrentDownloads: Int = 5
```

Add `maxConcurrentDownloads: Int = 5,` to the memberwise `init` after `requireEncryption`, with `self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)` in the body. Add to `init(settings:)`:

```swift
            maxConcurrentDownloads: settings.maxConcurrentDownloads,
```

Extend `mutableGlobalOptions`:

```swift
    var mutableGlobalOptions: [String: String] {
        [
            "max-overall-upload-limit": String(maxUploadBytesPerSec ?? 0),
            "max-overall-download-limit": String(maxDownloadBytesPerSec ?? 0),
            "max-concurrent-downloads": String(maxConcurrentDownloads),
        ]
    }
```

- [ ] **Step 4: Update the disk flags**

In `Aria2Daemon.arguments`, replace `"--disk-cache=64M",` with:

```swift
            "--disk-cache=128M",
            // Safe here because --file-allocation=falloc below preallocates the
            // file; aria2's documented mmap failure mode is unallocated space.
            "--enable-mmap=true",
            // A finished-but-seeding torrent stops counting against
            // --max-concurrent-downloads, so it can't block a queued one.
            "--bt-detach-seed-only=true",
```

Leave `--bt-max-open-files` unset — see the test's comment for why.

- [ ] **Step 5: Run test to verify it passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/Aria2DaemonTests
```
Expected: PASS. Pre-existing `test_mutableOptionsExcludeLaunchOnlySettings` must still pass — the new key contains no "port", "session", or "seed" substring.

- [ ] **Step 6: Commit**

```bash
git add Macget/Engine/Torrent/Aria2Daemon.swift MacgetTests/TorrentTests.swift
git commit -m "fix(torrent): raise disk cache, detach seeding, honour concurrency setting"
```

---

## Task 6: `TorrentMetainfo` — the private flag

**Files:**
- Create: `Macget/Engine/Torrent/TorrentMetainfo.swift`
- Test: `MacgetTests/TorrentMetainfoTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `TorrentMetainfo.isPrivate(_ data: Data) -> Bool`.

aria2 cannot answer this: `aria2.tellStatus`'s `bittorrent` struct exposes only `announceList`, `comment`, `creationDate`, `mode`, and `info.name` — no `private` at any depth. And aria2 will not protect us either: its docs say a private flag disables DHT *regardless of the setting*, but say nothing of the kind for `--bt-tracker`, because a supplied tracker is treated as user intent.

**This must be a real parser, not a byte search.** `info.pieces` is raw concatenated SHA-1 digests — arbitrary binary that will eventually contain the literal bytes `7:privatei1e`. A substring scan would mark such a public torrent private and silently strip the trackers it needed.

- [ ] **Step 1: Write the failing test**

Create `MacgetTests/TorrentMetainfoTests.swift`:

```swift
import XCTest
@testable import Macget

final class TorrentMetainfoTests: XCTestCase {

    /// Builds a minimal but structurally valid metainfo. Bencode dictionary keys
    /// must be sorted, and they are here: announce < info, name < pieces < private.
    private func metainfo(pieces: [UInt8], privateFlag: Int?) -> Data {
        var info = Data("d".utf8)
        info.append(Data("4:name9:test.file".utf8))
        info.append(Data("6:pieces\(pieces.count):".utf8))
        info.append(contentsOf: pieces)
        if let privateFlag {
            info.append(Data("7:privatei\(privateFlag)e".utf8))
        }
        info.append(Data("e".utf8))

        var root = Data("d8:announce19:udp://tracker:1337/4:info".utf8)
        root.append(info)
        root.append(Data("e".utf8))
        return root
    }

    func test_detectsPrivateFlag() {
        XCTAssertTrue(TorrentMetainfo.isPrivate(metainfo(pieces: [1, 2, 3], privateFlag: 1)))
    }

    func test_privateZeroAndMissingKeyBothMeanPublic() {
        XCTAssertFalse(TorrentMetainfo.isPrivate(metainfo(pieces: [1, 2, 3], privateFlag: 0)))
        XCTAssertFalse(TorrentMetainfo.isPrivate(metainfo(pieces: [1, 2, 3], privateFlag: nil)))
    }

    /// The regression this parser exists for. `pieces` is raw SHA-1 output, so it
    /// can contain any byte sequence — including the bencode for a private flag.
    /// A substring scan would call this torrent private and strip the trackers it
    /// needs. Structural parsing skips the payload using its length prefix.
    func test_publicTorrentWhosePiecesContainThePrivateMarkerStaysPublic() {
        let trap = Array("7:privatei1e".utf8)
        let pieces = [UInt8](repeating: 0xAB, count: 8) + trap + [UInt8](repeating: 0xCD, count: 8)
        XCTAssertFalse(TorrentMetainfo.isPrivate(metainfo(pieces: pieces, privateFlag: nil)))
    }

    /// Malformed input must read as public, never crash. Public is the safe
    /// direction: a wrongly-private torrent loses trackers with no visible cause.
    func test_malformedInputIsTreatedAsPublicWithoutCrashing() {
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data()))
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data("not bencode at all".utf8)))
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data("d4:infod7:private".utf8)))       // truncated
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data("d4:infod6:pieces99:ab".utf8)))   // length runs past end
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data("i42e".utf8)))                    // not a dictionary
    }

    /// A hostile file must not blow the stack with nesting alone.
    func test_deeplyNestedInputIsRejectedRatherThanRecursingForever() {
        let depth = 5_000
        let nested = String(repeating: "l", count: depth) + String(repeating: "e", count: depth)
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data(nested.utf8)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/TorrentMetainfoTests
```
Expected: compile failure — cannot find `TorrentMetainfo` in scope.

- [ ] **Step 3: Write the parser**

Create `Macget/Engine/Torrent/TorrentMetainfo.swift`:

```swift
import Foundation

/// Just enough bencode to answer one question: is this torrent private?
///
/// aria2 can't tell us. `aria2.tellStatus`'s `bittorrent` struct carries only
/// announceList / comment / creationDate / mode / info.name — there is no
/// `private` key at any depth — and aria2 won't apply the flag on our behalf
/// either: its docs say `private` disables DHT regardless of the setting, but
/// say nothing of the kind for `--bt-tracker`, because a supplied tracker is
/// treated as user intent it must honour.
///
/// This walks the structure rather than searching bytes, and that is the whole
/// point. `info.pieces` is raw concatenated SHA-1 digests — arbitrary binary
/// that will, given enough torrents, contain the literal bytes `7:privatei1e`.
/// A substring scan would mark such a torrent private and silently strip the
/// trackers it needed. Length prefixes let us skip payloads instead of reading
/// through them.
enum TorrentMetainfo {

    /// Bencode nests arbitrarily; a hostile file shouldn't blow the stack.
    private static let maxDepth = 64

    indirect enum Value {
        case integer(Int)
        case bytes([UInt8])
        case list([Value])
        case dictionary([String: Value])
    }

    /// True only when the metainfo's `info` dictionary carries `private = 1`.
    ///
    /// Malformed input, a missing key, and `private = 0` all read as public.
    /// Public is the safe default: a torrent wrongly treated as private loses
    /// its injected trackers with nothing in the UI to explain why.
    static func isPrivate(_ data: Data) -> Bool {
        guard case .dictionary(let root)? = parse(Array(data), at: 0, depth: 0)?.value,
              case .dictionary(let info)? = root["info"],
              case .integer(let flag)? = info["private"]
        else { return false }
        return flag == 1
    }

    // MARK: - Parsing

    static func parse(_ bytes: [UInt8], at index: Int, depth: Int) -> (value: Value, next: Int)? {
        guard depth <= maxDepth, index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "i"):
            return parseInteger(bytes, at: index)
        case UInt8(ascii: "l"):
            return parseList(bytes, at: index, depth: depth)
        case UInt8(ascii: "d"):
            return parseDictionary(bytes, at: index, depth: depth)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return parseBytes(bytes, at: index)
        default:
            return nil
        }
    }

    private static func parseInteger(_ bytes: [UInt8], at index: Int) -> (Value, Int)? {
        var cursor = index + 1
        var digits = ""
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "e") {
            digits.append(Character(UnicodeScalar(bytes[cursor])))
            cursor += 1
        }
        guard cursor < bytes.count, let value = Int(digits) else { return nil }
        return (.integer(value), cursor + 1)
    }

    /// The load-bearing case: the length prefix lets us jump over the payload
    /// instead of scanning it, so binary content can never be mistaken for
    /// structure.
    private static func parseBytes(_ bytes: [UInt8], at index: Int) -> (Value, Int)? {
        var cursor = index
        var digits = ""
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: ":") {
            digits.append(Character(UnicodeScalar(bytes[cursor])))
            cursor += 1
        }
        guard cursor < bytes.count, let length = Int(digits), length >= 0 else { return nil }
        let start = cursor + 1
        // A hostile length prefix can overflow rather than merely run past the end.
        let (end, overflowed) = start.addingReportingOverflow(length)
        guard !overflowed, end <= bytes.count else { return nil }
        return (.bytes(Array(bytes[start..<end])), end)
    }

    private static func parseList(_ bytes: [UInt8], at index: Int, depth: Int) -> (Value, Int)? {
        var cursor = index + 1
        var items: [Value] = []
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "e") {
            guard let (value, next) = parse(bytes, at: cursor, depth: depth + 1) else { return nil }
            items.append(value)
            cursor = next
        }
        guard cursor < bytes.count else { return nil }
        return (.list(items), cursor + 1)
    }

    private static func parseDictionary(_ bytes: [UInt8], at index: Int, depth: Int) -> (Value, Int)? {
        var cursor = index + 1
        var entries: [String: Value] = [:]
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "e") {
            guard let (keyValue, afterKey) = parseBytes(bytes, at: cursor),
                  case .bytes(let keyBytes) = keyValue,
                  let (value, afterValue) = parse(bytes, at: afterKey, depth: depth + 1)
            else { return nil }
            // Keys are conventionally UTF-8; a key that isn't is not one we look for.
            if let key = String(bytes: keyBytes, encoding: .utf8) {
                entries[key] = value
            }
            cursor = afterValue
        }
        guard cursor < bytes.count else { return nil }
        return (.dictionary(entries), cursor + 1)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/TorrentMetainfoTests
```
Expected: PASS (6 tests).

If `test_deeplyNestedInputIsRejectedRatherThanRecursingForever` crashes rather than fails, `maxDepth` is not being threaded through — check that `parseList`/`parseDictionary` pass `depth + 1`.

- [ ] **Step 5: Commit**

```bash
git add Macget/Engine/Torrent/TorrentMetainfo.swift MacgetTests/TorrentMetainfoTests.swift
git commit -m "feat(torrent): add minimal bencode reader for the private flag"
```

---

## Task 7: `TorrentTrackers` — the bundled list and its gate

**Files:**
- Create: `Macget/Engine/Torrent/TorrentTrackers.swift`
- Test: `MacgetTests/TorrentTrackersTests.swift` (create)

**Interfaces:**
- Consumes: nothing (takes `isPrivate` as a parameter rather than parsing itself).
- Produces: `TorrentTrackers.bundled: [String]`, `TorrentTrackers.option(isPrivate: Bool, enabled: Bool) -> String?`, `TorrentTrackers.metainfoURL(infoHash: String, in: URL) -> URL`.

- [ ] **Step 1: Write the failing test**

Create `MacgetTests/TorrentTrackersTests.swift`:

```swift
import XCTest
@testable import Macget

final class TorrentTrackersTests: XCTestCase {

    func test_injectsBundledTrackersIntoPublicTorrents() throws {
        let option = try XCTUnwrap(TorrentTrackers.option(isPrivate: false, enabled: true))
        XCTAssertEqual(option.split(separator: ",").count, TorrentTrackers.bundled.count)
        XCTAssertTrue(option.contains("udp://tracker.opentrackr.org:1337/announce"))
    }

    /// Announcing a private torrent to a public tracker defeats the tracker's
    /// ratio accounting and gets the user banned.
    func test_neverInjectsIntoPrivateTorrents() {
        XCTAssertNil(TorrentTrackers.option(isPrivate: true, enabled: true))
    }

    func test_respectsTheSetting() {
        XCTAssertNil(TorrentTrackers.option(isPrivate: false, enabled: false))
    }

    func test_bundledListIsWellFormed() {
        XCTAssertFalse(TorrentTrackers.bundled.isEmpty)
        for tracker in TorrentTrackers.bundled {
            XCTAssertNotNil(URL(string: tracker), "\(tracker) is not a URL")
            XCTAssertTrue(
                tracker.hasPrefix("udp://") || tracker.hasPrefix("http://") || tracker.hasPrefix("https://"),
                "\(tracker) uses a scheme no tracker speaks"
            )
            XCTAssertTrue(tracker.contains("/announce"), "\(tracker) is not an announce URL")
        }
        XCTAssertEqual(Set(TorrentTrackers.bundled).count, TorrentTrackers.bundled.count, "duplicates waste announces")
    }

    /// aria2 writes magnet metadata as `<infoHash>.torrent` beside the data,
    /// because MacGet passes --bt-save-metadata=true.
    func test_metainfoPathMatchesWhereAria2SavesIt() {
        let folder = URL(fileURLWithPath: "/tmp/dl", isDirectory: true)
        let url = TorrentTrackers.metainfoURL(infoHash: "abc123", in: folder)
        XCTAssertEqual(url.lastPathComponent, "abc123.torrent")
        XCTAssertEqual(url.deletingLastPathComponent().path, "/tmp/dl")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/TorrentTrackersTests
```
Expected: compile failure — cannot find `TorrentTrackers` in scope.

- [ ] **Step 3: Write the type**

Create `Macget/Engine/Torrent/TorrentTrackers.swift`:

```swift
import Foundation

/// The public trackers MacGet adds to non-private torrents, and the gate that
/// decides when not to.
///
/// The list is compiled in rather than fetched. A live list (ngosang/trackerslist
/// and friends) never goes stale, but it would also mean whatever that file says
/// tomorrow is where MacGet announces the user's torrents. Staleness between
/// releases is the accepted price of keeping that decision inside the app.
enum TorrentTrackers {

    /// Long-lived, high-availability public trackers. Deliberately short: past a
    /// handful, extra announces cost more than the peers they return.
    static let bundled: [String] = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.tracker.cl:1337/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
    ]

    /// The `bt-tracker` value for one download, or nil when nothing should be
    /// injected. Passed per-download on `aria2.addUri`/`aria2.addTorrent` — never
    /// as a global launch flag, because the decision is per torrent.
    static func option(isPrivate: Bool, enabled: Bool) -> String? {
        guard enabled, !isPrivate else { return nil }
        return bundled.joined(separator: ",")
    }

    /// Where aria2 saves a magnet's metadata once BEP-9 resolves it. MacGet
    /// passes `--bt-save-metadata=true`, so this file appears beside the data
    /// and is the only way to read a magnet's `private` flag.
    static func metainfoURL(infoHash: String, in folder: URL) -> URL {
        folder.appendingPathComponent("\(infoHash).torrent")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/TorrentTrackersTests
```
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Macget/Engine/Torrent/TorrentTrackers.swift MacgetTests/TorrentTrackersTests.swift
git commit -m "feat(torrent): add bundled public tracker list with private-torrent gate"
```

---

## Task 8: Wire tracker injection into `TorrentJob`

**Files:**
- Modify: `Macget/Engine/Torrent/TorrentJob.swift`
- Test: `MacgetTests/TorrentTrackersTests.swift` (extend)

**Interfaces:**
- Consumes: `TorrentMetainfo.isPrivate(_:)` (Task 6), `TorrentTrackers.option(isPrivate:enabled:)` and `TorrentTrackers.metainfoURL(infoHash:in:)` (Task 7), `TorrentEngineOptions.addPublicTrackers` (added in this task).
- Produces: `TorrentEngineOptions.addPublicTrackers: Bool` (default `true`), added as an `init` parameter after `maxConcurrentDownloads`.

Two paths, because a magnet hides its `private` flag until metadata arrives:

- **`.torrent`** — `download.torrentFileData` is already in hand, so a private torrent is added with no trackers at all.
- **Magnet** — trackers go in at add time (the metadata fetch needs peers), and are stripped from the child GID once metadata resolves private. aria2 writes that metadata as `<infoHash>.torrent` a moment after `followedBy` appears, so the check is retried across a few polls rather than done once at handoff.

- [ ] **Step 1: Write the failing test**

Add to `MacgetTests/TorrentTrackersTests.swift`:

```swift
    func test_addPublicTrackersFlowsFromSettingsToEngineOptions() {
        XCTAssertTrue(AppSettings().torrentOptions.addPublicTrackers)
        XCTAssertFalse(AppSettings(torrentAddPublicTrackers: false).torrentOptions.addPublicTrackers)
    }
```

Add a new class to the same file, covering the decision `TorrentJob` makes without needing a live daemon:

```swift
/// The add-time decision, extracted so it can be tested without a daemon.
final class TorrentTrackerDecisionTests: XCTestCase {

    private func metainfo(privateFlag: Int?) -> Data {
        // "4:test" is a 4-byte string — the length prefix must match exactly or
        // the parser reads the next key from the middle of this value.
        var info = Data("d4:name4:test".utf8)
        // (no pieces: the parser doesn't require them and this keeps the fixture small)
        if let privateFlag { info.append(Data("7:privatei\(privateFlag)e".utf8)) }
        info.append(Data("e".utf8))
        var root = Data("d4:info".utf8)
        root.append(info)
        root.append(Data("e".utf8))
        return root
    }

    func test_publicTorrentFileGetsTrackers() {
        XCTAssertNotNil(TorrentJob.trackerOption(
            torrentFileData: metainfo(privateFlag: nil), addPublicTrackers: true))
    }

    func test_privateTorrentFileGetsNone() {
        XCTAssertNil(TorrentJob.trackerOption(
            torrentFileData: metainfo(privateFlag: 1), addPublicTrackers: true))
    }

    /// A magnet has no metainfo yet, so it gets trackers and is corrected later.
    func test_magnetWithNoMetainfoYetStillGetsTrackers() {
        XCTAssertNotNil(TorrentJob.trackerOption(torrentFileData: nil, addPublicTrackers: true))
    }

    func test_settingOffMeansNoneEverywhere() {
        XCTAssertNil(TorrentJob.trackerOption(torrentFileData: nil, addPublicTrackers: false))
        XCTAssertNil(TorrentJob.trackerOption(
            torrentFileData: metainfo(privateFlag: nil), addPublicTrackers: false))
    }
}
```

Note the fixture above deliberately omits `pieces`; `d4:name4:testv…` is `name` → `testv`. Keep the key order sorted (`name` < `private`).

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/TorrentTrackerDecisionTests
```
Expected: compile failure — no member `addPublicTrackers`, no member `trackerOption`.

- [ ] **Step 3: Add the engine option**

In `Aria2Daemon.swift`, in `TorrentEngineOptions`, after `maxConcurrentDownloads`:

```swift
    /// Inject `TorrentTrackers.bundled` into non-private torrents.
    var addPublicTrackers: Bool = true
```

Add `addPublicTrackers: Bool = true,` to the memberwise `init` after `maxConcurrentDownloads`, with `self.addPublicTrackers = addPublicTrackers` in the body, and to `init(settings:)`:

```swift
            addPublicTrackers: settings.torrentAddPublicTrackers,
```

- [ ] **Step 4: Add the pure decision helper and use it**

In `TorrentJob.swift`, add to the `// MARK: - Lifecycle` section:

```swift
    /// Add-time tracker decision, pure so it can be tested without a daemon.
    ///
    /// A magnet passes `nil` here: its `private` flag is unknowable until
    /// metadata arrives, and the metadata fetch itself needs peers. It is
    /// corrected at the handoff by `dropTrackersIfPrivate`.
    static func trackerOption(torrentFileData: Data?, addPublicTrackers: Bool) -> String? {
        let isPrivate = torrentFileData.map(TorrentMetainfo.isPrivate) ?? false
        return TorrentTrackers.option(isPrivate: isPrivate, enabled: addPublicTrackers)
    }
```

Then rewrite `add(using:)`. Note the existing local variable is named `options`, which **shadows the actor's `options` property** (`TorrentEngineOptions`); rename it to `addOptions` so `self.options` is reachable and the two stop looking alike:

```swift
    private func add(using client: Aria2RPCClient) async throws -> String {
        var addOptions: [String: String] = ["dir": download.destinationFolder.path]
        // Honour an existing file selection across a resume.
        if let files = download.torrentFiles, !files.isEmpty {
            let selected = files.filter(\.selected).map { String($0.index) }
            // Selecting nothing would download nothing; treat it as "everything".
            if !selected.isEmpty, selected.count != files.count {
                addOptions["select-file"] = selected.joined(separator: ",")
            }
        }
        if let trackers = Self.trackerOption(
            torrentFileData: download.torrentFileData,
            addPublicTrackers: options.addPublicTrackers
        ) {
            addOptions["bt-tracker"] = trackers
        }

        if let data = download.torrentFileData {
            // A .torrent carries its own metainfo, so there's no metadata phase.
            isAwaitingMetadata = false
            return try await client.addTorrent(data, options: addOptions)
        }
        isAwaitingMetadata = true
        return try await client.addURI(download.url.absoluteString, options: addOptions)
    }
```

- [ ] **Step 5: Correct a magnet that resolves private**

Add a stored property beside `isAwaitingMetadata`:

```swift
    /// Polls remaining in which to check a resolved magnet's `private` flag.
    ///
    /// aria2 writes `<infoHash>.torrent` (via `--bt-save-metadata`) a moment
    /// after `followedBy` appears, so checking once at the handoff can lose the
    /// race. Ten polls at 250ms is 2.5s — long enough, and bounded so a torrent
    /// with no metadata file never re-reads forever.
    private var privateCheckPollsRemaining = 0
```

In `poll()`, inside the `followedBy` branch, before `return true`:

```swift
            privateCheckPollsRemaining = 10
```

and after the `await adoptMetadata(from: status)` call:

```swift
        if privateCheckPollsRemaining > 0 {
            await dropTrackersIfPrivate(status: status)
        }
```

Add the method to the `// MARK: - Polling` section:

```swift
    /// A magnet's trackers were injected before its `private` flag was knowable.
    /// Once metadata lands, strip them if the torrent turns out to be private.
    ///
    /// Best-effort throughout: a failure here leaves a private torrent announcing
    /// to public trackers, which is bad, but tearing the download down over it
    /// would be worse and fixes nothing.
    private func dropTrackersIfPrivate(status: Aria2Status) async {
        privateCheckPollsRemaining -= 1
        guard options.addPublicTrackers,
              let client,
              let gid,
              let infoHash = status.infoHash ?? download.torrentInfoHash
        else { return }

        let url = TorrentTrackers.metainfoURL(infoHash: infoHash, in: download.destinationFolder)
        guard let data = try? Data(contentsOf: url) else { return }   // not written yet; retry next poll

        privateCheckPollsRemaining = 0
        guard TorrentMetainfo.isPrivate(data) else { return }

        do {
            // An empty value clears the injected list without touching the
            // torrent's own trackers.
            try await client.changeOption(gid: gid, options: ["bt-tracker": ""])
            log.info("Dropped injected trackers from private torrent \(infoHash, privacy: .public)")
        } catch {
            log.error("Could not drop trackers from private torrent: \(error.localizedDescription, privacy: .public)")
        }
    }
```

- [ ] **Step 6: Run the tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/TorrentTrackersTests \
  -only-testing:MacgetTests/TorrentTrackerDecisionTests
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Macget/Engine/Torrent/Aria2Daemon.swift Macget/Engine/Torrent/TorrentJob.swift MacgetTests/TorrentTrackersTests.swift
git commit -m "feat(torrent): inject public trackers per download, skipping private torrents"
```

---

## Task 9: Performance settings UI

**Files:**
- Modify: `Macget/Views/TorrentSettingsView.swift`
- Test: manual (SwiftUI view; the project has no view-snapshot harness)

**Interfaces:**
- Consumes: all four settings from Task 1.
- Produces: no new API.

- [ ] **Step 1: Add the Performance section**

In `TorrentSettingsView.body`, insert a new `Section` between the existing `Section("Seeding")` and `Section("Network")`:

```swift
            Section("Performance") {
                HStack {
                    Text("Maximum peers per torrent")
                    Spacer()
                    TextField("", value: $vm.settings.torrentMaxPeers, format: .number.grouping(.never))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
                Text("More peers means more chances to find a fast one. 200 suits most connections; the maximum is 500.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Add public trackers to magnet links", isOn: $vm.settings.torrentAddPublicTrackers)
                Text("Helps magnet links whose own trackers have gone offline. Skipped automatically for private torrents, which forbid outside trackers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Require encrypted connections", isOn: $vm.settings.torrentRequireEncryption)
                Text("Hides BitTorrent traffic from providers that slow it down. It also refuses peers that can't encrypt, so fewer peers are available — turn this on only if downloads are being throttled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!vm.settings.torrentsEnabled)
```

- [ ] **Step 2: Add the global-speed-limit warning**

The global limit is passed to aria2 as `max-overall-download-limit`, so it throttles torrents — correct behaviour, but invisible from this screen and the likeliest cause of "my torrent is slow". Add at the end of the same `Section("Performance")` body, after the encryption caption:

```swift
                if let limit = vm.settings.globalSpeedLimitBytesPerSec {
                    Label(
                        "The global speed limit (\(limit / 1024) KB/s) applies to torrents too. Clear it in General to let torrents run at full speed.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.paused)
                }
```

`Theme.Palette.paused` is already used in this file for the aria2-missing warning, so no new import is needed.

- [ ] **Step 3: Build and run the app**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Macget.xcodeproj -scheme Macget -configuration Debug build
```
Expected: BUILD SUCCEEDED.

Then launch the app, open Settings ▸ Torrents, and confirm: the Performance section appears; all three controls are disabled while "Enable torrent downloads" is off; the peers field rejects nothing but clamps on reload; and the warning appears only when a global speed limit is set in General.

**Visual verification cannot be done from the shell** — `screencapture` fails without Screen Recording permission. Ask the user for a screenshot.

- [ ] **Step 4: Run the whole suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS'
```
Expected: all tests pass, including the pre-existing `Aria2DaemonTests`, `Aria2RPCClientTests`, and `MagnetLinkTests`.

- [ ] **Step 5: Commit**

```bash
git add Macget/Views/TorrentSettingsView.swift
git commit -m "feat(torrent): add Performance settings section"
```

---

## Task 10: Update the architecture docs

**Files:**
- Modify: `CLAUDE.md` (BitTorrent section)
- Modify: `docs/architecture.md`

**Interfaces:**
- Consumes: everything above.
- Produces: no API.

- [ ] **Step 1: Update `CLAUDE.md`**

In the `### BitTorrent (Macget/Engine/Torrent/)` section, add these bullets after the "Ports are ranges, not single values" bullet:

```markdown
- **`--bt-request-peer-speed-limit` is a discovery ceiling, not a bandwidth cap.** aria2 stops
  looking for more peers above it. It is set to `100M` — above any consumer link — because the
  previous `10M` was only ~80 Mbps and silently stopped peer discovery at 8% of a gigabit link,
  the same defect as aria2's own 50K dial-up default, ~200x further up the scale.
- **There is no `--dht-listen-port6`.** `--dht-listen-port` covers IPv4 DHT, IPv6 DHT and UDP
  trackers. IPv6 DHT needs `--enable-dht6` *plus* `--dht-listen-addr6`, which aria2 requires to be
  a global unicast address of the host — so `Aria2Daemon` discovers one via `getifaddrs` and emits
  neither flag when the Mac has no IPv6.
- **MacGet decides tracker injection itself, per download.** aria2 disables DHT for a `private`
  torrent on its own, but honours `--bt-tracker` regardless — a supplied tracker is user intent to
  aria2. `TorrentMetainfo` reads the flag from bencode (aria2's `tellStatus` never reports it), and
  it must stay a structural parser: `info.pieces` is raw SHA-1 and will eventually contain the
  literal bytes `7:privatei1e`.
- **`--bt-max-open-files` stays at aria2's default of 100** — macOS's soft `RLIMIT_NOFILE` is 256
  and `Process` can't raise it for the child, so a larger value fails at open() time.
```

- [ ] **Step 2: Update `docs/architecture.md`**

Find the BitTorrent section and add the same substance in that document's prose style, keeping it to a short paragraph on peer discovery, IPv6 DHT, and the private-tracker gate.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/architecture.md
git commit -m "docs: record torrent tuning invariants"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1 peer discovery — speed limit, max peers | 2 |
| §1 peer discovery — IPv6 DHT, no `port6` | 3 |
| §2 reachability (`PortMapper`) | **companion plan** |
| §3 tracker injection + private gate | 6, 7, 8 |
| §3 bencode detection | 6 |
| §4 anti-throttling | 4 |
| §5 disk & I/O; `bt-max-open-files` left alone | 5 |
| §6 global speed limit warning | 9 |
| §6 `max-concurrent-downloads` | 5 |
| §6 `bt-detach-seed-only` | 5 |
| Settings (4 fields) | 1 |
| UI Performance section | 9 |
| UI Connectivity row | **companion plan** |
| Testing | each task |

`torrentAutoPortMapping` is created in Task 1 but unused until the companion plan — deliberate, so both plans share one settings migration.

**Placeholder scan:** none. Every step has runnable commands or complete code.

**Type consistency:** `TorrentEngineOptions.init` gains parameters in a fixed order across tasks — `maxPeers` (2), `requireEncryption` (4), `maxConcurrentDownloads` (5), `addPublicTrackers` (8) — each inserted after the previous, before `verifyOnResume`. `Aria2Daemon.arguments` gains exactly one parameter, `ipv6DHTAddress`, in Task 3. `TorrentMetainfo.isPrivate(_:)` and `TorrentTrackers.option(isPrivate:enabled:)` keep the same signatures where Task 8 consumes them.
