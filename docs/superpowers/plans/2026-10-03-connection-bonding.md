# Connection Bonding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one download use every enabled internet link at once (e.g. slow Wi-Fi + iPhone USB tethering) and show, per download and globally, how much each link contributes.

**Architecture:** A `NetworkLinkMonitor` publishes usable links. For range-capable HTTP downloads, `BondingPolicy` assigns each worker slot a link; default-route slots keep using `URLSession`, the rest use a new Network.framework `PinnedHTTPTransport` (`NWConnection` + `requiredInterface`, HTTP/1.1). Work stealing in `SlotFiller` then balances automatically. Torrents use aria2's `--multiple-interface`, with per-link stats attributed from `nettop`. Per-link stats ride on `DownloadSnapshot.links` to the row, inspector, toolbar strip and menu bar.

**Tech Stack:** Swift 5 mode, SwiftUI, Swift Charts, Network.framework, SystemConfiguration, XCTest. aria2c (system copy), `/usr/bin/nettop`.

**Spec:** `docs/superpowers/specs/2026-10-03-connection-bonding-design.md`

## Global Constraints

- Minimum macOS **26.4**. No new third-party dependencies, no SPM.
- Threads stay bounded to **1…16** (`Download.maxThreadCount`); bonding divides that budget across links, never adds to it.
- Bonding is **off by default** (`BondingSettings.enabled = false`). With it off, or with fewer than 2 usable enabled links, behavior must be byte-for-byte today's path.
- A failure on a pinned (non-default) link **removes that link from that download; it never fails the download** and never prompts for credentials.
- A pinned-link failure **never writes `HostCapStore`**.
- `URLSessionFactory.shared`/engine session stays the only `URLSession`; pinned connections use `NWPinnedTransport.shared`.
- Logging via `Log.engine`/`Logger(subsystem: "com.macget", …)`; never `print`.
- New persisted fields (`AppSettings.bonding`) are `Codable` + `Sendable` and decode as default when absent. `LinkStat` is live-only, never persisted.
- New UI copy avoids naming the app; where unavoidable, match the surrounding view (the existing Settings ▸ Network copy says "Macget").
- Build/test from the shell needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. New `.swift` files under `Macget/` and `MacgetTests/` are auto-included (synchronized root groups) — no `project.pbxproj` edits.

Test command used throughout (abbreviated as **`$TEST`**):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS'
```

Single class: `$TEST -only-testing:MacgetTests/<ClassName>`. Assertion text is not in the log; when a test fails, read it with `xcrun xcresulttool get test-results tests --path <xcresult> --format json`.

## Deviations from the spec (decided while planning)

1. **Pinned workers follow redirects themselves** (max 5, same link). The spec relied on the probe's final URL, but the probe is skipped on resume and its result has no final URL, so a resumed GitHub-release download would silently lose bonding.
2. **Pinned connection errors don't back off on the same piece.** They release the piece immediately and add a strike to the link; 3 strikes in 30 s exclude the link for that download (`LinkStrikes`). Otherwise a failing link holds pieces hostage through ~15 s of exponential backoff.
3. **Per-link bytes are counted by the coordinator** (`inFlightRoute[chunkID]`) instead of adding a link parameter to `ChunkWorker.report` — the coordinator already knows which link each piece runs on.
4. **Per-link chart is a separate stacked chart** in the inspector's new "Network links" section; the existing `SpeedChartView` is left alone.
5. **`NetworkLinkMonitor` debounce is not unit-tested** (time-based actor logic). Filtering, classification and ordering are pure and tested.
6. Links that are offline are not listed in Settings (only usable links appear), so there is no "No internet" status row.

## Review Focus

1. **Server rejects the second IP (IP-signed CDN URL → 403 on the pinned link)** — download must complete on the default link, link shows "Not accepted by server", no credential prompt. Test: `BondingCoordinatorTests.test_pinned403_dropsLinkAndCompletes` (Task 9).
2. **Different CDN edge serves a different version (pinned gets 200 instead of 206)** — must not trigger `restartFromScratch` or fail. Test: `BondingCoordinatorTests.test_pinnedRangeIgnored_doesNotFailDownload` (Task 9).
3. **Phone unplugged mid-download while its connections hang** — download continues on Wi-Fi without waiting for the stall watchdog's 30 s. Test: `BondingCoordinatorTests.test_linkDisappears_workersReassigned` (Task 9).
4. **Flaky tether link failing repeatedly while Wi-Fi flows** — no learned host cap is written, download completes. Test: `BondingCoordinatorTests.test_flakyPinnedLink_neverWritesHostCap` (Task 9).
5. **HTTP response split at arbitrary byte boundaries / chunked encoding from a real server** — parser must produce identical body bytes regardless of packetization. Test: `HTTPResponseParserTests.test_byteAtATime_matchesSingleFeed` (Task 6).

---

### Task 1: Validate aria2 `--multiple-interface` and `nettop` on real hardware (manual gate)

This task decides whether Tasks 11–12 (torrent bonding + attribution) are built. It needs the user's phone; an agent cannot do it alone.

**Files:**
- Modify: `docs/superpowers/specs/2026-10-03-connection-bonding-design.md` (Risks section — record the outcome)

- [ ] **Step 1: Ask the user to connect Wi-Fi + iPhone USB tethering** and confirm both appear: `networksetup -listallhardwareports` and `ifconfig | grep -A3 '^en'` show two interfaces with IPv4 addresses.

- [ ] **Step 2: Run aria2 bound to both links against a well-seeded legal torrent**

```bash
WIFI_IP=$(ipconfig getifaddr en0); TETHER_IF=<the iPhone USB enX>; TETHER_IP=$(ipconfig getifaddr $TETHER_IF)
mkdir -p /tmp/bondtest && cd /tmp/bondtest
aria2c --multiple-interface="$WIFI_IP,$TETHER_IP" --seed-time=0 \
  "https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/debian-13.1.0-amd64-netinst.iso.torrent" &
sleep 20
nettop -L 1 -x -n -p $(pgrep -n aria2c) -J interface,bytes_in | awk -F, '$2!=""{s[$2]+=$3} END{for(i in s) print i, s[i]}'
kill %1
```

Expected if it works: both `en0` and `$TETHER_IF` show non-trivial `bytes_in`.

- [ ] **Step 3: Record the outcome** in the spec's Risks section as one line: "Validated 2026-10-xx: `--multiple-interface` spreads BT peer traffic across links — yes/no; `nettop` per-socket interface attribution works unprivileged — yes/no." If either is **no**, skip Tasks 11 and 12 and note it in the final summary.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-10-03-connection-bonding-design.md
git commit -m "docs: record connection-bonding hardware validation"
```

---

### Task 2: `BondingSettings` in `AppSettings`

**Files:**
- Create: `Macget/Engine/Bonding/BondingSettings.swift`
- Modify: `Macget/Models/AppSettings.swift` (property after `torrentAutoPortMapping`, init param, init body, `init(from:)`)
- Test: `MacgetTests/BondingSettingsTests.swift`

**Interfaces:**
- Produces: `struct BondingSettings: Codable, Equatable, Sendable { var enabled: Bool; var disabledLinkIDs: Set<String>; func isLinkEnabled(_ id: String) -> Bool }`, `AppSettings.bonding: BondingSettings`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Macget

final class BondingSettingsTests: XCTestCase {
    func test_defaultsAreOff() {
        let s = AppSettings()
        XCTAssertFalse(s.bonding.enabled)
        XCTAssertTrue(s.bonding.disabledLinkIDs.isEmpty)
    }

    func test_settingsWithoutBondingKeyDecodeAsDefault() throws {
        // A settings.json written before this feature existed.
        let json = #"{"defaultThreadCount": 6}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.bonding, BondingSettings())
        XCTAssertEqual(s.defaultThreadCount, 6)
    }

    func test_roundTrips() throws {
        var s = AppSettings()
        s.bonding = BondingSettings(enabled: true, disabledLinkIDs: ["en7"])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded.bonding, s.bonding)
    }

    func test_isLinkEnabled() {
        let b = BondingSettings(enabled: true, disabledLinkIDs: ["en7"])
        XCTAssertTrue(b.isLinkEnabled("en0"))
        XCTAssertFalse(b.isLinkEnabled("en7"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/BondingSettingsTests`
Expected: build failure — `cannot find 'BondingSettings' in scope`.

- [ ] **Step 3: Implement**

`Macget/Engine/Bonding/BondingSettings.swift`:

```swift
import Foundation

/// User preferences for combining several internet links into one download.
///
/// Off by default: a tethered phone's data usually counts against a mobile plan,
/// so using it is always the user's explicit choice.
struct BondingSettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    /// BSD names (e.g. "en7") the user switched off. Stored as the negative so a
    /// newly-plugged link is used by default once bonding is on.
    var disabledLinkIDs: Set<String> = []

    init(enabled: Bool = false, disabledLinkIDs: Set<String> = []) {
        self.enabled = enabled
        self.disabledLinkIDs = disabledLinkIDs
    }

    func isLinkEnabled(_ id: String) -> Bool {
        !disabledLinkIDs.contains(id)
    }
}
```

In `Macget/Models/AppSettings.swift`:

1. After `var torrentAutoPortMapping: Bool` add:

```swift
    /// Combine several internet links (Wi-Fi + tethered phone, …) for one download.
    var bonding: BondingSettings
```

2. Add the init parameter as the last parameter of `init(...)`: `bonding: BondingSettings = BondingSettings()` and in the body after `self.torrentAutoPortMapping = torrentAutoPortMapping`: `self.bonding = bonding`.

3. At the end of `init(from decoder:)`, after the `torrentAutoPortMapping` line:

```swift
        bonding = try c.decodeIfPresent(BondingSettings.self, forKey: .bonding) ?? defaults.bonding
```

- [ ] **Step 4: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/BondingSettingsTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Macget/Engine/Bonding/BondingSettings.swift Macget/Models/AppSettings.swift MacgetTests/BondingSettingsTests.swift
git commit -m "feat(bonding): add BondingSettings to AppSettings"
```

---

### Task 3: `NetworkLink`, `LinkStat` and the pure `LinkFilter`

**Files:**
- Create: `Macget/Engine/Bonding/NetworkLink.swift`
- Create: `Macget/Engine/Bonding/LinkStat.swift`
- Create: `Macget/Engine/Bonding/LinkFilter.swift`
- Test: `MacgetTests/LinkFilterTests.swift`

**Interfaces:**
- Produces:
  - `struct NetworkLink: Sendable, Hashable, Identifiable { let id: String; let displayName: String; let kind: Kind; let addresses: [String]; let isDefaultRoute: Bool; var ipv4Addresses: [String] }`, `enum NetworkLink.Kind: String, Sendable, CaseIterable { case wiredEthernet, wifi, tethered, other }`
  - `struct LinkStat: Sendable, Equatable, Identifiable` (fields below), `enum LinkStat.Status { case active, rejectedByServer, down }`, `static func LinkStat.aggregate(_ perDownload: [[LinkStat]]) -> [LinkStat]`
  - `enum LinkFilter { static func isCandidate(bsdName:) -> Bool; enum InterfaceType { case wifi, wiredEthernet, cellular, other }; static func classify(type:displayName:) -> NetworkLink.Kind; static func rank(_:) -> Int; static func sorted(_:) -> [NetworkLink] }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Macget

final class LinkFilterTests: XCTestCase {
    func test_excludesVirtualAndTunnelInterfaces() {
        for name in ["lo0", "utun3", "ipsec0", "awdl0", "llw0", "bridge0", "gif0", "stf0", "anpi1", "ap1", "nan0"] {
            XCTAssertFalse(LinkFilter.isCandidate(bsdName: name), name)
        }
        for name in ["en0", "en7", "en12"] {
            XCTAssertTrue(LinkFilter.isCandidate(bsdName: name), name)
        }
    }

    func test_classifiesTetheredByDisplayName() {
        // A USB-tethered iPhone presents as wired Ethernet; only its name gives it away.
        XCTAssertEqual(LinkFilter.classify(type: .wiredEthernet, displayName: "iPhone USB"), .tethered)
        XCTAssertEqual(LinkFilter.classify(type: .wiredEthernet, displayName: "iPad"), .tethered)
        XCTAssertEqual(LinkFilter.classify(type: .other, displayName: "Android RNDIS"), .tethered)
        XCTAssertEqual(LinkFilter.classify(type: .cellular, displayName: "anything"), .tethered)
        XCTAssertEqual(LinkFilter.classify(type: .wifi, displayName: "Wi-Fi"), .wifi)
        XCTAssertEqual(LinkFilter.classify(type: .wiredEthernet, displayName: "Thunderbolt Ethernet"), .wiredEthernet)
        XCTAssertEqual(LinkFilter.classify(type: .other, displayName: "Mystery"), .other)
    }

    func test_sortsDefaultFirstThenByKind() {
        let tether = NetworkLink(id: "en7", displayName: "iPhone USB", kind: .tethered, addresses: ["172.20.10.2"], isDefaultRoute: false)
        let wifi = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: ["192.168.0.5"], isDefaultRoute: true)
        let eth = NetworkLink(id: "en5", displayName: "Ethernet", kind: .wiredEthernet, addresses: ["10.0.0.2"], isDefaultRoute: false)
        XCTAssertEqual(LinkFilter.sorted([tether, eth, wifi]).map(\.id), ["en0", "en5", "en7"])
    }

    func test_ipv4AddressesExcludeIPv6() {
        let l = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: ["192.168.0.5", "2001:db8::1"], isDefaultRoute: true)
        XCTAssertEqual(l.ipv4Addresses, ["192.168.0.5"])
    }

    func test_aggregateSumsPerLinkAcrossDownloads() {
        func stat(_ id: String, _ kind: NetworkLink.Kind, _ speed: Double, estimate: Bool = false) -> LinkStat {
            LinkStat(linkID: id, displayName: id, kind: kind, speedBytesPerSec: speed, bytesThisSession: 10,
                     activeConnections: 2, status: .active, isEstimate: estimate)
        }
        let a = [stat("en0", .wifi, 100), stat("en7", .tethered, 300)]
        let b = [stat("en0", .wifi, 50), stat("en7", .tethered, 50, estimate: true)]
        let total = LinkStat.aggregate([a, b])
        XCTAssertEqual(total.map(\.linkID), ["en0", "en7"])
        XCTAssertEqual(total.map(\.speedBytesPerSec), [150, 350])
        XCTAssertEqual(total.map(\.bytesThisSession), [20, 20])
        XCTAssertEqual(total.map(\.activeConnections), [4, 4])
        XCTAssertEqual(total.map(\.isEstimate), [false, true])
    }

    func test_aggregateIsEmptyWithFewerThanTwoMovingLinks() {
        let only = [LinkStat(linkID: "en0", displayName: "Wi-Fi", kind: .wifi, speedBytesPerSec: 100,
                             bytesThisSession: 1, activeConnections: 1, status: .active, isEstimate: false),
                    LinkStat(linkID: "en7", displayName: "iPhone USB", kind: .tethered, speedBytesPerSec: 0,
                             bytesThisSession: 0, activeConnections: 0, status: .active, isEstimate: false)]
        XCTAssertTrue(LinkStat.aggregate([only]).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/LinkFilterTests`
Expected: build failure — `cannot find 'LinkFilter' in scope`.

- [ ] **Step 3: Implement**

`Macget/Engine/Bonding/NetworkLink.swift`:

```swift
import Foundation

/// One usable internet link — a physical interface that currently reaches the
/// internet. Identified by BSD name, which is what Network.framework, aria2 and
/// `nettop` all agree on.
struct NetworkLink: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        case wiredEthernet, wifi, tethered, other
    }

    let id: String              // BSD name, e.g. "en0"
    let displayName: String     // "Wi-Fi", "iPhone USB", "Thunderbolt Ethernet"
    let kind: Kind
    /// Local IPv4 and global IPv6 addresses. Link-local addresses are excluded.
    let addresses: [String]
    let isDefaultRoute: Bool

    /// aria2's `--multiple-interface` binds by address; IPv4 is the reliable family.
    var ipv4Addresses: [String] { addresses.filter { !$0.contains(":") } }
}
```

`Macget/Engine/Bonding/LinkStat.swift`:

```swift
import Foundation

/// Live per-link throughput for one download (or, aggregated, for all of them).
/// Never persisted — like `DownloadSnapshot.speedBytesPerSec`, it only means
/// something while bytes are moving.
struct LinkStat: Sendable, Equatable, Identifiable {
    enum Status: String, Sendable {
        case active
        /// The server refused this link's IP (signed URL, different edge, TLS…).
        case rejectedByServer
        /// The link went away or failed repeatedly during this download.
        case down
    }

    let linkID: String
    let displayName: String
    let kind: NetworkLink.Kind
    let speedBytesPerSec: Double
    let bytesThisSession: Int64
    let activeConnections: Int
    let status: Status
    /// True for torrents when several share the daemon and the split is apportioned.
    let isEstimate: Bool

    var id: String { linkID }

    /// Sums per-link stats across downloads for the global strip and menu bar.
    /// Empty unless at least two links are actually carrying bytes — a single
    /// link has nothing to break down.
    static func aggregate(_ perDownload: [[LinkStat]]) -> [LinkStat] {
        var order: [String] = []
        var byID: [String: LinkStat] = [:]
        for stats in perDownload {
            for s in stats {
                if let prev = byID[s.linkID] {
                    byID[s.linkID] = LinkStat(
                        linkID: s.linkID, displayName: prev.displayName, kind: prev.kind,
                        speedBytesPerSec: prev.speedBytesPerSec + s.speedBytesPerSec,
                        bytesThisSession: prev.bytesThisSession + s.bytesThisSession,
                        activeConnections: prev.activeConnections + s.activeConnections,
                        status: .active,
                        isEstimate: prev.isEstimate || s.isEstimate
                    )
                } else {
                    order.append(s.linkID)
                    byID[s.linkID] = LinkStat(
                        linkID: s.linkID, displayName: s.displayName, kind: s.kind,
                        speedBytesPerSec: s.speedBytesPerSec, bytesThisSession: s.bytesThisSession,
                        activeConnections: s.activeConnections, status: .active, isEstimate: s.isEstimate
                    )
                }
            }
        }
        let result = order.compactMap { byID[$0] }
            .sorted { (LinkFilter.rank($0.kind), $0.linkID) < (LinkFilter.rank($1.kind), $1.linkID) }
        guard result.filter({ $0.speedBytesPerSec > 0 }).count >= 2 else { return [] }
        return result
    }
}
```

`Macget/Engine/Bonding/LinkFilter.swift`:

```swift
import Foundation

/// Pure rules for which interfaces count as internet links and how to name them.
enum LinkFilter {
    /// Virtual, tunnel and peer-to-peer interfaces. VPN tunnels (`utun`, `ipsec`)
    /// are excluded deliberately: they ride on top of a physical link, so
    /// "bonding" a VPN with its own carrier would double-count one link.
    static let excludedPrefixes = ["lo", "utun", "ipsec", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap", "nan"]

    static func isCandidate(bsdName: String) -> Bool {
        !excludedPrefixes.contains { bsdName.hasPrefix($0) }
    }

    /// Network.framework's interface type, decoupled so tests needn't build an `NWInterface`.
    enum InterfaceType: Sendable {
        case wifi, wiredEthernet, cellular, other
    }

    /// A USB-tethered phone presents as wired Ethernet; only its localized name
    /// ("iPhone USB") distinguishes it, and that's the distinction the user cares
    /// about because it is the one on a data plan.
    static func classify(type: InterfaceType, displayName: String) -> NetworkLink.Kind {
        let lower = displayName.lowercased()
        let tetherHints = ["iphone", "ipad", "android", "rndis", "tether"]
        if type == .cellular || tetherHints.contains(where: lower.contains) {
            return .tethered
        }
        switch type {
        case .wifi: return .wifi
        case .wiredEthernet: return .wiredEthernet
        case .cellular, .other: return .other
        }
    }

    /// Lower is preferred when a thread budget is too small for every link.
    static func rank(_ kind: NetworkLink.Kind) -> Int {
        switch kind {
        case .wiredEthernet: return 0
        case .wifi: return 1
        case .tethered: return 2
        case .other: return 3
        }
    }

    static func sorted(_ links: [NetworkLink]) -> [NetworkLink] {
        links.sorted {
            if $0.isDefaultRoute != $1.isDefaultRoute { return $0.isDefaultRoute }
            return (rank($0.kind), $0.id) < (rank($1.kind), $1.id)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/LinkFilterTests`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Macget/Engine/Bonding/NetworkLink.swift Macget/Engine/Bonding/LinkStat.swift Macget/Engine/Bonding/LinkFilter.swift MacgetTests/LinkFilterTests.swift
git commit -m "feat(bonding): add NetworkLink, LinkStat and LinkFilter"
```

---

### Task 4: `NetworkLinkMonitor` and engine reachability on top of it

**Files:**
- Create: `Macget/Engine/Bonding/NetworkLinkMonitor.swift`
- Create: `Macget/Engine/Bonding/LinkAddresses.swift`
- Modify: `Macget/Engine/DownloadEngine.swift` (`startNetworkMonitoring`, properties at ~line 41)
- Test: `MacgetTests/LinkAddressesTests.swift`

**Interfaces:**
- Consumes: `NetworkLink`, `LinkFilter` (Task 3).
- Produces:
  - `protocol LinkProvider: Sendable { func usableLinks() async -> [NetworkLink] }`
  - `struct LinkSnapshot: Sendable, Equatable { let links: [NetworkLink]; let isOnline: Bool }`
  - `actor NetworkLinkMonitor: LinkProvider { static let shared; func start(); func usableLinks() -> [NetworkLink]; func interface(for id: String) -> NWInterface?; func updates() -> AsyncStream<LinkSnapshot> }`
  - `enum LinkAddresses { static func byInterface() -> [String: [String]]; static func normalize(_ raw: String) -> String? }`
  - `DownloadEngine.lastLinkSnapshot: LinkSnapshot` (private), `handleLinkSnapshot(_:)` (private; Task 11 extends it).

- [ ] **Step 1: Write the failing test** (the address normalizer is the only pure part)

```swift
import XCTest
@testable import Macget

final class LinkAddressesTests: XCTestCase {
    func test_normalizeDropsLinkLocalAndScope() {
        XCTAssertNil(LinkAddresses.normalize("fe80::1%en0"))
        XCTAssertNil(LinkAddresses.normalize("169.254.3.4"))
        XCTAssertEqual(LinkAddresses.normalize("2001:db8::5%en0"), "2001:db8::5")
        XCTAssertEqual(LinkAddresses.normalize("192.168.0.5"), "192.168.0.5")
    }

    func test_byInterfaceReturnsLoopbackOnAnyMac() {
        // Sanity check that getifaddrs plumbing works at all.
        XCTAssertEqual(LinkAddresses.byInterface()["lo0"]?.contains("127.0.0.1"), true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/LinkAddressesTests`
Expected: build failure — `cannot find 'LinkAddresses' in scope`.

- [ ] **Step 3: Implement `LinkAddresses`**

`Macget/Engine/Bonding/LinkAddresses.swift`:

```swift
import Foundation
import Darwin

/// Local addresses per BSD interface name, via `getifaddrs`.
enum LinkAddresses {
    static func byInterface() -> [String: [String]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var out: [String: [String]] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET
                ? MemoryLayout<sockaddr_in>.size
                : MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            if name.hasPrefix("lo") {
                out[name, default: []].append(String(cString: host))
                continue
            }
            if let addr = normalize(String(cString: host)) {
                out[name, default: []].append(addr)
            }
        }
        return out
    }

    /// Strips a `%scope` suffix and drops link-local addresses, which can't reach
    /// the internet and would only confuse aria2's interface binding.
    static func normalize(_ raw: String) -> String? {
        let addr = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
        if addr.lowercased().hasPrefix("fe80") || addr.hasPrefix("169.254.") { return nil }
        return addr
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/LinkAddressesTests`
Expected: 2 tests pass.

- [ ] **Step 5: Implement `NetworkLinkMonitor`**

`Macget/Engine/Bonding/NetworkLinkMonitor.swift`:

```swift
import Foundation
import Network
import OSLog
import SystemConfiguration

/// Every usable link, plus whether the Mac is online at all.
struct LinkSnapshot: Sendable, Equatable {
    let links: [NetworkLink]
    let isOnline: Bool
}

/// Something that can say which links are usable right now. The coordinator
/// depends on this, not on the monitor, so tests can inject a fixed set.
protocol LinkProvider: Sendable {
    func usableLinks() async -> [NetworkLink]
}

/// Watches the machine's network interfaces and publishes the ones that reach
/// the internet.
///
/// One whole-machine `NWPathMonitor` lists candidate interfaces in preference
/// order (first = default route). Each candidate then gets its own
/// `NWPathMonitor(requiredInterface:)`, because the whole-machine path being
/// satisfied says nothing about whether *this* interface reaches anything — a
/// tethered phone with no signal is still "plugged in".
///
/// Changes are debounced so a tether that drops for a second doesn't churn
/// every download's workers or restart the aria2 daemon.
actor NetworkLinkMonitor: LinkProvider {
    static let shared = NetworkLinkMonitor()
    static let debounce: Duration = .seconds(2)

    private let queue = DispatchQueue(label: "com.macget.link-monitor")
    private let log = Logger(subsystem: "com.macget", category: "Links")

    private var mainMonitor: NWPathMonitor?
    private var perInterface: [String: NWPathMonitor] = [:]
    private var interfaces: [String: NWInterface] = [:]
    private var satisfied: Set<String> = []
    private var defaultID: String?
    private var online = true
    private var published = LinkSnapshot(links: [], isOnline: true)
    private var subscribers: [UUID: AsyncStream<LinkSnapshot>.Continuation] = [:]
    private var debounceTask: Task<Void, Never>?

    func start() {
        guard mainMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.handleMainPath(path) }
        }
        monitor.start(queue: queue)
        mainMonitor = monitor
    }

    func usableLinks() -> [NetworkLink] { published.links }

    func interface(for id: String) -> NWInterface? { interfaces[id] }

    /// Current snapshot immediately, then every debounced change.
    func updates() -> AsyncStream<LinkSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.yield(published)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func handleMainPath(_ path: NWPath) {
        online = path.status == .satisfied
        let candidates = path.availableInterfaces.filter { LinkFilter.isCandidate(bsdName: $0.name) }
        defaultID = candidates.first?.name

        let names = Set(candidates.map(\.name))
        for iface in candidates where perInterface[iface.name] == nil {
            interfaces[iface.name] = iface
            let name = iface.name
            let monitor = NWPathMonitor(requiredInterface: iface)
            monitor.pathUpdateHandler = { [weak self] p in
                let ok = p.status == .satisfied
                Task { await self?.handleInterfacePath(name: name, satisfied: ok) }
            }
            monitor.start(queue: queue)
            perInterface[name] = monitor
        }
        for (name, monitor) in perInterface where !names.contains(name) {
            monitor.cancel()
            perInterface[name] = nil
            interfaces[name] = nil
            satisfied.remove(name)
        }
        scheduleRepublish()
    }

    private func handleInterfacePath(name: String, satisfied ok: Bool) {
        if ok { satisfied.insert(name) } else { satisfied.remove(name) }
        scheduleRepublish()
    }

    private func scheduleRepublish() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.republish()
        }
    }

    private func republish() {
        let names = Self.localizedNames()
        let addresses = LinkAddresses.byInterface()
        let links = satisfied.compactMap { id -> NetworkLink? in
            guard let iface = interfaces[id] else { return nil }
            let display = names[id] ?? id
            return NetworkLink(
                id: id,
                displayName: display,
                kind: LinkFilter.classify(type: Self.interfaceType(iface.type), displayName: display),
                addresses: addresses[id] ?? [],
                isDefaultRoute: id == defaultID
            )
        }
        let snapshot = LinkSnapshot(links: LinkFilter.sorted(links), isOnline: online)
        guard snapshot != published else { return }
        published = snapshot
        log.info("Usable links: \(snapshot.links.map(\.id).joined(separator: ","), privacy: .public) online=\(snapshot.isOnline)")
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private static func interfaceType(_ type: NWInterface.InterfaceType) -> LinkFilter.InterfaceType {
        switch type {
        case .wifi: return .wifi
        case .wiredEthernet: return .wiredEthernet
        case .cellular: return .cellular
        default: return .other
        }
    }

    /// "Wi-Fi", "iPhone USB", "Thunderbolt Ethernet" — what System Settings shows.
    private static func localizedNames() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var out: [String: String] = [:]
        for iface in all {
            if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                out[bsd] = name
            }
        }
        return out
    }
}
```

- [ ] **Step 6: Move engine reachability onto the monitor**

In `Macget/Engine/DownloadEngine.swift`:

1. Replace `private var pathMonitor: NWPathMonitor?` with:

```swift
    private var linkMonitorTask: Task<Void, Never>?
    /// Most recent link set; Task 11 derives aria2's bonding addresses from it.
    private var lastLinkSnapshot = LinkSnapshot(links: [], isOnline: true)
```

2. Replace the body of `startNetworkMonitoring()`:

```swift
    private func startNetworkMonitoring() {
        guard linkMonitorTask == nil else { return }
        linkMonitorTask = Task { [weak self] in
            await NetworkLinkMonitor.shared.start()
            for await snapshot in await NetworkLinkMonitor.shared.updates() {
                await self?.handleLinkSnapshot(snapshot)
            }
        }
    }

    private func handleLinkSnapshot(_ snapshot: LinkSnapshot) async {
        lastLinkSnapshot = snapshot
        await handleNetworkPath(satisfied: snapshot.isOnline)
    }
```

Keep `handleNetworkPath(satisfied:)` unchanged. Leave `import Network` (other code may use it; the compiler will warn if unused — remove it only if so).

- [ ] **Step 7: Run the full suite** (reachability behavior must be unchanged)

Run: `$TEST`
Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Macget/Engine/Bonding/NetworkLinkMonitor.swift Macget/Engine/Bonding/LinkAddresses.swift Macget/Engine/DownloadEngine.swift MacgetTests/LinkAddressesTests.swift
git commit -m "feat(bonding): add NetworkLinkMonitor and drive engine reachability from it"
```

---

### Task 5: `BondingPolicy`, `LinkStrikes`, `BondingEligibility`

**Files:**
- Create: `Macget/Engine/Bonding/BondingPolicy.swift`
- Test: `MacgetTests/BondingPolicyTests.swift`

**Interfaces:**
- Consumes: `NetworkLink`, `BondingSettings`, `LinkFilter`.
- Produces:
  - `struct LinkQuota: Equatable, Sendable { let linkID: String; let isDefault: Bool; let slots: Int }`
  - `enum BondingPolicy { static let minimumSlotsPerLink = 2; static func activeLinks(_:settings:excluded:) -> [NetworkLink]; static func quotas(links:threadCount:) -> [LinkQuota]; static func nextLink(quotas:occupied:) -> LinkQuota?; static func torrentAddresses(links:settings:) -> [String] }`
  - `struct LinkStrikes { static let threshold = 3; static let window: TimeInterval = 30; mutating func record(_ linkID: String, at: Date) -> Bool }`
  - `enum BondingEligibility { static func isEligible(url: URL, supportsRange: Bool, appProxyConfigured: Bool, systemProxyActive: Bool) -> Bool; static func systemProxyActive(for url: URL) -> Bool }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Macget

final class BondingPolicyTests: XCTestCase {
    private let wifi = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: ["192.168.0.5"], isDefaultRoute: true)
    private let tether = NetworkLink(id: "en7", displayName: "iPhone USB", kind: .tethered, addresses: ["172.20.10.2"], isDefaultRoute: false)
    private let eth = NetworkLink(id: "en5", displayName: "Ethernet", kind: .wiredEthernet, addresses: ["10.0.0.2", "2001:db8::2"], isDefaultRoute: false)

    func test_evenSplitAcrossTwoLinks() {
        XCTAssertEqual(BondingPolicy.quotas(links: [wifi, tether], threadCount: 8), [
            LinkQuota(linkID: "en0", isDefault: true, slots: 4),
            LinkQuota(linkID: "en7", isDefault: false, slots: 4),
        ])
    }

    func test_remainderGoesToPreferredLink() {
        XCTAssertEqual(BondingPolicy.quotas(links: [wifi, tether], threadCount: 5).map(\.slots), [3, 2])
    }

    func test_singleLinkMeansNoQuotas() {
        XCTAssertEqual(BondingPolicy.quotas(links: [wifi], threadCount: 8), [])
    }

    func test_tooFewThreadsForTwoPerLinkMeansNoQuotas() {
        XCTAssertEqual(BondingPolicy.quotas(links: [wifi, tether], threadCount: 3), [])
    }

    func test_dropsLeastPreferredLinkWhenBudgetIsTight() {
        // 5 threads fit two links at 2+ each; the tethered link is the one dropped.
        let q = BondingPolicy.quotas(links: LinkFilter.sorted([tether, eth, wifi]), threadCount: 5)
        XCTAssertEqual(q.map(\.linkID), ["en0", "en5"])
    }

    func test_threadCountClampedTo16() {
        XCTAssertEqual(BondingPolicy.quotas(links: [wifi, tether], threadCount: 40).map(\.slots).reduce(0, +), 16)
    }

    func test_activeLinksHonorsSettingsAndExclusions() {
        let settings = BondingSettings(enabled: true, disabledLinkIDs: ["en5"])
        let active = BondingPolicy.activeLinks([wifi, tether, eth], settings: settings, excluded: ["en7"])
        XCTAssertEqual(active.map(\.id), ["en0"])
        XCTAssertEqual(BondingPolicy.activeLinks([wifi, tether], settings: BondingSettings(), excluded: []), [])
    }

    func test_nextLinkPicksMostUnderfilled() {
        let q = BondingPolicy.quotas(links: [wifi, tether], threadCount: 8)
        XCTAssertEqual(BondingPolicy.nextLink(quotas: q, occupied: ["en0": 4, "en7": 1])?.linkID, "en7")
        XCTAssertEqual(BondingPolicy.nextLink(quotas: q, occupied: [:])?.linkID, "en0")
        XCTAssertNil(BondingPolicy.nextLink(quotas: q, occupied: ["en0": 4, "en7": 4]))
    }

    func test_torrentAddressesNeedTwoEnabledLinks() {
        let on = BondingSettings(enabled: true)
        XCTAssertEqual(BondingPolicy.torrentAddresses(links: [wifi, eth], settings: on), ["192.168.0.5", "10.0.0.2"])
        XCTAssertEqual(BondingPolicy.torrentAddresses(links: [wifi], settings: on), [])
        XCTAssertEqual(BondingPolicy.torrentAddresses(links: [wifi, eth], settings: BondingSettings()), [])
    }

    func test_strikesExcludeAfterThreeInWindow() {
        var strikes = LinkStrikes()
        let t0 = Date()
        XCTAssertFalse(strikes.record("en7", at: t0))
        XCTAssertFalse(strikes.record("en7", at: t0.addingTimeInterval(1)))
        XCTAssertFalse(strikes.record("en0", at: t0.addingTimeInterval(1)))
        XCTAssertTrue(strikes.record("en7", at: t0.addingTimeInterval(2)))
    }

    func test_strikesOutsideWindowAreForgotten() {
        var strikes = LinkStrikes()
        let t0 = Date()
        _ = strikes.record("en7", at: t0)
        _ = strikes.record("en7", at: t0.addingTimeInterval(1))
        XCTAssertFalse(strikes.record("en7", at: t0.addingTimeInterval(45)))
    }

    func test_eligibility() {
        let https = URL(string: "https://example.com/a.iso")!
        XCTAssertTrue(BondingEligibility.isEligible(url: https, supportsRange: true, appProxyConfigured: false, systemProxyActive: false))
        XCTAssertFalse(BondingEligibility.isEligible(url: https, supportsRange: false, appProxyConfigured: false, systemProxyActive: false))
        XCTAssertFalse(BondingEligibility.isEligible(url: https, supportsRange: true, appProxyConfigured: true, systemProxyActive: false))
        XCTAssertFalse(BondingEligibility.isEligible(url: https, supportsRange: true, appProxyConfigured: false, systemProxyActive: true))
        XCTAssertFalse(BondingEligibility.isEligible(url: URL(string: "ftp://example.com/a")!, supportsRange: true, appProxyConfigured: false, systemProxyActive: false))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/BondingPolicyTests`
Expected: build failure — `cannot find 'BondingPolicy' in scope`.

- [ ] **Step 3: Implement**

`Macget/Engine/Bonding/BondingPolicy.swift`:

```swift
import Foundation
import CFNetwork

/// How many worker slots one link gets within a download.
struct LinkQuota: Equatable, Sendable {
    let linkID: String
    /// The default-route link. Its slots run on URLSession, not the pinned transport.
    let isDefault: Bool
    let slots: Int
}

/// Pure decisions about splitting a download's workers across links.
///
/// There is no speed weighting on purpose: pieces are stolen by whichever worker
/// finishes first, so a faster link already ends up carrying more of the file.
enum BondingPolicy {
    /// One connection per link can't hide a reconnect, so a link that can't get
    /// two isn't worth the complexity of using.
    static let minimumSlotsPerLink = 2

    /// Links the user allowed and the server hasn't rejected. Empty when bonding is off.
    static func activeLinks(_ links: [NetworkLink], settings: BondingSettings, excluded: Set<String>) -> [NetworkLink] {
        guard settings.enabled else { return [] }
        return links.filter { settings.isLinkEnabled($0.id) && !excluded.contains($0.id) }
    }

    /// `links` must already be in preference order (`LinkFilter.sorted`). Returns
    /// an empty array whenever bonding wouldn't apply, which callers read as
    /// "run exactly as today".
    static func quotas(links: [NetworkLink], threadCount: Int) -> [LinkQuota] {
        let threads = max(1, min(Download.maxThreadCount, threadCount))
        let fit = min(links.count, threads / minimumSlotsPerLink)
        guard fit >= 2 else { return [] }
        let chosen = Array(links.prefix(fit))
        let base = threads / fit
        let remainder = threads % fit
        return chosen.enumerated().map { index, link in
            LinkQuota(linkID: link.id, isDefault: link.isDefaultRoute, slots: base + (index < remainder ? 1 : 0))
        }
    }

    /// The quota with the most free slots; ties go to the earlier (preferred) link.
    static func nextLink(quotas: [LinkQuota], occupied: [String: Int]) -> LinkQuota? {
        var best: (quota: LinkQuota, free: Int)?
        for q in quotas {
            let free = q.slots - (occupied[q.linkID] ?? 0)
            guard free > 0 else { continue }
            if best == nil || free > best!.free { best = (q, free) }
        }
        return best?.quota
    }

    /// IPv4 addresses for aria2's `--multiple-interface`, or empty when torrents
    /// shouldn't bond.
    static func torrentAddresses(links: [NetworkLink], settings: BondingSettings) -> [String] {
        let active = activeLinks(links, settings: settings, excluded: [])
        let withAddress = active.filter { !$0.ipv4Addresses.isEmpty }
        guard withAddress.count >= 2 else { return [] }
        return withAddress.compactMap { $0.ipv4Addresses.first }
    }
}

/// Counts connection failures per pinned link. Repeated failures in a short
/// window mean the link itself is unusable for this download, so it is dropped
/// rather than spending exponential backoff on a piece another link could take.
struct LinkStrikes {
    static let threshold = 3
    static let window: TimeInterval = 30

    private var history: [String: [Date]] = [:]

    /// Returns true when this strike pushes the link over the threshold.
    mutating func record(_ linkID: String, at date: Date = Date()) -> Bool {
        var list = history[linkID, default: []].filter { date.timeIntervalSince($0) <= Self.window }
        list.append(date)
        history[linkID] = list
        return list.count >= Self.threshold
    }
}

/// Whether a download can use pinned connections at all. The pinned transport
/// speaks plain HTTP/1.1 and has no proxy support, so any proxy means "default
/// link only" rather than silently bypassing the user's proxy on the other links.
enum BondingEligibility {
    static func isEligible(url: URL, supportsRange: Bool, appProxyConfigured: Bool, systemProxyActive: Bool) -> Bool {
        guard supportsRange, !appProxyConfigured, !systemProxyActive else { return false }
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    static func systemProxyActive(for url: URL) -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]]
        else { return false }
        return proxies.contains { ($0[kCFProxyTypeKey as String] as? String) != (kCFProxyTypeNone as String) }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/BondingPolicyTests`
Expected: 12 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Macget/Engine/Bonding/BondingPolicy.swift MacgetTests/BondingPolicyTests.swift
git commit -m "feat(bonding): add BondingPolicy, LinkStrikes and eligibility rules"
```

---

### Task 6: `HTTPResponseParser`

**Files:**
- Create: `Macget/Engine/Bonding/HTTPResponseParser.swift`
- Test: `MacgetTests/HTTPResponseParserTests.swift`

**Interfaces:**
- Produces:
  - `struct HTTPResponseHead: Sendable, Equatable { let status: Int; let headers: [String: String]; init(status:headers:); func value(_ name: String) -> String? }` — keys stored lowercased.
  - `enum HTTPParseEvent: Equatable { case head(HTTPResponseHead), body(Data), end }`
  - `enum HTTPParseError: Error, Equatable { case malformedStatusLine, malformedHeader, malformedChunk, headerTooLarge, truncatedBody }`
  - `struct HTTPResponseParser: Sendable { mutating func feed(_:) throws -> [HTTPParseEvent]; mutating func finish() throws -> [HTTPParseEvent]; var isComplete: Bool }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Macget

final class HTTPResponseParserTests: XCTestCase {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private func body(of events: [HTTPParseEvent]) -> Data {
        events.reduce(into: Data()) { acc, e in if case .body(let d) = e { acc.append(d) } }
    }

    private func head(of events: [HTTPParseEvent]) -> HTTPResponseHead? {
        for e in events { if case .head(let h) = e { return h } }
        return nil
    }

    private let partial = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-9/100\r\nContent-Length: 10\r\nETag: \"v1\"\r\n\r\n0123456789"

    func test_fixedLengthInOneFeed() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes(partial))
        XCTAssertEqual(head(of: events)?.status, 206)
        XCTAssertEqual(head(of: events)?.value("Content-Range"), "bytes 0-9/100")
        XCTAssertEqual(head(of: events)?.value("etag"), "\"v1\"")
        XCTAssertEqual(body(of: events), bytes("0123456789"))
        XCTAssertEqual(events.last, .end)
        XCTAssertTrue(p.isComplete)
    }

    func test_byteAtATime_matchesSingleFeed() throws {
        let chunked = "HTTP/1.1 206 Partial Content\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=1\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: y\r\n\r\n"
        for raw in [partial, chunked] {
            var whole = HTTPResponseParser()
            let expected = body(of: try whole.feed(bytes(raw)))
            var p = HTTPResponseParser()
            var events: [HTTPParseEvent] = []
            for b in bytes(raw) { events += try p.feed(Data([b])) }
            XCTAssertEqual(body(of: events), expected)
            XCTAssertEqual(events.last, .end)
            XCTAssertEqual(events.filter { if case .head = $0 { return true } else { return false } }.count, 1)
        }
    }

    func test_chunkedBody() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"))
        XCTAssertEqual(body(of: events), bytes("Wikipedia"))
        XCTAssertTrue(p.isComplete)
    }

    func test_interim100ContinueIsSkipped() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes("HTTP/1.1 100 Continue\r\n\r\n" + partial))
        XCTAssertEqual(head(of: events)?.status, 206)
        XCTAssertEqual(body(of: events), bytes("0123456789"))
    }

    func test_noContentHasNoBody() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes("HTTP/1.1 204 No Content\r\n\r\n"))
        XCTAssertEqual(events.last, .end)
    }

    func test_redirectHeadIsExposed() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes("HTTP/1.1 302 Found\r\nLocation: /real.iso\r\nContent-Length: 0\r\n\r\n"))
        XCTAssertEqual(head(of: events)?.status, 302)
        XCTAssertEqual(head(of: events)?.value("location"), "/real.iso")
        XCTAssertTrue(p.isComplete)
    }

    func test_closeDelimitedBodyEndsOnFinish() throws {
        var p = HTTPResponseParser()
        var events = try p.feed(bytes("HTTP/1.0 200 OK\r\n\r\nabc"))
        XCTAssertFalse(p.isComplete)
        events += try p.finish()
        XCTAssertEqual(body(of: events), bytes("abc"))
        XCTAssertEqual(events.last, .end)
    }

    func test_earlyCloseMidBodyThrows() throws {
        var p = HTTPResponseParser()
        _ = try p.feed(bytes("HTTP/1.1 206 Partial Content\r\nContent-Length: 10\r\n\r\n01234"))
        XCTAssertThrowsError(try p.finish()) { XCTAssertEqual($0 as? HTTPParseError, .truncatedBody) }
    }

    func test_closeBeforeHeadThrows() {
        var p = HTTPResponseParser()
        XCTAssertThrowsError(try p.finish()) { XCTAssertEqual($0 as? HTTPParseError, .truncatedBody) }
    }

    func test_malformedStatusLineThrows() {
        var p = HTTPResponseParser()
        XCTAssertThrowsError(try p.feed(bytes("SSH-2.0-OpenSSH\r\n\r\n"))) {
            XCTAssertEqual($0 as? HTTPParseError, .malformedStatusLine)
        }
    }

    func test_oversizedHeaderThrows() {
        var p = HTTPResponseParser()
        let huge = "HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: HTTPResponseParser.maxHeaderBytes + 1)
        XCTAssertThrowsError(try p.feed(bytes(huge))) { XCTAssertEqual($0 as? HTTPParseError, .headerTooLarge) }
    }

    func test_duplicateHeadersAreJoined() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes("HTTP/1.1 200 OK\r\nVia: a\r\nVia: b\r\nContent-Length: 0\r\n\r\n"))
        XCTAssertEqual(head(of: events)?.value("via"), "a, b")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/HTTPResponseParserTests`
Expected: build failure — `cannot find 'HTTPResponseParser' in scope`.

- [ ] **Step 3: Implement**

`Macget/Engine/Bonding/HTTPResponseParser.swift`:

```swift
import Foundation

/// A parsed status line and headers. Header names are stored lowercased.
struct HTTPResponseHead: Sendable, Equatable {
    let status: Int
    let headers: [String: String]

    init(status: Int, headers: [String: String]) {
        self.status = status
        var lowered: [String: String] = [:]
        for (k, v) in headers { lowered[k.lowercased()] = v }
        self.headers = lowered
    }

    func value(_ name: String) -> String? { headers[name.lowercased()] }
}

enum HTTPParseEvent: Equatable {
    case head(HTTPResponseHead)
    case body(Data)
    case end
}

enum HTTPParseError: Error, Equatable {
    case malformedStatusLine
    case malformedHeader
    case malformedChunk
    case headerTooLarge
    case truncatedBody
}

/// Incremental HTTP/1.1 response parser for the pinned transport.
///
/// Pure and synchronous: it is fed whatever bytes the socket delivered, in
/// whatever packetization, and returns events. That keeps every framing branch —
/// `Content-Length`, chunked, close-delimited, interim 1xx — testable without a
/// socket.
struct HTTPResponseParser: Sendable {
    static let maxHeaderBytes = 64 * 1024
    private static let crlf = Data("\r\n".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)

    private enum State: Sendable {
        case head
        case fixed(remaining: Int64)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkDataEnd
        case trailers
        case untilClose
        case done
    }

    private var state: State = .head
    private var buffer = Data()
    private(set) var isComplete = false

    mutating func feed(_ data: Data) throws -> [HTTPParseEvent] {
        buffer.append(data)
        var events: [HTTPParseEvent] = []
        while true {
            switch state {
            case .head:
                guard let end = buffer.range(of: Self.headerEnd) else {
                    if buffer.count > Self.maxHeaderBytes { throw HTTPParseError.headerTooLarge }
                    return events
                }
                let head = try Self.parseHead(buffer[buffer.startIndex..<end.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                if (100..<200).contains(head.status) { continue }   // interim; the real head follows
                events.append(.head(head))
                if head.status == 204 || head.status == 304 {
                    markDone(&events)
                    return events
                }
                if head.value("transfer-encoding")?.lowercased().contains("chunked") == true {
                    state = .chunkSize
                } else if let raw = head.value("content-length"),
                          let length = Int64(raw.trimmingCharacters(in: .whitespaces)), length >= 0 {
                    state = .fixed(remaining: length)
                } else {
                    state = .untilClose
                }

            case .fixed(let remaining):
                if remaining == 0 {
                    markDone(&events)
                    return events
                }
                guard !buffer.isEmpty else { return events }
                let take = Int(min(Int64(buffer.count), remaining))
                events.append(.body(Data(buffer.prefix(take))))
                buffer.removeFirst(take)
                state = .fixed(remaining: remaining - Int64(take))

            case .chunkSize:
                guard let lineEnd = buffer.range(of: Self.crlf) else {
                    if buffer.count > 1024 { throw HTTPParseError.malformedChunk }
                    return events
                }
                let line = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
                let hex = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                    .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(hex, radix: 16), size >= 0 else { throw HTTPParseError.malformedChunk }
                state = size == 0 ? .trailers : .chunkData(remaining: size)

            case .chunkData(let remaining):
                guard !buffer.isEmpty else { return events }
                let take = min(buffer.count, remaining)
                events.append(.body(Data(buffer.prefix(take))))
                buffer.removeFirst(take)
                state = remaining == take ? .chunkDataEnd : .chunkData(remaining: remaining - take)

            case .chunkDataEnd:
                guard buffer.count >= 2 else { return events }
                guard Data(buffer.prefix(2)) == Self.crlf else { throw HTTPParseError.malformedChunk }
                buffer.removeFirst(2)
                state = .chunkSize

            case .trailers:
                guard let lineEnd = buffer.range(of: Self.crlf) else { return events }
                let isBlank = lineEnd.lowerBound == buffer.startIndex
                buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
                if isBlank {
                    markDone(&events)
                    return events
                }

            case .untilClose:
                if !buffer.isEmpty {
                    events.append(.body(buffer))
                    buffer.removeAll()
                }
                return events

            case .done:
                return events
            }
        }
    }

    /// The peer closed the connection. Ends a close-delimited body; anything
    /// else still in progress is a truncated response.
    mutating func finish() throws -> [HTTPParseEvent] {
        switch state {
        case .done:
            return []
        case .untilClose:
            var events: [HTTPParseEvent] = []
            if !buffer.isEmpty { events.append(.body(buffer)); buffer.removeAll() }
            markDone(&events)
            return events
        default:
            throw HTTPParseError.truncatedBody
        }
    }

    private mutating func markDone(_ events: inout [HTTPParseEvent]) {
        state = .done
        isComplete = true
        events.append(.end)
    }

    private static func parseHead(_ data: Data) throws -> HTTPResponseHead {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformedStatusLine }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            throw HTTPParseError.malformedStatusLine
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformedHeader }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw HTTPParseError.malformedHeader }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        return HTTPResponseHead(status: status, headers: headers)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/HTTPResponseParserTests`
Expected: 12 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Macget/Engine/Bonding/HTTPResponseParser.swift MacgetTests/HTTPResponseParserTests.swift
git commit -m "feat(bonding): add incremental HTTP/1.1 response parser"
```

---

### Task 7: `PinnedTransport` + `NWPinnedTransport` + shared range validation

**Files:**
- Create: `Macget/Engine/Bonding/PinnedTransport.swift`
- Create: `Macget/Engine/Bonding/NWPinnedTransport.swift`
- Create: `Macget/Engine/RangeResponseValidator.swift`
- Modify: `Macget/Engine/ChunkWorker.swift` (`StreamingDelegate.urlSession(_:dataTask:didReceive:completionHandler:)` and `statusError`)
- Test: `MacgetTests/RangeResponseValidatorTests.swift`, `MacgetTests/PinnedRequestTests.swift`

**Interfaces:**
- Consumes: `HTTPResponseParser`, `HTTPResponseHead` (Task 6), `NetworkLinkMonitor.interface(for:)` (Task 4).
- Produces:
  - `protocol PinnedTransport: Sendable { func get(url: URL, headers: [(String, String)], linkID: String) async throws -> PinnedResponse }`
  - `struct PinnedResponse: Sendable { let head: HTTPResponseHead; let body: AsyncThrowingStream<Data, Error> }`
  - `enum PinnedTransportError: Error, LocalizedError, Equatable { case unsupportedURL, interfaceUnavailable(String), tlsFailed(String), connectionFailed(String), closedBeforeResponse; var isTLS: Bool }`
  - `enum PinnedRequest { static func bytes(url: URL, headers: [(String, String)]) -> Data? }`
  - `final class NWPinnedTransport: PinnedTransport { static let shared }`
  - `enum RangeResponseValidator { static func validate(status: Int, contentRange: String?, retryAfter: String?, expectedStart: Int64, expectedEnd: Int64, unbounded: Bool) -> ChunkError? }`

- [ ] **Step 1: Write the failing tests**

`MacgetTests/RangeResponseValidatorTests.swift`:

```swift
import XCTest
@testable import Macget

final class RangeResponseValidatorTests: XCTestCase {
    private func v(_ status: Int, _ cr: String? = nil, retryAfter: String? = nil, unbounded: Bool = false) -> ChunkError? {
        RangeResponseValidator.validate(status: status, contentRange: cr, retryAfter: retryAfter,
                                        expectedStart: 100, expectedEnd: 199, unbounded: unbounded)
    }

    func test_matching206IsAccepted() { XCTAssertNil(v(206, "bytes 100-199/1000")) }
    func test_206WithoutContentRangeIsAccepted() { XCTAssertNil(v(206)) }

    func test_200IsRangeRefused() {
        guard case .rangeRefused(200)? = v(200) else { return XCTFail() }
    }

    func test_wrongContentRange() {
        guard case .wrongContentRange? = v(206, "bytes 0-99/1000") else { return XCTFail() }
    }

    func test_busyCarriesRetryAfter() {
        guard case .serverBusy(503, let ra)? = v(503, retryAfter: "7") else { return XCTFail() }
        XCTAssertEqual(ra, 7)
    }

    func test_authRequired() {
        guard case .authRequired(401)? = v(401) else { return XCTFail() }
    }

    func test_unboundedAcceptsAny2xx() {
        XCTAssertNil(v(200, unbounded: true))
        guard case .unexpectedStatus(404)? = v(404, unbounded: true) else { return XCTFail() }
    }
}
```

`MacgetTests/PinnedRequestTests.swift`:

```swift
import XCTest
@testable import Macget

final class PinnedRequestTests: XCTestCase {
    func test_requestLineHostAndHeaders() throws {
        let data = try XCTUnwrap(PinnedRequest.bytes(
            url: URL(string: "https://cdn.example.com/files/a%20b.iso?sig=x&e=1")!,
            headers: [("Range", "bytes=0-99"), ("User-Agent", "Macget/1.0")]
        ))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /files/a%20b.iso?sig=x&e=1 HTTP/1.1\r\nHost: cdn.example.com\r\n"))
        XCTAssertTrue(text.contains("\r\nRange: bytes=0-99\r\n"))
        XCTAssertTrue(text.contains("\r\nConnection: keep-alive\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func test_nonDefaultPortInHost() throws {
        let data = try XCTUnwrap(PinnedRequest.bytes(url: URL(string: "http://example.com:8080/")!, headers: []))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Host: example.com:8080\r\n"))
    }

    func test_headerInjectionIsStripped() throws {
        let data = try XCTUnwrap(PinnedRequest.bytes(url: URL(string: "https://example.com/x")!,
                                                     headers: [("Cookie", "a=1\r\nEvil: yes")]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("\r\nEvil: yes"))
    }

    func test_emptyPathBecomesSlash() throws {
        let data = try XCTUnwrap(PinnedRequest.bytes(url: URL(string: "https://example.com")!, headers: []))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("GET / HTTP/1.1\r\n"))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `$TEST -only-testing:MacgetTests/RangeResponseValidatorTests -only-testing:MacgetTests/PinnedRequestTests`
Expected: build failure — `cannot find 'RangeResponseValidator' in scope`.

- [ ] **Step 3: Implement `RangeResponseValidator` and use it from `StreamingDelegate`**

`Macget/Engine/RangeResponseValidator.swift`:

```swift
import Foundation

/// The 206 / Content-Range checks every ranged response must pass, shared by the
/// URLSession path and the pinned-link path so the two can't drift apart.
enum RangeResponseValidator {
    /// Returns nil when the response may be streamed, else the error to raise.
    static func validate(
        status: Int,
        contentRange: String?,
        retryAfter: String?,
        expectedStart: Int64,
        expectedEnd: Int64,
        unbounded: Bool
    ) -> ChunkError? {
        if unbounded {
            // No Range was sent — any 2xx is the full body.
            return (200..<300).contains(status) ? nil : statusError(status, retryAfter: retryAfter)
        }
        if status == 200 { return .rangeRefused(200) }
        if status != 206 { return statusError(status, retryAfter: retryAfter) }
        if let contentRange {
            let expected = "bytes \(expectedStart)-\(expectedEnd)/"
            if !contentRange.hasPrefix(expected) {
                return .wrongContentRange(expected: expected + "<total>", got: contentRange)
            }
        }
        return nil
    }

    /// 429/503 carry the parsed `Retry-After`; 401/407 surface as `authRequired`.
    static func statusError(_ status: Int, retryAfter: String?) -> ChunkError {
        switch status {
        case 429, 503: return .serverBusy(code: status, retryAfter: RetryAfter.parse(retryAfter))
        case 401, 407: return .authRequired(code: status)
        default: return .unexpectedStatus(status)
        }
    }
}
```

In `Macget/Engine/ChunkWorker.swift`, replace the body of `StreamingDelegate.urlSession(_:dataTask:didReceive:completionHandler:)` after the `guard let http …` block with:

```swift
        if let error = RangeResponseValidator.validate(
            status: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            expectedStart: expectedStart,
            expectedEnd: expectedEnd,
            unbounded: unbounded
        ) {
            continuation?.finish(throwing: error)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
```

and delete the now-unused `private static func statusError(_ http: HTTPURLResponse)`.

- [ ] **Step 4: Implement `PinnedTransport` and `PinnedRequest`**

`Macget/Engine/Bonding/PinnedTransport.swift`:

```swift
import Foundation

/// One HTTP GET over a specific network link.
///
/// URLSession can't pin a request to an interface on macOS, so workers assigned
/// to a non-default link use this instead. Kept to the narrow job the engine
/// needs — ranged GETs — so its failure mode is "that link isn't used", never a
/// failed download.
protocol PinnedTransport: Sendable {
    /// Returns once the response head has arrived. The body streams afterwards.
    func get(url: URL, headers: [(String, String)], linkID: String) async throws -> PinnedResponse
}

struct PinnedResponse: Sendable {
    let head: HTTPResponseHead
    let body: AsyncThrowingStream<Data, Error>
}

enum PinnedTransportError: Error, LocalizedError, Equatable {
    case unsupportedURL
    case interfaceUnavailable(String)
    case tlsFailed(String)
    case connectionFailed(String)
    case closedBeforeResponse

    var isTLS: Bool {
        if case .tlsFailed = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedURL: return "Only http and https downloads can use extra links."
        case .interfaceUnavailable(let id): return "Network link \(id) is no longer available."
        case .tlsFailed(let detail): return "Secure connection failed on this link: \(detail)"
        case .connectionFailed(let detail): return "Connection failed on this link: \(detail)"
        case .closedBeforeResponse: return "The server closed the connection before responding."
        }
    }
}

/// Serializes an HTTP/1.1 GET.
enum PinnedRequest {
    static func bytes(url: URL, headers: [(String, String)]) -> Data? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true) { target += "?" + query }

        let scheme = url.scheme?.lowercased() ?? "https"
        let defaultPort = scheme == "https" ? 443 : 80
        let hostHeader = (url.port.map { $0 != defaultPort } ?? false) ? "\(host):\(url.port!)" : host

        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        }

        var text = "GET \(target) HTTP/1.1\r\nHost: \(hostHeader)\r\n"
        for (name, value) in headers {
            let n = clean(name)
            if n.caseInsensitiveCompare("Host") == .orderedSame || n.caseInsensitiveCompare("Connection") == .orderedSame { continue }
            text += "\(n): \(clean(value))\r\n"
        }
        text += "Connection: keep-alive\r\n\r\n"
        return Data(text.utf8)
    }
}
```

- [ ] **Step 5: Run to verify the tests pass**

Run: `$TEST -only-testing:MacgetTests/RangeResponseValidatorTests -only-testing:MacgetTests/PinnedRequestTests -only-testing:MacgetTests/UnknownSizeDownloadTests -only-testing:MacgetTests/ConcurrencyRampTests`
Expected: all pass (the last two prove the `StreamingDelegate` refactor kept URLSession behavior).

- [ ] **Step 6: Implement `NWPinnedTransport`**

`Macget/Engine/Bonding/NWPinnedTransport.swift`:

```swift
import Foundation
import Network
import OSLog

/// `PinnedTransport` over Network.framework: `NWConnection` with
/// `requiredInterface`, TLS from the system trust store, HTTP/1.1 keep-alive.
final class NWPinnedTransport: PinnedTransport, @unchecked Sendable {
    static let shared = NWPinnedTransport()

    private let pool = PinnedConnectionPool()
    private let queue = DispatchQueue(label: "com.macget.pinned-transport", attributes: .concurrent)
    private let interfaceLookup: @Sendable (String) async -> NWInterface?

    init(interfaceLookup: @escaping @Sendable (String) async -> NWInterface? = { await NetworkLinkMonitor.shared.interface(for: $0) }) {
        self.interfaceLookup = interfaceLookup
    }

    func get(url: URL, headers: [(String, String)], linkID: String) async throws -> PinnedResponse {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false),
              let request = PinnedRequest.bytes(url: url, headers: headers)
        else { throw PinnedTransportError.unsupportedURL }
        guard let iface = await interfaceLookup(linkID) else {
            throw PinnedTransportError.interfaceUnavailable(linkID)
        }
        let key = PinnedConnectionPool.Key(linkID: linkID, host: host,
                                           port: url.port ?? (scheme == "https" ? 443 : 80),
                                           tls: scheme == "https")

        // A pooled connection may have been closed by the server while idle;
        // that only shows up when we use it, so fall back to a fresh one once.
        if let reused = await pool.checkout(key) {
            do {
                return try await exchange(reused, request: request, key: key)
            } catch is CancellationError {
                reused.cancel()
                throw CancellationError()
            } catch {
                reused.cancel()
            }
        }
        let fresh = try await connect(key: key, interface: iface)
        return try await exchange(fresh, request: request, key: key)
    }

    private func connect(key: PinnedConnectionPool.Key, interface: NWInterface) async throws -> NWConnection {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        tcp.noDelay = true
        let params: NWParameters
        if key.tls {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, key.host)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.requiredInterface = interface
        params.preferNoProxies = true

        guard let port = NWEndpoint.Port(rawValue: UInt16(key.port)) else { throw PinnedTransportError.unsupportedURL }
        let connection = NWConnection(host: NWEndpoint.Host(key.host), port: port, using: params)
        try await connection.startAndWaitReady(queue: queue)
        return connection
    }

    /// Sends the request and reads until the response head arrives. The rest of
    /// the body is pumped by a task that feeds the returned stream.
    private func exchange(_ connection: NWConnection, request: Data, key: PinnedConnectionPool.Key) async throws -> PinnedResponse {
        try await connection.sendAsync(request)

        var parser = HTTPResponseParser()
        var head: HTTPResponseHead?
        var early: [Data] = []
        var peerClosed = false
        while head == nil {
            let (data, isComplete) = try await connection.receiveChunk()
            var events = try data.map { try parser.feed($0) } ?? []
            if isComplete {
                peerClosed = true
                events += try parser.finish()
            }
            for event in events {
                switch event {
                case .head(let h): head = h
                case .body(let d): early.append(d)
                case .end: break
                }
            }
            if isComplete && head == nil { throw PinnedTransportError.closedBeforeResponse }
        }

        let finalHead = head!
        let reusable = !peerClosed && finalHead.value("connection")?.lowercased() != "close"
        let pool = self.pool
        let startParser = parser

        let body = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in early { continuation.yield(chunk) }
            if startParser.isComplete {
                Task {
                    if reusable {
                        await pool.checkin(connection, key: key)
                    } else {
                        connection.cancel()
                    }
                }
                continuation.finish()
                return
            }
            let pump = Task {
                var parser = startParser
                do {
                    while true {
                        let (data, isComplete) = try await connection.receiveChunk()
                        var events = try data.map { try parser.feed($0) } ?? []
                        if isComplete { events += try parser.finish() }
                        for case .body(let d) in events { continuation.yield(d) }
                        if parser.isComplete {
                            if reusable && !isComplete {
                                await pool.checkin(connection, key: key)
                            } else {
                                connection.cancel()
                            }
                            continuation.finish()
                            return
                        }
                    }
                } catch {
                    connection.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    pump.cancel()
                    connection.cancel()
                }
            }
        }
        return PinnedResponse(head: finalHead, body: body)
    }
}

/// Idle keep-alive connections per (link, host, port, scheme), so stealing the
/// next piece doesn't cost another TLS handshake over a slow tethered link.
actor PinnedConnectionPool {
    struct Key: Hashable, Sendable {
        let linkID: String
        let host: String
        let port: Int
        let tls: Bool
    }

    static let maxIdlePerKey = 16
    private var idle: [Key: [NWConnection]] = [:]

    func checkout(_ key: Key) -> NWConnection? {
        var list = idle[key] ?? []
        defer { idle[key] = list.isEmpty ? nil : list }
        while let connection = list.popLast() {
            if case .ready = connection.state { return connection }
            connection.cancel()
        }
        return nil
    }

    func checkin(_ connection: NWConnection, key: Key) {
        guard case .ready = connection.state else { connection.cancel(); return }
        var list = idle[key] ?? []
        guard list.count < Self.maxIdlePerKey else { connection.cancel(); return }
        list.append(connection)
        idle[key] = list
    }
}

/// Resumes a continuation at most once — `NWConnection.stateUpdateHandler` keeps
/// firing after the state we were waiting for.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

extension NWConnection {
    func startAndWaitReady(queue: DispatchQueue) async throws {
        let once = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        once.run { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        // `.waiting` means no route on this interface right now.
                        // For a pinned link that's a failure, not something to wait out.
                        self?.cancel()
                        once.run { continuation.resume(throwing: Self.map(error)) }
                    case .cancelled:
                        once.run { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                start(queue: queue)
            }
        } onCancel: {
            self.cancel()
        }
    }

    func sendAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: Self.map(error)) } else { continuation.resume() }
            })
        }
    }

    /// One read of up to 64 KB. `isComplete` means the peer closed its side.
    func receiveChunk(maximumLength: Int = 64 * 1024) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: Self.map(error))
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    fileprivate static func map(_ error: NWError) -> PinnedTransportError {
        if case .tls = error { return .tlsFailed(error.debugDescription) }
        return .connectionFailed(error.debugDescription)
    }
}
```

- [ ] **Step 7: Build and run the full suite**

Run: `$TEST`
Expected: all tests pass (`NWPinnedTransport` has no unit tests; it is exercised by the manual check in Task 17).

- [ ] **Step 8: Commit**

```bash
git add Macget/Engine/RangeResponseValidator.swift Macget/Engine/Bonding/PinnedTransport.swift Macget/Engine/Bonding/NWPinnedTransport.swift Macget/Engine/ChunkWorker.swift MacgetTests/RangeResponseValidatorTests.swift MacgetTests/PinnedRequestTests.swift
git commit -m "feat(bonding): add Network.framework pinned HTTP transport"
```

---

### Task 8: `ChunkWorker` pinned route, link errors, local-address metrics

**Files:**
- Modify: `Macget/Engine/ChunkWorker.swift`
- Modify: `Macget/Engine/DownloadCoordinator.swift` (`isPermanentChunkError` switch only — it is exhaustive)
- Test: `MacgetTests/PinnedChunkWorkerTests.swift`

**Interfaces:**
- Consumes: `PinnedTransport`, `PinnedResponse`, `PinnedTransportError`, `RangeResponseValidator`.
- Produces:
  - `ChunkError.linkRejected(linkID: String, serverRefused: Bool)` — drop this link for this download.
  - `ChunkError.linkTransport(linkID: String, detail: String)` — a strike against the link.
  - `struct PinnedRoute: Sendable { let linkID: String; let transport: any PinnedTransport }`
  - `ChunkWorker.pinned: PinnedRoute?`, `ChunkWorker.onLocalAddress: (@Sendable (String) -> Void)?`
  - `static func ChunkWorker.pinnedFailure(_ error: ChunkError, linkID: String) -> ChunkError`
  - `ChunkWorker.maxRedirects = 5`

- [ ] **Step 1: Write the failing test**

`MacgetTests/PinnedChunkWorkerTests.swift` (the `StubPinnedTransport` defined here is reused by Task 9):

```swift
import XCTest
@testable import Macget

/// Deterministic file content: byte i is `i % 251`, so any misplaced range shows.
enum BondingTestData {
    static func bytes(_ range: ClosedRange<Int64>) -> Data {
        Data(range.map { UInt8(truncatingIfNeeded: $0 % 251) })
    }

    static func parseRange(_ header: String, total: Int64) -> (Int64, Int64)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0]) else { return nil }
        let end = Int64(parts[1]) ?? (total - 1)
        return (start, min(end, total - 1))
    }
}

final class StubPinnedTransport: PinnedTransport, @unchecked Sendable {
    enum Mode { case serve, status(Int), redirect(String), hang, fail }

    private let lock = NSLock()
    private var _mode: Mode
    private var _requests: [(url: URL, headers: [(String, String)], linkID: String)] = []
    let totalBytes: Int64

    init(mode: Mode, totalBytes: Int64) {
        _mode = mode
        self.totalBytes = totalBytes
    }

    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requests.count }
    var lastURL: URL? { lock.lock(); defer { lock.unlock() }; return _requests.last?.url }
    var lastHeaders: [(String, String)] { lock.lock(); defer { lock.unlock() }; return _requests.last?.headers ?? [] }

    func get(url: URL, headers: [(String, String)], linkID: String) async throws -> PinnedResponse {
        lock.lock(); _requests.append((url, headers, linkID)); let mode = _mode; lock.unlock()
        let range = headers.first { $0.0 == "Range" }.flatMap { BondingTestData.parseRange($0.1, total: totalBytes) }

        switch mode {
        case .fail:
            throw PinnedTransportError.connectionFailed("stub")
        case .status(let code):
            return PinnedResponse(head: HTTPResponseHead(status: code, headers: [:]),
                                  body: AsyncThrowingStream { $0.finish() })
        case .redirect(let location):
            self.mode = .serve
            return PinnedResponse(head: HTTPResponseHead(status: 302, headers: ["Location": location]),
                                  body: AsyncThrowingStream { $0.finish() })
        case .hang:
            let (s, e) = range ?? (0, totalBytes - 1)
            return PinnedResponse(head: HTTPResponseHead(status: 206, headers: ["Content-Range": "bytes \(s)-\(e)/\(totalBytes)"]),
                                  body: AsyncThrowingStream { _ in })
        case .serve:
            guard let (s, e) = range else { throw PinnedTransportError.unsupportedURL }
            let data = BondingTestData.bytes(s...e)
            return PinnedResponse(
                head: HTTPResponseHead(status: 206, headers: ["Content-Range": "bytes \(s)-\(e)/\(totalBytes)"]),
                body: AsyncThrowingStream { c in
                    var offset = 0
                    while offset < data.count {
                        let end = min(offset + 64 * 1024, data.count)
                        c.yield(data.subdata(in: offset..<end))
                        offset = end
                    }
                    c.finish()
                }
            )
        }
    }
}

final class PinnedChunkWorkerTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macget-pinned-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func runWorker(_ transport: StubPinnedTransport, chunk: Chunk, total: Int64) async throws -> Data {
        let url = dir.appendingPathComponent("f.bin")
        let writer = try FileWriter(url: url, totalBytes: total)
        let worker = ChunkWorker(
            chunk: chunk,
            url: URL(string: "https://example.com/f.bin")!,
            etag: "\"v1\"",
            lastModified: nil,
            writer: writer,
            session: .shared,
            pinned: PinnedRoute(linkID: "en7", transport: transport),
            report: { _, _ in }
        )
        try await worker.run()
        await writer.close()
        return try Data(contentsOf: url)
    }

    func test_pinnedRouteWritesTheRequestedRange() async throws {
        let total: Int64 = 300_000
        let transport = StubPinnedTransport(mode: .serve, totalBytes: total)
        let chunk = Chunk(startByte: 1000, endByte: 200_999)
        let file = try await runWorker(transport, chunk: chunk, total: total)
        XCTAssertEqual(file.subdata(in: 1000..<201_000), BondingTestData.bytes(1000...200_999))
        XCTAssertEqual(transport.lastHeaders.first { $0.0 == "If-Range" }?.1, "\"v1\"")
        XCTAssertEqual(transport.lastHeaders.first { $0.0 == "Accept-Encoding" }?.1, "identity")
    }

    func test_403BecomesLinkRejected() async throws {
        let transport = StubPinnedTransport(mode: .status(403), totalBytes: 1000)
        do {
            _ = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 999), total: 1000)
            XCTFail("expected throw")
        } catch ChunkError.linkRejected(let id, let refused) {
            XCTAssertEqual(id, "en7")
            XCTAssertTrue(refused)
        }
    }

    func test_rangeIgnoredBecomesLinkRejectedNotRangeRefused() async throws {
        let transport = StubPinnedTransport(mode: .status(200), totalBytes: 1000)
        do {
            _ = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 999), total: 1000)
            XCTFail("expected throw")
        } catch ChunkError.linkRejected { }
    }

    func test_busyStaysRetryable() async throws {
        let transport = StubPinnedTransport(mode: .status(503), totalBytes: 1000)
        do {
            _ = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 999), total: 1000)
            XCTFail("expected throw")
        } catch ChunkError.serverBusy { }
    }

    func test_connectionFailureBecomesLinkTransport() async throws {
        let transport = StubPinnedTransport(mode: .fail, totalBytes: 1000)
        do {
            _ = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 999), total: 1000)
            XCTFail("expected throw")
        } catch ChunkError.linkTransport(let id, _) {
            XCTAssertEqual(id, "en7")
        }
    }

    func test_followsRedirectOnSameLink() async throws {
        let total: Int64 = 2000
        let transport = StubPinnedTransport(mode: .redirect("/real/f.bin"), totalBytes: total)
        let file = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 1999), total: total)
        XCTAssertEqual(file, BondingTestData.bytes(0...1999))
        XCTAssertEqual(transport.lastURL?.absoluteString, "https://example.com/real/f.bin")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func test_pinnedFailureMapping() {
        func map(_ e: ChunkError) -> ChunkError { ChunkWorker.pinnedFailure(e, linkID: "en7") }
        guard case .linkRejected(_, true) = map(.authRequired(code: 401)) else { return XCTFail() }
        guard case .linkRejected(_, true) = map(.unexpectedStatus(404)) else { return XCTFail() }
        guard case .linkRejected(_, true) = map(.wrongContentRange(expected: "a", got: "b")) else { return XCTFail() }
        guard case .unexpectedStatus(500) = map(.unexpectedStatus(500)) else { return XCTFail() }
        guard case .serverBusy = map(.serverBusy(code: 429, retryAfter: nil)) else { return XCTFail() }
    }
}
```

Check `Chunk`'s initializer before running: `grep -n "init(" Macget/Models/Chunk.swift`. If it isn't `Chunk(startByte:endByte:)`, adapt the test's calls to the real initializer (the coordinator already uses `Chunk(startByte: 0, endByte: …)` in `runSingleStream`, so it should be).

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/PinnedChunkWorkerTests`
Expected: build failure — `cannot find 'PinnedRoute' in scope`.

- [ ] **Step 3: Add the error cases**

In `ChunkError` (top of `ChunkWorker.swift`) add:

```swift
    /// A pinned (non-default) link was refused by the server or can't serve this
    /// file — drop the link for this download. Never fails the download.
    case linkRejected(linkID: String, serverRefused: Bool)
    /// A pinned link's connection failed. Counts as a strike against the link;
    /// the piece goes straight back to the pool rather than backing off.
    case linkTransport(linkID: String, detail: String)
```

and in `errorDescription`:

```swift
        case .linkRejected(let id, let refused):
            return refused ? "Server refused connections over \(id)." : "Network link \(id) is unusable for this download."
        case .linkTransport(let id, let detail):
            return "Connection over \(id) failed: \(detail)"
```

In `DownloadCoordinator.isPermanentChunkError`, extend the `ChunkError` switch:

```swift
            case .noHttpResponse, .serverBusy, .linkRejected, .linkTransport:
                return false
```

- [ ] **Step 4: Add the pinned route to `ChunkWorker`**

Add near the other `ChunkWorker` properties (before `let report`):

```swift
    /// When set, this attempt runs over a specific network link through the
    /// pinned transport instead of URLSession. Never set for unbounded streams.
    var pinned: PinnedRoute? = nil
    /// URLSession path only: called with the local IP the connection used, so
    /// the coordinator can attribute default-link bytes to the right interface.
    var onLocalAddress: (@Sendable (String) -> Void)? = nil
```

At file scope (after `ChunkError`):

```swift
struct PinnedRoute: Sendable {
    let linkID: String
    let transport: any PinnedTransport
}
```

In `run()`, replace the final `try await stream(request: req, …)` call (the ranged one) with:

```swift
        if let pinned {
            try await streamPinned(route: pinned, request: req, expectedStart: requestStart, expectedEnd: requestEnd)
        } else {
            try await stream(request: req, expectedStart: requestStart, expectedEnd: requestEnd, startingOffset: requestStart, unbounded: false)
        }
```

Split `stream(…)` into the URLSession stream construction and a shared write loop. Replace the whole `stream` function with:

```swift
    private func stream(request: URLRequest, expectedStart: Int64, expectedEnd: Int64, startingOffset: Int64, unbounded: Bool) async throws {
        let delegate = StreamingDelegate()
        delegate.credential = credential
        delegate.onLocalAddress = onLocalAddress
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            delegate.attach(continuation: continuation, expectedRangeStart: expectedStart, expectedRangeEnd: expectedEnd, unbounded: unbounded)
            let task = session.dataTask(with: request)
            task.delegate = delegate
            // Tell URLSession's scheduler this task matters more than the default,
            // so when bandwidth is contested (e.g. another app streaming video) our
            // chunks aren't the first to back off.
            task.priority = URLSessionTask.highPriority
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
        try await write(stream, startingOffset: startingOffset, expectedEnd: expectedEnd, unbounded: unbounded)
    }

    static let maxRedirects = 5

    /// The pinned-link equivalent of `stream`. Every failure is translated so it
    /// can only ever cost this download the link, never the download itself.
    private func streamPinned(route: PinnedRoute, request: URLRequest, expectedStart: Int64, expectedEnd: Int64) async throws {
        var headers: [(String, String)] = (request.allHTTPHeaderFields ?? [:]).map { ($0.key, $0.value) }
        if !headers.contains(where: { $0.0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            headers.append(("User-Agent", URLSessionFactory.userAgent))
        }
        headers.append(("Accept-Encoding", "identity"))
        // Preemptive Basic only over TLS — never send a password in the clear.
        if let credential, let user = credential.user, let password = credential.password,
           request.url?.scheme?.lowercased() == "https" {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            headers.append(("Authorization", "Basic \(token)"))
        }

        guard var url = request.url else { throw ChunkError.linkRejected(linkID: route.linkID, serverRefused: false) }
        var response: PinnedResponse
        var redirects = 0
        while true {
            do {
                response = try await route.transport.get(url: url, headers: headers, linkID: route.linkID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PinnedTransportError where error.isTLS {
                throw ChunkError.linkRejected(linkID: route.linkID, serverRefused: false)
            } catch {
                throw ChunkError.linkTransport(linkID: route.linkID, detail: error.localizedDescription)
            }
            let status = response.head.status
            guard [301, 302, 303, 307, 308].contains(status) else { break }
            guard redirects < Self.maxRedirects,
                  let location = response.head.value("location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL
            else { throw ChunkError.linkRejected(linkID: route.linkID, serverRefused: true) }
            redirects += 1
            url = next
        }

        if let error = RangeResponseValidator.validate(
            status: response.head.status,
            contentRange: response.head.value("content-range"),
            retryAfter: response.head.value("retry-after"),
            expectedStart: expectedStart,
            expectedEnd: expectedEnd,
            unbounded: false
        ) {
            throw Self.pinnedFailure(error, linkID: route.linkID)
        }

        let linkID = route.linkID
        let body = response.body
        let translated = AsyncThrowingStream<Data, Error> { continuation in
            let pump = Task {
                do {
                    for try await data in body { continuation.yield(data) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: ChunkError.linkTransport(linkID: linkID, detail: error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
        try await write(translated, startingOffset: expectedStart, expectedEnd: expectedEnd, unbounded: false)
    }

    /// Validation failures on a pinned link mean "this link can't serve this
    /// file" — a signed URL bound to the other IP, a different CDN edge, auth the
    /// pinned transport can't do. Only transient server states stay retryable.
    static func pinnedFailure(_ error: ChunkError, linkID: String) -> ChunkError {
        switch error {
        case .rangeRefused, .wrongContentRange, .authRequired:
            return .linkRejected(linkID: linkID, serverRefused: true)
        case .unexpectedStatus(let code) where (300..<500).contains(code):
            return .linkRejected(linkID: linkID, serverRefused: true)
        default:
            return error
        }
    }

    /// Buffers deliveries into 64 KB writes at increasing offsets.
    private func write(_ stream: AsyncThrowingStream<Data, Error>, startingOffset: Int64, expectedEnd: Int64, unbounded: Bool) async throws {
        var offset = startingOffset
        var buffer = Data()
        buffer.reserveCapacity(Self.writeBufferBytes)
        // Guard against `expectedEnd + 1` overflowing for the unbounded sentinel.
        let chunkEndExclusive = (expectedEnd == .max) ? Int64.max : expectedEnd + 1

        for try await piece in stream {
            try Task.checkCancellation()

            let usable: Data
            if unbounded {
                // Unknown total size — take everything the server sends.
                usable = piece
            } else {
                // Don't write past the chunk end if server over-reads.
                let allowedRemaining = chunkEndExclusive - (offset + Int64(buffer.count))
                if allowedRemaining <= 0 { break }
                usable = (Int64(piece.count) > allowedRemaining)
                    ? piece.prefix(Int(allowedRemaining))
                    : piece
            }
            buffer.append(usable)

            if buffer.count >= Self.writeBufferBytes {
                let toWrite = buffer
                try await writer.write(toWrite, at: offset)
                offset += Int64(toWrite.count)
                await report(chunk.id, toWrite.count)
                await rateLimiter?.consume(toWrite.count)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            let toWrite = buffer
            try await writer.write(toWrite, at: offset)
            await report(chunk.id, toWrite.count)
            await rateLimiter?.consume(toWrite.count)
        }
    }
```

(The unbounded call site at the top of `run()` keeps calling `stream(…, unbounded: true)` and so stays on URLSession.)

In `StreamingDelegate`, add the property and the metrics callback:

```swift
    /// Reports the local address the finished task used (URLSession picks the interface).
    var onLocalAddress: (@Sendable (String) -> Void)?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        if let address = metrics.transactionMetrics.last?.localAddress {
            onLocalAddress?(address)
        }
    }
```

- [ ] **Step 5: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/PinnedChunkWorkerTests -only-testing:MacgetTests/UnknownSizeDownloadTests -only-testing:MacgetTests/ConcurrencyRampTests -only-testing:MacgetTests/RetryClassificationTests`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Macget/Engine/ChunkWorker.swift Macget/Engine/DownloadCoordinator.swift MacgetTests/PinnedChunkWorkerTests.swift
git commit -m "feat(bonding): let ChunkWorker run a piece over a pinned link"
```

---

### Task 9: Coordinator — link assignment, per-link stats, link failure handling

**Files:**
- Create: `Macget/Engine/Bonding/LinkStatBuilder.swift`
- Modify: `Macget/Engine/DownloadCoordinator.swift`
- Test: `MacgetTests/LinkStatBuilderTests.swift`, `MacgetTests/BondingCoordinatorTests.swift`

**Interfaces:**
- Consumes: `LinkProvider`, `NetworkLink`, `BondingSettings`, `BondingPolicy`, `LinkQuota`, `LinkStrikes`, `BondingEligibility`, `PinnedTransport`, `PinnedRoute`, `ChunkError.linkRejected/.linkTransport`, `LinkStat`, `StubPinnedTransport` + `BondingTestData` (test target, Task 8).
- Produces:
  - `DownloadSnapshot.links: [LinkStat]` (default `[]`)
  - `DownloadCoordinator.init(…, linkProvider: LinkProvider? = nil, pinnedTransport: (any PinnedTransport)? = nil, bonding: BondingSettings = BondingSettings(), appProxyConfigured: Bool = false, …)` — new params inserted after `autoSortByType`.
  - `DownloadCoordinator.updateBonding(_ settings: BondingSettings)`
  - `enum LinkStatBuilder { static func build(links:speeds:bytes:connections:statuses:) -> [LinkStat] }`

- [ ] **Step 1: Write the failing `LinkStatBuilder` test**

```swift
import XCTest
@testable import Macget

final class LinkStatBuilderTests: XCTestCase {
    private let wifi = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: [], isDefaultRoute: true)
    private let tether = NetworkLink(id: "en7", displayName: "iPhone USB", kind: .tethered, addresses: [], isDefaultRoute: false)

    func test_buildsOneStatPerLinkInOrder() {
        let stats = LinkStatBuilder.build(
            links: [wifi, tether],
            speeds: ["en0": 1_000, "en7": 3_000],
            bytes: ["en0": 10, "en7": 30],
            connections: ["en0": 4, "en7": 4],
            statuses: [:]
        )
        XCTAssertEqual(stats.map(\.linkID), ["en0", "en7"])
        XCTAssertEqual(stats.map(\.speedBytesPerSec), [1_000, 3_000])
        XCTAssertEqual(stats.map(\.status), [.active, .active])
        XCTAssertEqual(stats.map(\.speedBytesPerSec).reduce(0, +), 4_000)
    }

    func test_rejectedLinkStillListedWithStatus() {
        let stats = LinkStatBuilder.build(links: [wifi, tether], speeds: ["en0": 1_000], bytes: ["en0": 10, "en7": 0],
                                          connections: ["en0": 8], statuses: ["en7": .rejectedByServer])
        XCTAssertEqual(stats.last?.status, .rejectedByServer)
        XCTAssertEqual(stats.last?.speedBytesPerSec, 0)
    }

    func test_goneLinkWithBytesIsKeptAsDown() {
        // The phone was unplugged: its link vanished from `links` but carried bytes earlier.
        let stats = LinkStatBuilder.build(links: [wifi], speeds: ["en0": 1_000], bytes: ["en0": 10, "en7": 99],
                                          connections: [:], statuses: ["en7": .down], knownNames: ["en7": ("iPhone USB", .tethered)])
        XCTAssertEqual(stats.map(\.linkID), ["en0", "en7"])
        XCTAssertEqual(stats.last?.status, .down)
    }

    func test_emptyWhenOnlyOneLinkInvolved() {
        XCTAssertEqual(LinkStatBuilder.build(links: [wifi], speeds: ["en0": 1], bytes: ["en0": 1], connections: [:], statuses: [:]), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/LinkStatBuilderTests`
Expected: build failure — `cannot find 'LinkStatBuilder' in scope`.

- [ ] **Step 3: Implement `LinkStatBuilder`**

`Macget/Engine/Bonding/LinkStatBuilder.swift`:

```swift
import Foundation

/// Turns the coordinator's per-link counters into display rows.
enum LinkStatBuilder {
    /// - Parameters:
    ///   - links: currently usable links involved in this download, in display order.
    ///   - knownNames: names for links that have since disappeared but still have
    ///     bytes or a status to show (so an unplugged phone reads "Link down"
    ///     rather than vanishing from the breakdown).
    /// - Returns: empty unless at least two links are involved.
    static func build(
        links: [NetworkLink],
        speeds: [String: Double],
        bytes: [String: Int64],
        connections: [String: Int],
        statuses: [String: LinkStat.Status],
        knownNames: [String: (String, NetworkLink.Kind)] = [:]
    ) -> [LinkStat] {
        var rows: [LinkStat] = links.map { link in
            LinkStat(
                linkID: link.id, displayName: link.displayName, kind: link.kind,
                speedBytesPerSec: speeds[link.id] ?? 0,
                bytesThisSession: bytes[link.id] ?? 0,
                activeConnections: connections[link.id] ?? 0,
                status: statuses[link.id] ?? .active,
                isEstimate: false
            )
        }
        let present = Set(links.map(\.id))
        for (id, total) in bytes.sorted(by: { $0.key < $1.key }) where !present.contains(id) && (total > 0 || statuses[id] != nil) {
            let (name, kind) = knownNames[id] ?? (id, .other)
            rows.append(LinkStat(linkID: id, displayName: name, kind: kind, speedBytesPerSec: 0,
                                 bytesThisSession: total, activeConnections: 0,
                                 status: statuses[id] ?? .down, isEstimate: false))
        }
        return rows.count >= 2 ? rows : []
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/LinkStatBuilderTests`
Expected: 4 tests pass.

- [ ] **Step 5: Write the failing coordinator tests**

`MacgetTests/BondingCoordinatorTests.swift`:

```swift
import XCTest
@testable import Macget

/// Ranged URLSession stub for the default link: HEAD advertises ranges, GET serves `BondingTestData`.
final class BondingStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var totalBytes: Int64 = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let total = Self.totalBytes
        var headers = ["Accept-Ranges": "bytes", "ETag": "\"v1\""]
        var status = 200
        var body = Data()
        if request.httpMethod == "HEAD" {
            headers["Content-Length"] = String(total)
        } else if let raw = request.value(forHTTPHeaderField: "Range"),
                  let (s, e) = BondingTestData.parseRange(raw, total: total) {
            status = 206
            headers["Content-Range"] = "bytes \(s)-\(e)/\(total)"
            headers["Content-Length"] = String(e - s + 1)
            body = BondingTestData.bytes(s...e)
        } else {
            headers["Content-Length"] = String(total)
            body = BondingTestData.bytes(0...(total - 1))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class StubLinkProvider: LinkProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _links: [NetworkLink]
    init(_ links: [NetworkLink]) { _links = links }
    var links: [NetworkLink] {
        get { lock.lock(); defer { lock.unlock() }; return _links }
        set { lock.lock(); _links = newValue; lock.unlock() }
    }
    func usableLinks() async -> [NetworkLink] { links }
}

actor SnapshotLog {
    private(set) var snapshots: [DownloadSnapshot] = []
    private(set) var final: Download?
    func add(_ s: DownloadSnapshot) { snapshots.append(s) }
    func finish(_ d: Download) { final = d }
}

final class BondingCoordinatorTests: XCTestCase {
    static let wifi = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: ["192.168.0.5"], isDefaultRoute: true)
    static let tether = NetworkLink(id: "en7", displayName: "iPhone USB", kind: .tethered, addresses: ["172.20.10.2"], isDefaultRoute: false)
    let total: Int64 = 32 * 1024 * 1024

    private var dir: URL!
    private var capStoreURL: URL!

    override func setUp() {
        BondingStubURLProtocol.totalBytes = total
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macget-bond-\(UUID().uuidString)")
        capStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent("caps-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: capStoreURL)
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BondingStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func run(
        transport: StubPinnedTransport,
        provider: StubLinkProvider,
        capStore: HostCapStore? = nil,
        timeout: TimeInterval = 30
    ) async throws -> (Download?, [DownloadSnapshot]) {
        var download = Download(url: URL(string: "https://bond.example.com/big.bin")!, destinationFolder: dir, filename: "big.bin")
        download.threadCount = 8
        let log = SnapshotLog()
        let done = expectation(description: "terminal")
        let coordinator = DownloadCoordinator(
            download: download,
            session: session(),
            hostCapStore: capStore ?? HostCapStore(fileURL: capStoreURL),
            linkProvider: provider,
            pinnedTransport: transport,
            bonding: BondingSettings(enabled: true),
            onStateChange: { d in
                if d.status.isTerminal { await log.finish(d); done.fulfill() }
            },
            onSnapshot: { s in await log.add(s) }
        )
        await coordinator.start()
        await fulfillment(of: [done], timeout: timeout)
        return (await log.final, await log.snapshots)
    }

    private func assertFileIsCorrect() throws {
        let data = try Data(contentsOf: dir.appendingPathComponent("big.bin"))
        XCTAssertEqual(data.count, Int(total))
        XCTAssertEqual(data, BondingTestData.bytes(0...(total - 1)))
    }

    func test_bothLinksCarryBytesAndFileIsCorrect() async throws {
        let transport = StubPinnedTransport(mode: .serve, totalBytes: total)
        let (final, snaps) = try await run(transport: transport, provider: StubLinkProvider([Self.wifi, Self.tether]))
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        try assertFileIsCorrect()
        XCTAssertGreaterThan(transport.requestCount, 0, "pinned link was never used")
        let withLinks = snaps.first { $0.links.count == 2 }
        XCTAssertNotNil(withLinks, "no snapshot carried a two-link breakdown")
        XCTAssertEqual(withLinks?.links.map(\.linkID), ["en0", "en7"])
    }

    func test_pinned403_dropsLinkAndCompletes() async throws {
        let transport = StubPinnedTransport(mode: .status(403), totalBytes: total)
        let (final, snaps) = try await run(transport: transport, provider: StubLinkProvider([Self.wifi, Self.tether]))
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        try assertFileIsCorrect()
        XCTAssertTrue(snaps.contains { $0.links.contains { $0.linkID == "en7" && $0.status == .rejectedByServer } })
        // One rejection excludes the link; later spawns never try it again.
        XCTAssertLessThanOrEqual(transport.requestCount, 4)
    }

    func test_pinnedRangeIgnored_doesNotFailDownload() async throws {
        let transport = StubPinnedTransport(mode: .status(200), totalBytes: total)
        let (final, _) = try await run(transport: transport, provider: StubLinkProvider([Self.wifi, Self.tether]))
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        try assertFileIsCorrect()
    }

    func test_linkDisappears_workersReassigned() async throws {
        let transport = StubPinnedTransport(mode: .hang, totalBytes: total)
        let provider = StubLinkProvider([Self.wifi, Self.tether])
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            provider.links = [Self.wifi]   // phone unplugged
        }
        let start = Date()
        let (final, snaps) = try await run(transport: transport, provider: provider, timeout: 20)
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        try assertFileIsCorrect()
        XCTAssertLessThan(Date().timeIntervalSince(start), 15, "should not wait for the 30s stall watchdog")
        XCTAssertTrue(snaps.contains { $0.links.contains { $0.linkID == "en7" && $0.status == .down } })
    }

    func test_flakyPinnedLink_neverWritesHostCap() async throws {
        let capStore = HostCapStore(fileURL: capStoreURL)
        let transport = StubPinnedTransport(mode: .fail, totalBytes: total)
        let (final, _) = try await run(transport: transport, provider: StubLinkProvider([Self.wifi, Self.tether]), capStore: capStore)
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        let cap = await capStore.cap(for: "bond.example.com")
        XCTAssertNil(cap, "a failing pinned link must not teach a host cap")
    }

    func test_bondingOffNeverTouchesPinnedTransport() async throws {
        let transport = StubPinnedTransport(mode: .serve, totalBytes: total)
        var download = Download(url: URL(string: "https://bond.example.com/big.bin")!, destinationFolder: dir, filename: "big.bin")
        download.threadCount = 8
        let done = expectation(description: "terminal")
        let coordinator = DownloadCoordinator(
            download: download, session: session(), hostCapStore: HostCapStore(fileURL: capStoreURL),
            linkProvider: StubLinkProvider([Self.wifi, Self.tether]), pinnedTransport: transport,
            bonding: BondingSettings(enabled: false),
            onStateChange: { d in if d.status.isTerminal { done.fulfill() } },
            onSnapshot: { _ in }
        )
        await coordinator.start()
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(transport.requestCount, 0)
    }
}
```

- [ ] **Step 6: Run to verify they fail**

Run: `$TEST -only-testing:MacgetTests/BondingCoordinatorTests`
Expected: build failure — `extra arguments 'linkProvider', 'pinnedTransport', 'bonding'`.

- [ ] **Step 7: Implement coordinator changes**

In `Macget/Engine/DownloadCoordinator.swift`:

1. `DownloadSnapshot` — add after `isSeeding`:

```swift
    /// Per-link breakdown when more than one network link is carrying this
    /// download; empty otherwise. Live only, never persisted.
    var links: [LinkStat] = []
```

2. New stored properties (after `splitCount`):

```swift
    // MARK: Bonding state

    /// How a worker reaches the server.
    private enum WorkerRoute: Equatable {
        case urlSession
        case pinned(String)
    }

    private let linkProvider: LinkProvider?
    private let pinnedTransport: (any PinnedTransport)?
    private var bonding: BondingSettings
    private let appProxyConfigured: Bool
    /// Decided once per run after the probe: range support + no proxy + http(s).
    private var bondingEligible = false
    private var currentLinks: [NetworkLink] = []
    /// Route each in-flight piece is using, keyed like `inFlight`.
    private var inFlightRoute: [UUID: WorkerRoute] = [:]
    /// Links the server refused or that failed repeatedly — out for the rest of this run.
    private var excludedLinks: Set<String> = []
    private var linkStatuses: [String: LinkStat.Status] = [:]
    private var linkStrikes = LinkStrikes()
    private var linkBytes: [String: Int64] = [:]
    private var linkMeters: [String: SpeedMeter] = [:]
    private var knownLinkNames: [String: (String, NetworkLink.Kind)] = [:]
    /// The interface URLSession is actually using; starts as the default route
    /// and is corrected from task metrics.
    private var urlSessionLinkID: String?
```

3. `init` — add parameters after `autoSortByType: Bool = false,`:

```swift
        linkProvider: LinkProvider? = nil,
        pinnedTransport: (any PinnedTransport)? = nil,
        bonding: BondingSettings = BondingSettings(),
        appProxyConfigured: Bool = false,
```

and assign them in the body:

```swift
        self.linkProvider = linkProvider
        self.pinnedTransport = pinnedTransport
        self.bonding = bonding
        self.appProxyConfigured = appProxyConfigured
```

4. Public setter (next to `adjustThreadCount`):

```swift
    /// Settings changed mid-download. Takes effect at the next slot fill.
    func updateBonding(_ settings: BondingSettings) async {
        bonding = settings
        await refreshLinks()
    }
```

5. In `runDownload()`, immediately before `// 6. Mark downloading and start the publish loop.` insert:

```swift
        // 5b. Decide whether this run may use extra network links.
        bondingEligible = bonding.enabled
            && linkProvider != nil
            && pinnedTransport != nil
            && BondingEligibility.isEligible(
                url: download.url,
                supportsRange: download.supportsRange,
                appProxyConfigured: appProxyConfigured,
                systemProxyActive: BondingEligibility.systemProxyActive(for: download.url)
            )
        if bondingEligible, let linkProvider {
            currentLinks = await linkProvider.usableLinks()
            urlSessionLinkID = currentLinks.first(where: \.isDefaultRoute)?.id
            for link in currentLinks { knownLinkNames[link.id] = (link.displayName, link.kind) }
        }
```

6. Quotas and route choice (new private helpers, place under `// MARK: - Dynamic worker management`):

```swift
    private func currentQuotas() -> [LinkQuota] {
        guard bondingEligible else { return [] }
        let active = BondingPolicy.activeLinks(currentLinks, settings: bonding, excluded: excludedLinks)
        return BondingPolicy.quotas(links: active, threadCount: effectiveThreadCount())
    }

    /// Picks the link with the most free slots. URLSession counts against the
    /// default-route link's quota.
    private func pickRoute() -> WorkerRoute {
        let quotas = currentQuotas()
        guard !quotas.isEmpty else { return .urlSession }
        var occupied: [String: Int] = [:]
        let defaultID = quotas.first(where: \.isDefault)?.linkID
        for route in inFlightRoute.values {
            switch route {
            case .urlSession: if let defaultID { occupied[defaultID, default: 0] += 1 }
            case .pinned(let id): occupied[id, default: 0] += 1
            }
        }
        guard let quota = BondingPolicy.nextLink(quotas: quotas, occupied: occupied) else { return .urlSession }
        return quota.isDefault ? .urlSession : .pinned(quota.linkID)
    }

    private func routeLinkID(_ route: WorkerRoute) -> String? {
        switch route {
        case .urlSession: return urlSessionLinkID
        case .pinned(let id): return id
        }
    }
```

7. `spawnWorker(chunkID:)` — pick a route and pass it through:

```swift
    private func spawnWorker(chunkID: UUID) {
        let route = pickRoute()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.processChunkWithRetries(chunkID: chunkID, route: route)
                await self.chunkFinished(chunkID: chunkID, error: nil)
            } catch {
                await self.chunkFinished(chunkID: chunkID, error: error)
                throw error
            }
        }
        inFlight[chunkID] = task
        inFlightRoute[chunkID] = route
    }
```

8. `processChunkWithRetries` — signature `processChunkWithRetries(chunkID: UUID, route: WorkerRoute)`; call `runChunkOnce(chunkID: chunkID, route: route)`; extend the `ChunkError` switch with, as the first case:

```swift
                case .linkRejected, .linkTransport:
                    // Pinned-link problems are the coordinator's to handle at the
                    // link level; don't count attempts against the piece.
                    throw err
```

and change the demotion feed and the attempt cap so pinned workers never feed host demotion:

```swift
            let bytesAfter = chunkBytesWritten(chunkID)
            if route == .urlSession, bytesAfter - bytesBefore < DemotionPolicy.progressCutoff {
                await noteRapidFailure()
            }

            if attempt >= maxAttempts {
                if case .pinned(let id) = route {
                    throw ChunkError.linkRejected(linkID: id, serverRefused: false)
                }
                throw ChunkError.unexpectedStatus(0)
            }
```

9. `runChunkOnce` — signature `runChunkOnce(chunkID: UUID, route: WorkerRoute)`; build the worker with the route:

```swift
        var worker = ChunkWorker(
            chunk: chunk,
            url: download.url,
            etag: download.etag,
            lastModified: download.lastModified,
            writer: writer,
            session: session,
            headers: download.requestHeaders,
            rateLimiter: rateLimiter,
            credential: resolvedCredential,
            report: { [weak self] id, bytes in
                await self?.reportBytes(chunkID: id, bytes: bytes)
            }
        )
        switch route {
        case .pinned(let linkID):
            if let pinnedTransport { worker.pinned = PinnedRoute(linkID: linkID, transport: pinnedTransport) }
        case .urlSession:
            if bondingEligible {
                worker.onLocalAddress = { [weak self] address in
                    Task { await self?.noteURLSessionLocalAddress(address) }
                }
            }
        }
        try await worker.run()
```

10. Per-link byte accounting — replace `reportBytes`:

```swift
    private func reportBytes(chunkID: UUID, bytes: Int) async {
        guard let i = download.chunks.firstIndex(where: { $0.id == chunkID }) else { return }
        download.chunks[i].bytesWritten += Int64(bytes)
        await speedMeter.record(totalBytes: download.bytesDownloaded)
        if bondingEligible, let route = inFlightRoute[chunkID], let linkID = routeLinkID(route) {
            linkBytes[linkID, default: 0] += Int64(bytes)
            let meter: SpeedMeter
            if let existing = linkMeters[linkID] {
                meter = existing
            } else {
                meter = SpeedMeter()
                linkMeters[linkID] = meter
            }
            await meter.record(totalBytes: linkBytes[linkID] ?? 0)
        }
    }

    private func noteURLSessionLocalAddress(_ address: String) {
        let clean = LinkAddresses.normalize(address) ?? address
        if let link = currentLinks.first(where: { $0.addresses.contains(clean) }) {
            urlSessionLinkID = link.id
        }
    }
```

11. Link failure handling — at the very top of `chunkFinished(chunkID:error:)`, replace the first line with:

```swift
        inFlight.removeValue(forKey: chunkID)
        inFlightRoute.removeValue(forKey: chunkID)
        if let ce = error as? ChunkError {
            switch ce {
            case .linkRejected(let linkID, let refused):
                excludeLink(linkID, status: refused ? .rejectedByServer : .down)
                if pendingFatalError == nil { fillIdleSlots() }
                checkJoinCondition()
                return
            case .linkTransport(let linkID, _):
                if linkStrikes.record(linkID) { excludeLink(linkID, status: .down) }
                if pendingFatalError == nil { fillIdleSlots() }
                checkJoinCondition()
                return
            default:
                break
            }
        }
```

and add:

```swift
    private func excludeLink(_ linkID: String, status: LinkStat.Status) {
        guard !excludedLinks.contains(linkID) else { return }
        excludedLinks.insert(linkID)
        linkStatuses[linkID] = status
        Log.engine.warning("Dropping link \(linkID, privacy: .public) for \(self.download.filename, privacy: .public): \(status.rawValue, privacy: .public)")
        // Workers already on that link would only fail too.
        for (id, route) in inFlightRoute where route == .pinned(linkID) {
            inFlight[id]?.cancel()
        }
    }
```

12. Link refresh, called every publish tick — add to `startPublishLoop`'s loop after `await self?.checkStall()`:

```swift
                await self?.refreshLinks()
```

and implement:

```swift
    /// Picks up links appearing or disappearing mid-download. A vanished link's
    /// workers are cancelled now rather than left for the 30 s stall watchdog;
    /// their pieces keep their recorded progress and are re-spawned elsewhere.
    private func refreshLinks() async {
        guard bondingEligible, download.status == .downloading, let linkProvider else { return }
        let links = await linkProvider.usableLinks()
        guard links != currentLinks else { return }
        let usable = Set(links.map(\.id))
        for link in links {
            knownLinkNames[link.id] = (link.displayName, link.kind)
            if linkStatuses[link.id] == .down, !excludedLinks.contains(link.id) { linkStatuses[link.id] = nil }
        }
        for (id, route) in inFlightRoute {
            if case .pinned(let linkID) = route, !usable.contains(linkID) {
                linkStatuses[linkID] = .down
                inFlight[id]?.cancel()
            }
        }
        currentLinks = links
        if let newDefault = links.first(where: \.isDefaultRoute)?.id { urlSessionLinkID = newDefault }
        fillIdleSlots()
    }
```

13. Demotion must judge the default link on its own throughput while bonding — in `noteRapidFailure()` replace `let throughput = await speedMeter.currentSpeed()` with:

```swift
        // With extra links in play, aggregate speed would hide a dead default
        // link behind a healthy phone and teach the host a cap it didn't earn.
        let throughput: Double
        if bondingEligible, !currentQuotas().isEmpty, let id = urlSessionLinkID, let meter = linkMeters[id] {
            throughput = await meter.currentSpeed()
        } else {
            throughput = await speedMeter.currentSpeed()
        }
```

14. Snapshot — in `publishSnapshot()` build links before constructing `snap`, and pass them:

```swift
        var links: [LinkStat] = []
        if bondingEligible {
            var speeds: [String: Double] = [:]
            for (id, meter) in linkMeters { speeds[id] = await meter.currentSpeed() }
            var connections: [String: Int] = [:]
            for route in inFlightRoute.values {
                if let id = routeLinkID(route) { connections[id, default: 0] += 1 }
            }
            let shown = currentLinks.filter { bonding.isLinkEnabled($0.id) }
            links = LinkStatBuilder.build(links: shown, speeds: speeds, bytes: linkBytes,
                                          connections: connections, statuses: linkStatuses,
                                          knownNames: knownLinkNames)
        }
```

and add `links: links` as the last argument of the `DownloadSnapshot(...)` initializer call.

15. `applySplit` and `cancelExcessWorkers` need no change: `applySplit` removes the original's `inFlight` entry — also remove its route: add `inFlightRoute.removeValue(forKey: decision.originalID)` right after `inFlight.removeValue(forKey: decision.originalID)`.

- [ ] **Step 8: Run to verify they pass**

Run: `$TEST -only-testing:MacgetTests/BondingCoordinatorTests -only-testing:MacgetTests/LinkStatBuilderTests`
Expected: 10 tests pass. If `test_linkDisappears_workersReassigned` exceeds 15 s, check that `refreshLinks` runs on the publish tick and that cancelled pinned workers' pieces are re-spawned by the orchestration loop.

- [ ] **Step 9: Run the full suite**

Run: `$TEST`
Expected: all pass — in particular `ConcurrencyRampTests`, `DemotionPolicyTests`, `SlotFillerTests`, `DuplicateCoordinatorTests` (bonding defaults off).

- [ ] **Step 10: Commit**

```bash
git add Macget/Engine/Bonding/LinkStatBuilder.swift Macget/Engine/DownloadCoordinator.swift MacgetTests/LinkStatBuilderTests.swift MacgetTests/BondingCoordinatorTests.swift
git commit -m "feat(bonding): split download workers across network links"
```

---

### Task 10: Engine wiring for HTTP bonding

**Files:**
- Modify: `Macget/Engine/DownloadEngine.swift` (`startCoordinator(for:)`, `updateSettings(_:)`)
- Test: `MacgetTests/BondingEngineWiringTests.swift`

**Interfaces:**
- Consumes: `DownloadCoordinator.init(… linkProvider:pinnedTransport:bonding:appProxyConfigured: …)`, `updateBonding(_:)`, `NetworkLinkMonitor.shared`, `NWPinnedTransport.shared`.
- Produces: `DownloadEngine.init(store:settings:session:linkProvider:pinnedTransport:)` — two new optional params, defaulting to the shared singletons.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Macget

final class BondingEngineWiringTests: XCTestCase {
    func test_engineHandsBondingSettingsAndTransportToCoordinators() async throws {
        let total: Int64 = 32 * 1024 * 1024
        BondingStubURLProtocol.totalBytes = total
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BondingStubURLProtocol.self]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macget-engine-bond-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var settings = AppSettings()
        settings.defaultDestination = dir
        settings.defaultThreadCount = 8
        settings.bonding = BondingSettings(enabled: true)
        let transport = StubPinnedTransport(mode: .serve, totalBytes: total)
        let store = DownloadStore(fileURL: dir.appendingPathComponent("queue.json"))
        let engine = DownloadEngine(
            store: store, settings: settings, session: URLSession(configuration: config),
            linkProvider: StubLinkProvider([BondingCoordinatorTests.wifi, BondingCoordinatorTests.tether]),
            pinnedTransport: transport
        )

        let done = expectation(description: "completed")
        Task {
            for await event in engine.events {
                if case .stateChanged(let d) = event, d.status == .completed { done.fulfill(); return }
            }
        }
        await engine.add(url: URL(string: "https://bond.example.com/big.bin")!)
        await fulfillment(of: [done], timeout: 30)
        XCTAssertGreaterThan(transport.requestCount, 0)
    }
}
```

Before running, check the real signatures: `grep -n "init(fileURL\|init(" Macget/Persistence/DownloadStore.swift` and `grep -n "func add(" Macget/Engine/DownloadEngine.swift`. Adapt the `DownloadStore(...)` and `engine.add(...)` calls to whatever exists (existing tests such as `ListBootstrapTests` show the usual construction).

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/BondingEngineWiringTests`
Expected: build failure — `extra arguments 'linkProvider', 'pinnedTransport'`.

- [ ] **Step 3: Implement**

In `DownloadEngine`:

```swift
    private let linkProvider: LinkProvider
    private let pinnedTransport: any PinnedTransport
```

Init signature becomes:

```swift
    init(
        store: DownloadStore,
        settings: AppSettings,
        session: URLSession? = nil,
        linkProvider: LinkProvider = NetworkLinkMonitor.shared,
        pinnedTransport: any PinnedTransport = NWPinnedTransport.shared
    ) {
        self.linkProvider = linkProvider
        self.pinnedTransport = pinnedTransport
        // …existing body unchanged…
```

In `startCoordinator(for:)`, add to the `DownloadCoordinator(...)` call (after `autoSortByType:`):

```swift
            linkProvider: linkProvider,
            pinnedTransport: pinnedTransport,
            bonding: settings.bonding,
            appProxyConfigured: settings.proxyHost != nil,
```

In `updateSettings(_:)`, after `settings = newSettings`:

```swift
        if newSettings.bonding != oldBonding {
            for coordinator in coordinators.values {
                await coordinator.updateBonding(newSettings.bonding)
            }
        }
```

with `let oldBonding = settings.bonding` captured at the top of the method next to `oldMax`.

- [ ] **Step 4: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/BondingEngineWiringTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Macget/Engine/DownloadEngine.swift MacgetTests/BondingEngineWiringTests.swift
git commit -m "feat(bonding): wire link provider and pinned transport through the engine"
```

---

### Task 11: Torrent bonding via aria2 `--multiple-interface` *(skip if Task 1 said no)*

**Files:**
- Modify: `Macget/Engine/Torrent/Aria2Daemon.swift` (`TorrentEngineOptions`, `arguments`, `client(options:)`, new `isBondingFallbackActive`, `processIdentifier`)
- Modify: `Macget/Engine/DownloadEngine.swift` (`handleLinkSnapshot`, `updateSettings`, `startTorrent`)
- Test: `MacgetTests/TorrentBondingTests.swift`

**Interfaces:**
- Consumes: `BondingPolicy.torrentAddresses(links:settings:)`, `DownloadEngine.lastLinkSnapshot` (Task 4).
- Produces:
  - `TorrentEngineOptions.bondingAddresses: [String]` (launch-only; not in `mutableGlobalOptions`)
  - `Aria2Daemon.isBondingFallbackActive: Bool`, `Aria2Daemon.processIdentifier: Int32?`
  - `DownloadEngine.torrentBondingFallbackActive() async -> Bool`
  - `DownloadEngine.currentTorrentOptions() -> TorrentEngineOptions` (private)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Macget

final class TorrentBondingTests: XCTestCase {
    func test_multipleInterfacePresentOnlyWithAddresses() {
        var options = TorrentEngineOptions()
        XCTAssertFalse(Aria2Daemon.arguments(port: 1, secret: "s", options: options)
            .contains { $0.hasPrefix("--multiple-interface") })

        options.bondingAddresses = ["192.168.0.5", "172.20.10.2"]
        XCTAssertTrue(Aria2Daemon.arguments(port: 1, secret: "s", options: options)
            .contains("--multiple-interface=192.168.0.5,172.20.10.2"))
    }

    func test_bondingAddressesAreLaunchOnly() {
        var options = TorrentEngineOptions()
        options.bondingAddresses = ["192.168.0.5", "172.20.10.2"]
        XCTAssertNil(options.mutableGlobalOptions["multiple-interface"])
    }

    func test_settingsDoNotCarryAddresses() {
        // Addresses come from live links, never from persisted settings.
        var settings = AppSettings()
        settings.bonding = BondingSettings(enabled: true)
        XCTAssertEqual(settings.torrentOptions.bondingAddresses, [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/TorrentBondingTests`
Expected: build failure — `value of type 'TorrentEngineOptions' has no member 'bondingAddresses'`.

- [ ] **Step 3: Implement daemon changes**

In `TorrentEngineOptions` add (after `verifyOnResume`):

```swift
    /// Local IPv4 addresses to spread peer connections across (aria2
    /// `--multiple-interface`). Empty = default route only. Launch-only: changing
    /// it means restarting the daemon, which `DownloadEngine` does.
    var bondingAddresses: [String] = []
```

In `Aria2Daemon.arguments`, just before `for (key, value) in options.mutableGlobalOptions…`:

```swift
        if !options.bondingAddresses.isEmpty {
            // Binds outgoing sockets round-robin across these addresses; macOS's
            // scoped routing then sends each out of the interface that owns it.
            args.append("--multiple-interface=\(options.bondingAddresses.joined(separator: ","))")
        }
```

In `Aria2Daemon` add:

```swift
    /// True when the last launch with `--multiple-interface` failed and the
    /// daemon fell back to the default route. Shown in Settings.
    private(set) var isBondingFallbackActive = false

    /// aria2's pid while it runs — `TorrentLinkAttributor` samples it with `nettop`.
    var processIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }
```

Replace the `let task = Task { try await start(options: options) }` line in `client(options:)` with:

```swift
        let task = Task { () throws -> Aria2RPCClient in
            do {
                let started = try await start(options: options)
                isBondingFallbackActive = false
                return started
            } catch where !options.bondingAddresses.isEmpty {
                // A stale address (link dropped mid-restart) must not take
                // torrents down with it — retry on the default route.
                log.error("aria2c failed with --multiple-interface; retrying without it")
                process?.terminate()
                process = nil
                var plain = options
                plain.bondingAddresses = []
                let started = try await start(options: plain)
                isBondingFallbackActive = true
                return started
            }
        }
```

- [ ] **Step 4: Run to verify the test passes**

Run: `$TEST -only-testing:MacgetTests/TorrentBondingTests -only-testing:MacgetTests/TorrentTests -only-testing:MacgetTests/TorrentUXTests`
Expected: all pass.

- [ ] **Step 5: Restart torrents when the bonded address set changes**

In `DownloadEngine` add:

```swift
    /// Addresses the running (or next) aria2 daemon binds to.
    private var torrentBondingAddresses: [String] = []

    private func currentTorrentOptions() -> TorrentEngineOptions {
        var options = settings.torrentOptions
        options.bondingAddresses = torrentBondingAddresses
        return options
    }

    func torrentBondingFallbackActive() async -> Bool {
        await Aria2Daemon.shared.isBondingFallbackActive
    }

    /// `--multiple-interface` is launch-only, so a changed link set means
    /// restarting aria2. MacGet owns the torrent queue: stop the jobs, stop the
    /// daemon, start the jobs again — aria2's `--continue` and control files
    /// resume them from their pieces on disk.
    private func applyTorrentBonding() async {
        let addresses = BondingPolicy.torrentAddresses(links: lastLinkSnapshot.links, settings: settings.bonding)
        guard addresses != torrentBondingAddresses else { return }
        torrentBondingAddresses = addresses
        let active = Array(torrents.keys)
        guard !active.isEmpty else { return }
        log.info("Network links changed — restarting \(active.count) torrent(s) on \(addresses.isEmpty ? "the default route" : addresses.joined(separator: ","), privacy: .public)")
        for id in active {
            await torrents[id]?.suspendForShutdown()
            torrents[id] = nil
        }
        await Aria2Daemon.shared.shutdown()
        for id in active {
            if let d = downloads[id] { startTorrent(for: d) }
        }
    }
```

Call it at the end of `handleLinkSnapshot(_:)`:

```swift
        await applyTorrentBonding()
```

and in `updateSettings(_:)` right after the coordinator `updateBonding` loop:

```swift
        if newSettings.bonding != oldBonding { await applyTorrentBonding() }
```

In `startTorrent(for:)` change `options: settings.torrentOptions,` to `options: currentTorrentOptions(),`.

- [ ] **Step 6: Run the full suite**

Run: `$TEST`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Macget/Engine/Torrent/Aria2Daemon.swift Macget/Engine/DownloadEngine.swift MacgetTests/TorrentBondingTests.swift
git commit -m "feat(bonding): spread torrent peer connections across links via aria2"
```

---

### Task 12: Torrent per-link attribution from `nettop` *(skip if Task 1 said no)*

**Files:**
- Create: `Macget/Engine/Torrent/NettopParser.swift`
- Create: `Macget/Engine/Torrent/TorrentLinkAttributor.swift`
- Modify: `Macget/Engine/Torrent/TorrentJob.swift` (main snapshot in `poll()`)
- Test: `MacgetTests/TorrentLinkAttributionTests.swift`

**Interfaces:**
- Consumes: `LinkStat`, `NetworkLink`, `Aria2Daemon.processIdentifier`, `NetworkLinkMonitor.shared.usableLinks()`, `TorrentEngineOptions.bondingAddresses`.
- Produces:
  - `struct NettopSocketSample: Equatable { let key: String; let interface: String; let bytesIn: Int64 }`
  - `enum NettopParser { static func parse(_ csv: String) -> [NettopSocketSample]; static func delta(previous:current:) -> [String: Int64]; static func socketCounts(_:) -> [String: Int] }`
  - `actor TorrentLinkAttributor { static let shared; init(sampler:pidProvider:); func linkStats(for:speed:links:now:) -> [LinkStat]; static func apportion(...) -> [LinkStat] }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Macget

final class TorrentLinkAttributionTests: XCTestCase {
    private let sample1 = """
    ,interface,bytes_in,
    aria2c.4242,,0,
    tcp4 192.168.0.5:50001<->1.2.3.4:6881,en0,1000,
    tcp4 172.20.10.2:50002<->5.6.7.8:6881,en7,2000,
    udp4 *:*<->*:*,,,
    """
    private let sample2 = """
    ,interface,bytes_in,
    aria2c.4242,,0,
    tcp4 192.168.0.5:50001<->1.2.3.4:6881,en0,1500,
    tcp4 172.20.10.2:50002<->5.6.7.8:6881,en7,4000,
    tcp4 172.20.10.2:50003<->9.9.9.9:6881,en7,300,
    """

    func test_parseSkipsHeaderProcessAndInterfacelessRows() {
        let rows = NettopParser.parse(sample1)
        XCTAssertEqual(rows.map(\.interface), ["en0", "en7"])
        XCTAssertEqual(rows.map(\.bytesIn), [1000, 2000])
    }

    func test_deltaPerInterfaceCountsNewSockets() {
        let d = NettopParser.delta(previous: NettopParser.parse(sample1), current: NettopParser.parse(sample2))
        XCTAssertEqual(d, ["en0": 500, "en7": 2300])
    }

    func test_socketCounts() {
        XCTAssertEqual(NettopParser.socketCounts(NettopParser.parse(sample2)), ["en0": 1, "en7": 2])
    }

    private let wifi = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: [], isDefaultRoute: true)
    private let tether = NetworkLink(id: "en7", displayName: "iPhone USB", kind: .tethered, addresses: [], isDefaultRoute: false)

    func test_singleTorrentIsExactAndNotEstimate() {
        let id = UUID()
        let stats = TorrentLinkAttributor.apportion(id: id, speeds: [id: 900], linkRates: ["en0": 300, "en7": 600],
                                                    links: [wifi, tether], available: true, cumulative: [:], sockets: ["en0": 2, "en7": 3])
        XCTAssertEqual(stats.map(\.speedBytesPerSec), [300, 600])
        XCTAssertEqual(stats.map(\.isEstimate), [false, false])
        XCTAssertEqual(stats.map(\.activeConnections), [2, 3])
    }

    func test_twoTorrentsSplitProportionallyAndAreEstimates() {
        let a = UUID(), b = UUID()
        let stats = TorrentLinkAttributor.apportion(id: a, speeds: [a: 300, b: 900], linkRates: ["en0": 400, "en7": 800],
                                                    links: [wifi, tether], available: true, cumulative: [:], sockets: [:])
        XCTAssertEqual(stats.map(\.speedBytesPerSec), [100, 200])
        XCTAssertEqual(stats.map(\.isEstimate), [true, true])
    }

    func test_unavailableYieldsNothing() {
        let id = UUID()
        XCTAssertEqual(TorrentLinkAttributor.apportion(id: id, speeds: [id: 1], linkRates: ["en0": 1, "en7": 1],
                                                       links: [wifi, tether], available: false, cumulative: [:], sockets: [:]), [])
    }

    func test_actorIgnoresFirstSampleAndAttributesSecond() async {
        let outputs = Outputs([sample1, sample2])
        let attributor = TorrentLinkAttributor(sampler: { _ in outputs.next() }, pidProvider: { 4242 }, autoSample: false)
        let id = UUID()
        await attributor.sampleNow()
        let first = await attributor.linkStats(for: id, speed: 1000, links: [wifi, tether])
        XCTAssertEqual(first, [], "first nettop sample has no baseline")
        await attributor.sampleNow()
        let second = await attributor.linkStats(for: id, speed: 1000, links: [wifi, tether])
        XCTAssertEqual(second.count, 2)
        XCTAssertGreaterThan(second[1].speedBytesPerSec, second[0].speedBytesPerSec)
    }

    func test_actorMarksUnavailableWhenNettopFails() async {
        let attributor = TorrentLinkAttributor(sampler: { _ in nil }, pidProvider: { 4242 }, autoSample: false)
        await attributor.sampleNow()
        let available = await attributor.isAvailable
        XCTAssertFalse(available)
    }
}

private final class Outputs: @unchecked Sendable {
    private var queue: [String]
    private let lock = NSLock()
    init(_ q: [String]) { queue = q }
    func next() -> String? { lock.lock(); defer { lock.unlock() }; return queue.isEmpty ? nil : queue.removeFirst() }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/TorrentLinkAttributionTests`
Expected: build failure — `cannot find 'NettopParser' in scope`.

- [ ] **Step 3: Implement `NettopParser`**

`Macget/Engine/Torrent/NettopParser.swift`:

```swift
import Foundation

struct NettopSocketSample: Equatable {
    /// The socket description, e.g. "tcp4 1.2.3.4:5<->6.7.8.9:10" — unique per connection.
    let key: String
    let interface: String
    /// Cumulative bytes received on this socket since it opened.
    let bytesIn: Int64
}

/// Parses `nettop -L 1 -x -n -p <pid> -J interface,bytes_in` CSV output.
///
/// aria2 reports speed per torrent but never which local interface the bytes
/// arrived on; macOS's per-socket statistics (what `nettop` shows) do, and work
/// without root for our own child process.
enum NettopParser {
    static func parse(_ csv: String) -> [NettopSocketSample] {
        csv.split(whereSeparator: \.isNewline).compactMap { line in
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            // Header and per-process rows have an empty interface column.
            guard cols.count >= 3, !cols[0].isEmpty, !cols[1].isEmpty, let bytes = Int64(cols[2]) else { return nil }
            return NettopSocketSample(key: cols[0], interface: cols[1], bytesIn: bytes)
        }
    }

    /// Bytes received per interface between two samples. A socket new in
    /// `current` contributes everything it has received so far.
    static func delta(previous: [NettopSocketSample], current: [NettopSocketSample]) -> [String: Int64] {
        let before = Dictionary(previous.map { ($0.key, $0.bytesIn) }, uniquingKeysWith: max)
        var out: [String: Int64] = [:]
        for sample in current {
            let d = sample.bytesIn - (before[sample.key] ?? 0)
            if d > 0 { out[sample.interface, default: 0] += d }
        }
        return out
    }

    static func socketCounts(_ samples: [NettopSocketSample]) -> [String: Int] {
        samples.reduce(into: [:]) { $0[$1.interface, default: 0] += 1 }
    }
}
```

- [ ] **Step 4: Implement `TorrentLinkAttributor`**

`Macget/Engine/Torrent/TorrentLinkAttributor.swift`:

```swift
import Foundation

/// Estimates how much of each torrent arrives over each network link.
///
/// One aria2 process serves every torrent, so per-interface bytes are only known
/// for the process as a whole. They are split across active torrents in
/// proportion to aria2's own per-torrent speeds: exact with one torrent running,
/// an estimate (flagged, shown with "≈") with several.
actor TorrentLinkAttributor {
    static let shared = TorrentLinkAttributor()

    /// Speeds older than this are treated as stopped torrents.
    static let speedFreshness: TimeInterval = 3

    private let sampler: @Sendable (Int32) async -> String?
    private let pidProvider: @Sendable () async -> Int32?

    private var previous: [NettopSocketSample]?
    private var previousAt: Date?
    private var linkRates: [String: Double] = [:]
    private var sockets: [String: Int] = [:]
    private var speeds: [UUID: (speed: Double, at: Date)] = [:]
    private var cumulative: [UUID: [String: Int64]] = [:]
    private(set) var isAvailable = true
    private var samplingTask: Task<Void, Never>?
    private var lastRequestAt = Date.distantPast
    /// Off in tests, which drive `sampleNow()` themselves so a background loop
    /// can't consume their canned `nettop` output.
    private let autoSample: Bool

    init(
        sampler: @escaping @Sendable (Int32) async -> String? = TorrentLinkAttributor.runNettop,
        pidProvider: @escaping @Sendable () async -> Int32? = { await Aria2Daemon.shared.processIdentifier },
        autoSample: Bool = true
    ) {
        self.sampler = sampler
        self.pidProvider = pidProvider
        self.autoSample = autoSample
    }

    /// Called from each torrent's poll. Starts sampling on first use and lets it
    /// lapse when nobody has asked for a few seconds.
    func linkStats(for id: UUID, speed: Double, links: [NetworkLink], now: Date = Date()) -> [LinkStat] {
        speeds[id] = (speed, now)
        lastRequestAt = now
        ensureSampling()
        return Self.apportion(id: id, speeds: freshSpeeds(now), linkRates: linkRates, links: links,
                              available: isAvailable, cumulative: cumulative[id] ?? [:], sockets: sockets)
    }

    static func apportion(
        id: UUID,
        speeds: [UUID: Double],
        linkRates: [String: Double],
        links: [NetworkLink],
        available: Bool,
        cumulative: [String: Int64],
        sockets: [String: Int]
    ) -> [LinkStat] {
        guard available, links.count >= 2, !linkRates.isEmpty else { return [] }
        let total = speeds.values.reduce(0, +)
        guard total > 0, let mine = speeds[id] else { return [] }
        let share = mine / total
        let isEstimate = speeds.values.filter { $0 > 0 }.count > 1
        return links.map { link in
            LinkStat(
                linkID: link.id, displayName: link.displayName, kind: link.kind,
                speedBytesPerSec: (linkRates[link.id] ?? 0) * share,
                bytesThisSession: cumulative[link.id] ?? 0,
                activeConnections: isEstimate ? 0 : (sockets[link.id] ?? 0),
                status: .active,
                isEstimate: isEstimate
            )
        }
    }

    /// One sample. Internal so tests can drive it without the timer.
    func sampleNow() async {
        guard let pid = await pidProvider() else {
            previous = nil
            linkRates = [:]
            return
        }
        guard let csv = await sampler(pid) else {
            isAvailable = false
            return
        }
        let current = NettopParser.parse(csv)
        let now = Date()
        if let previous, let previousAt {
            let dt = max(now.timeIntervalSince(previousAt), 0.1)
            let delta = NettopParser.delta(previous: previous, current: current)
            linkRates = delta.mapValues { Double($0) / dt }
            let fresh = freshSpeeds(now)
            let total = fresh.values.reduce(0, +)
            if total > 0 {
                for (id, speed) in fresh {
                    let share = speed / total
                    for (link, bytes) in delta {
                        cumulative[id, default: [:]][link, default: 0] += Int64(Double(bytes) * share)
                    }
                }
            }
        }
        previous = current
        previousAt = now
        sockets = NettopParser.socketCounts(current)
        isAvailable = true
    }

    private func freshSpeeds(_ now: Date) -> [UUID: Double] {
        speeds.filter { now.timeIntervalSince($0.value.at) <= Self.speedFreshness }.mapValues(\.speed)
    }

    private func ensureSampling() {
        guard autoSample, samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.isIdle() { await self.stopSampling(); return }
                await self.sampleNow()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func isIdle() -> Bool { Date().timeIntervalSince(lastRequestAt) > 5 }

    private func stopSampling() {
        samplingTask = nil
        previous = nil
        linkRates = [:]
    }

    /// `nettop` one-shot sample of a single process's sockets.
    static let runNettop: @Sendable (Int32) async -> String? = { pid in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
                process.arguments = ["-L", "1", "-x", "-n", "-p", String(pid), "-J", "interface,bytes_in"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
```

- [ ] **Step 5: Feed it from `TorrentJob`**

In `TorrentJob.poll()`, just before the main `await onSnapshot(DownloadSnapshot(… isSeeding: seeding))` call, add:

```swift
        var links: [LinkStat] = []
        if !options.bondingAddresses.isEmpty, !seeding {
            let usable = await NetworkLinkMonitor.shared.usableLinks()
            links = await TorrentLinkAttributor.shared.linkStats(
                for: download.id, speed: Double(status.downloadSpeed), links: usable)
        }
```

and add `links: links` as the final argument of that `DownloadSnapshot(...)` call. Confirm `TorrentJob` stores its options as `options` (`grep -n "options" Macget/Engine/Torrent/TorrentJob.swift`); use the actual property name.

- [ ] **Step 6: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/TorrentLinkAttributionTests -only-testing:MacgetTests/TorrentTests`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Macget/Engine/Torrent/NettopParser.swift Macget/Engine/Torrent/TorrentLinkAttributor.swift Macget/Engine/Torrent/TorrentJob.swift MacgetTests/TorrentLinkAttributionTests.swift
git commit -m "feat(bonding): attribute torrent traffic to network links via nettop"
```

---

### Task 13: Row breakdown — `DownloadRowItem.links`, list aggregation, `LinkBreakdownView`

**Files:**
- Create: `Macget/Views/Components/LinkBreakdownView.swift`
- Modify: `Macget/ViewModels/DownloadListViewModel.swift` (`DownloadRowItem`, `rebuildRows`, new `linkTotals`)
- Modify: `Macget/Views/Components/DownloadRowCard.swift` (`activeLine`)
- Test: `MacgetTests/LinkBreakdownTextTests.swift`

**Interfaces:**
- Consumes: `LinkStat`, `LinkStat.aggregate`, `DownloadSnapshot.links`, `ByteFormatter.speedString`.
- Produces:
  - `DownloadRowItem.links: [LinkStat]` (`var … = []`, last property)
  - `DownloadListViewModel.linkTotals: [LinkStat]` (`private(set)`)
  - `enum LinkBreakdownText { static func caption(_:) -> String; static func accessibility(_:) -> String; static func statusText(_:) -> String }`
  - `enum LinkPalette { static func color(for: NetworkLink.Kind) -> Color }`
  - `struct LinkBreakdownView: View { let links: [LinkStat] }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Macget

final class LinkBreakdownTextTests: XCTestCase {
    private func stat(_ id: String, _ name: String, _ speed: Double, estimate: Bool = false, status: LinkStat.Status = .active) -> LinkStat {
        LinkStat(linkID: id, displayName: name, kind: .wifi, speedBytesPerSec: speed, bytesThisSession: 0,
                 activeConnections: 1, status: status, isEstimate: estimate)
    }

    func test_captionListsEachMovingLink() {
        let caption = LinkBreakdownText.caption([stat("en0", "Wi-Fi", 1_200_000), stat("en7", "iPhone USB", 3_400_000)])
        XCTAssertEqual(caption, "Wi-Fi \(ByteFormatter.speedString(1_200_000)) · iPhone USB \(ByteFormatter.speedString(3_400_000))")
    }

    func test_captionPrefixesEstimate() {
        XCTAssertTrue(LinkBreakdownText.caption([stat("en0", "Wi-Fi", 1, estimate: true), stat("en7", "iPhone USB", 1)]).hasPrefix("≈ "))
    }

    func test_captionOmitsStoppedLinks() {
        let caption = LinkBreakdownText.caption([stat("en0", "Wi-Fi", 1000), stat("en7", "iPhone USB", 0, status: .rejectedByServer)])
        XCTAssertFalse(caption.contains("iPhone"))
    }

    func test_accessibilityIncludesPercent() {
        let a11y = LinkBreakdownText.accessibility([stat("en0", "Wi-Fi", 250), stat("en7", "iPhone USB", 750)])
        XCTAssertTrue(a11y.contains("Wi-Fi"))
        XCTAssertTrue(a11y.contains("25 percent"))
        XCTAssertTrue(a11y.contains("75 percent"))
    }

    func test_statusText() {
        XCTAssertEqual(LinkBreakdownText.statusText(.active), "Active")
        XCTAssertEqual(LinkBreakdownText.statusText(.rejectedByServer), "Not accepted by server")
        XCTAssertEqual(LinkBreakdownText.statusText(.down), "Link down")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/LinkBreakdownTextTests`
Expected: build failure — `cannot find 'LinkBreakdownText' in scope`.

- [ ] **Step 3: Implement the view and text helpers**

`Macget/Views/Components/LinkBreakdownView.swift`:

```swift
import SwiftUI

/// Stable colors per link kind, so "green" always means the phone.
enum LinkPalette {
    static func color(for kind: NetworkLink.Kind) -> Color {
        switch kind {
        case .wifi: return .blue
        case .tethered: return .green
        case .wiredEthernet: return .orange
        case .other: return .gray
        }
    }
}

enum LinkBreakdownText {
    /// "Wi-Fi 1.2 MB/s · iPhone USB 3.4 MB/s", prefixed "≈ " when apportioned.
    static func caption(_ links: [LinkStat]) -> String {
        let moving = links.filter { $0.speedBytesPerSec > 0 }
        let body = moving.map { "\($0.displayName) \(ByteFormatter.speedString($0.speedBytesPerSec))" }
            .joined(separator: " · ")
        return links.contains(where: \.isEstimate) ? "≈ " + body : body
    }

    static func accessibility(_ links: [LinkStat]) -> String {
        let total = links.reduce(0) { $0 + $1.speedBytesPerSec }
        return links.filter { $0.speedBytesPerSec > 0 }.map { link in
            let percent = total > 0 ? Int((link.speedBytesPerSec / total * 100).rounded()) : 0
            return "\(link.displayName), \(ByteFormatter.speedString(link.speedBytesPerSec)), \(percent) percent of current speed"
        }.joined(separator: "; ")
    }

    static func statusText(_ status: LinkStat.Status) -> String {
        switch status {
        case .active: return "Active"
        case .rejectedByServer: return "Not accepted by server"
        case .down: return "Link down"
        }
    }
}

/// A thin stacked bar of each link's share of current speed, with a caption.
struct LinkBreakdownView: View {
    let links: [LinkStat]
    var showsCaption = true

    private var moving: [LinkStat] { links.filter { $0.speedBytesPerSec > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                let total = max(moving.reduce(0) { $0 + $1.speedBytesPerSec }, 1)
                HStack(spacing: 1) {
                    ForEach(moving) { link in
                        Rectangle()
                            .fill(LinkPalette.color(for: link.kind))
                            .frame(width: max(2, geo.size.width * link.speedBytesPerSec / total))
                    }
                }
            }
            .frame(height: 3)
            .clipShape(Capsule())

            if showsCaption {
                Text(LinkBreakdownText.caption(links))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LinkBreakdownText.accessibility(links))
    }
}
```

- [ ] **Step 4: Plumb links into rows and the list total**

In `DownloadRowItem` add as the **last** stored property:

```swift
    /// Per-link speed breakdown when several network links carry this download.
    var links: [LinkStat] = []
```

In `rebuildRows()`, add `links: snap?.links ?? []` as the last argument of the `DownloadRowItem(...)` call (after `torrentFiles:`), and after the `totalSpeed = …` line:

```swift
        linkTotals = LinkStat.aggregate(items.filter { $0.status == .downloading }.map(\.links))
```

Add the property next to `totalSpeed`:

```swift
    /// Per-link speed summed across every active download, for the toolbar strip
    /// and menu bar. Empty unless two or more links are carrying traffic.
    private(set) var linkTotals: [LinkStat] = []
```

In `DownloadRowCard.activeLine`, wrap the existing `HStack(spacing: 8) { … }` in:

```swift
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // …existing contents unchanged…
            }
            if row.links.count >= 2 {
                LinkBreakdownView(links: row.links)
            }
        }
```

- [ ] **Step 5: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/LinkBreakdownTextTests -only-testing:MacgetTests/StatusBarModelTests -only-testing:MacgetTests/TorrentUXTests -only-testing:MacgetTests/ListBootstrapTests`
Expected: all pass (existing `DownloadRowItem(...)` constructions still compile because `links` has a default).

- [ ] **Step 6: Commit**

```bash
git add Macget/Views/Components/LinkBreakdownView.swift Macget/ViewModels/DownloadListViewModel.swift Macget/Views/Components/DownloadRowCard.swift MacgetTests/LinkBreakdownTextTests.swift
git commit -m "feat(bonding): show per-link speed breakdown in download rows"
```

---

### Task 14: Inspector "Network links" section with stacked chart

**Files:**
- Create: `Macget/Views/Inspector/LinkSpeedChartView.swift`
- Modify: `Macget/ViewModels/InspectorModel.swift` (`linkSeries`, `setTarget`, `tick`)
- Modify: `Macget/Views/Inspector/DownloadInspectorView.swift` (`selected(_:)`)
- Test: `MacgetTests/InspectorLinkSeriesTests.swift`

**Interfaces:**
- Consumes: `DownloadRowItem.links`, `SpeedSeries`, `LinkPalette`, `LinkBreakdownText.statusText`.
- Produces: `InspectorModel.linkSeries: [String: SpeedSeries]`, `InspectorModel.linkOrder: [LinkStat]`, `static func InspectorModel.appendLinkSamples(_:to:) -> [String: SpeedSeries]`, `struct LinkSpeedChartView: View { let series: [String: SpeedSeries]; let links: [LinkStat] }`.

- [ ] **Step 1: Write the failing test** (the sampling rule is pure and static)

```swift
import XCTest
@testable import Macget

final class InspectorLinkSeriesTests: XCTestCase {
    private func stat(_ id: String, _ speed: Double) -> LinkStat {
        LinkStat(linkID: id, displayName: id, kind: .wifi, speedBytesPerSec: speed, bytesThisSession: 0,
                 activeConnections: 0, status: .active, isEstimate: false)
    }

    func test_appendsOneSamplePerLink() {
        var series: [String: SpeedSeries] = [:]
        series = InspectorModel.appendLinkSamples([stat("en0", 10), stat("en7", 30)], to: series)
        series = InspectorModel.appendLinkSamples([stat("en0", 20), stat("en7", 40)], to: series)
        XCTAssertEqual(series["en0"]?.samples, [10, 20])
        XCTAssertEqual(series["en7"]?.samples, [30, 40])
    }

    func test_linkMissingFromTickGetsZeroSoSeriesStayAligned() {
        var series = InspectorModel.appendLinkSamples([stat("en0", 10), stat("en7", 30)], to: [:])
        series = InspectorModel.appendLinkSamples([stat("en0", 20)], to: series)
        XCTAssertEqual(series["en7"]?.samples, [30, 0])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/InspectorLinkSeriesTests`
Expected: build failure — `type 'InspectorModel' has no member 'appendLinkSamples'`.

- [ ] **Step 3: Implement the model changes**

In `InspectorModel` add:

```swift
    /// Per-link throughput for the selected download, keyed by link ID, sampled
    /// on the same tick as `selectedSeries`.
    private(set) var linkSeries: [String: SpeedSeries] = [:]

    /// The selected download's current links, in display order.
    var linkOrder: [LinkStat] { targetRow?.links ?? [] }

    /// Every known series gets a sample each tick (zero when the link carried
    /// nothing), so stacked areas stay aligned on one time base.
    static func appendLinkSamples(_ links: [LinkStat], to series: [String: SpeedSeries]) -> [String: SpeedSeries] {
        var out = series
        let now = Date()
        let speeds = Dictionary(links.map { ($0.linkID, $0.speedBytesPerSec) }, uniquingKeysWith: +)
        for id in Set(out.keys).union(speeds.keys) {
            var s = out[id] ?? SpeedSeries()
            s.append(speeds[id] ?? 0, at: now)
            out[id] = s
        }
        return out
    }
```

In `setTarget(_:)`, after `workerSeries.reset()`: `linkSeries = [:]`.
In `tick()`, after `selectedSeries.append(...)`:

```swift
        if let links = targetRow?.links, !links.isEmpty {
            linkSeries = Self.appendLinkSamples(links, to: linkSeries)
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/InspectorLinkSeriesTests`
Expected: 2 tests pass.

- [ ] **Step 5: Implement the chart and section**

`Macget/Views/Inspector/LinkSpeedChartView.swift`:

```swift
import SwiftUI
import Charts

/// Stacked throughput by network link: the height is total speed, each band is
/// one link's contribution.
struct LinkSpeedChartView: View {
    let series: [String: SpeedSeries]
    let links: [LinkStat]
    var height: CGFloat = 72

    private struct Point: Identifiable {
        let index: Int
        let linkID: String
        let name: String
        let value: Double
        var id: String { "\(linkID)-\(index)" }
    }

    private var points: [Point] {
        links.flatMap { link -> [Point] in
            (series[link.linkID]?.samples ?? []).enumerated().map {
                Point(index: $0.offset, linkID: link.linkID, name: link.displayName, value: $0.element)
            }
        }
    }

    var body: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Sample", point.index),
                y: .value("Speed", point.value),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Link", point.name))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(
            domain: links.map(\.displayName),
            range: links.map { LinkPalette.color(for: $0.kind) }
        )
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(ByteFormatter.speedString(v)) }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: height)
        .accessibilityLabel(LinkBreakdownText.accessibility(links))
    }
}
```

In `DownloadInspectorView.selected(_:)`, insert after the `section("Transfer") { … }` block:

```swift
        if row.links.count >= 2 {
            section("Network links", subtitle: row.links.contains(where: \.isEstimate) ? "estimated" : "\(row.links.count)") {
                VStack(alignment: .leading, spacing: 8) {
                    LinkSpeedChartView(series: model.linkSeries, links: row.links)
                    ForEach(row.links) { link in
                        HStack(spacing: 6) {
                            Circle().fill(LinkPalette.color(for: link.kind)).frame(width: 7, height: 7)
                            Text(link.displayName).lineLimit(1)
                            Spacer()
                            if link.status == .active {
                                Text(ByteFormatter.speedString(link.speedBytesPerSec)).monospacedDigit()
                            } else {
                                Text(LinkBreakdownText.statusText(link.status)).foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: link.bytesThisSession, countStyle: .file))
                            Text("·")
                            Text(row.isTorrent && link.activeConnections == 0 ? "— connections" : "\(link.activeConnections) connections")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 13)
                    }
                }
            }
        }
```

- [ ] **Step 6: Build and run the full suite**

Run: `$TEST`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Macget/Views/Inspector/LinkSpeedChartView.swift Macget/ViewModels/InspectorModel.swift Macget/Views/Inspector/DownloadInspectorView.swift MacgetTests/InspectorLinkSeriesTests.swift
git commit -m "feat(bonding): add per-link section and stacked chart to the inspector"
```

---

### Task 15: Global strip — toolbar and menu bar

**Files:**
- Create: `Macget/Views/Components/LinkStripView.swift`
- Modify: `Macget/Views/ContentView.swift` (toolbar)
- Modify: `Macget/App/StatusBarModel.swift`, `Macget/App/StatusBarController.swift`
- Modify: wherever `StatusBarModel(rows:totalSpeed:)` is constructed (`grep -rn "StatusBarModel(" Macget`)
- Test: `MacgetTests/StatusBarModelTests.swift` (add cases)

**Interfaces:**
- Consumes: `DownloadListViewModel.linkTotals`, `LinkBreakdownText.caption`, `LinkPalette`.
- Produces: `StatusBarModel.linkSummaryText: String?`, `StatusBarModel.init(rows:totalSpeed:linkTotals:)` (new param defaults to `[]`), `struct LinkStripView: View { let totals: [LinkStat]; let totalSpeed: Double }`.

- [ ] **Step 1: Write the failing test** — append to `MacgetTests/StatusBarModelTests.swift` inside the existing class:

```swift
    func test_linkSummaryAbsentWithoutBonding() {
        let model = StatusBarModel(rows: [], totalSpeed: 0)
        XCTAssertNil(model.linkSummaryText)
    }

    func test_linkSummaryListsLinksAndTotal() {
        let totals = [
            LinkStat(linkID: "en0", displayName: "Wi-Fi", kind: .wifi, speedBytesPerSec: 1_000_000, bytesThisSession: 0,
                     activeConnections: 4, status: .active, isEstimate: false),
            LinkStat(linkID: "en7", displayName: "iPhone USB", kind: .tethered, speedBytesPerSec: 3_000_000, bytesThisSession: 0,
                     activeConnections: 4, status: .active, isEstimate: false),
        ]
        let model = StatusBarModel(rows: [], totalSpeed: 4_000_000, linkTotals: totals)
        XCTAssertEqual(model.linkSummaryText,
                       LinkBreakdownText.caption(totals) + " · Total " + ByteFormatter.speedString(4_000_000))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/StatusBarModelTests`
Expected: build failure — `extra argument 'linkTotals'`.

- [ ] **Step 3: Implement**

In `StatusBarModel` add the property and extend the initializer:

```swift
    /// "Wi-Fi 1.0 MB/s · iPhone USB 3.0 MB/s · Total 4.0 MB/s" while bonding is
    /// carrying traffic; nil otherwise.
    let linkSummaryText: String?
```

Change `init(rows: [DownloadRowItem], totalSpeed: Double)` to `init(rows: [DownloadRowItem], totalSpeed: Double, linkTotals: [LinkStat] = [])` and add at the end of the body:

```swift
        linkSummaryText = linkTotals.count >= 2
            ? LinkBreakdownText.caption(linkTotals) + " · Total " + ByteFormatter.speedString(totalSpeed)
            : nil
```

Update each `StatusBarModel(rows:totalSpeed:)` construction site in the app to pass `linkTotals: listVM.linkTotals` (or the local name of the list view model there).

In `StatusBarController.menuWillOpen(_:)`, right after `menu.addItem(header)`:

```swift
        if let summary = model.linkSummaryText {
            let item = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
```

`Macget/Views/Components/LinkStripView.swift`:

```swift
import SwiftUI

/// Toolbar strip: combined speed per link across all downloads.
struct LinkStripView: View {
    let totals: [LinkStat]
    let totalSpeed: Double

    var body: some View {
        HStack(spacing: 10) {
            ForEach(totals.filter { $0.speedBytesPerSec > 0 }) { link in
                HStack(spacing: 4) {
                    Circle().fill(LinkPalette.color(for: link.kind)).frame(width: 6, height: 6)
                    Text("\(link.displayName) \(ByteFormatter.speedString(link.speedBytesPerSec))")
                }
            }
            Divider().frame(height: 12)
            Text("Total \(ByteFormatter.speedString(totalSpeed))").fontWeight(.medium)
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LinkBreakdownText.accessibility(totals) + "; total \(ByteFormatter.speedString(totalSpeed))")
        .help("Download speed per network link across all active downloads")
    }
}
```

In `ContentView`'s `.toolbar { … }`, add a new item group before the first `ToolbarItemGroup`:

```swift
                    if listVM.linkTotals.count >= 2 {
                        ToolbarItem(placement: .principal) {
                            LinkStripView(totals: listVM.linkTotals, totalSpeed: listVM.totalSpeed)
                        }
                    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/StatusBarModelTests`
Expected: all pass, including the two new tests.

- [ ] **Step 5: Commit**

```bash
git add Macget/Views/Components/LinkStripView.swift Macget/Views/ContentView.swift Macget/App/StatusBarModel.swift Macget/App/StatusBarController.swift MacgetTests/StatusBarModelTests.swift
git add -u Macget
git commit -m "feat(bonding): add global per-link speed strip to toolbar and menu bar"
```

---

### Task 16: Settings ▸ Network ▸ Combine connections

**Files:**
- Modify: `Macget/Views/SettingsView.swift` (`networkTab`, new `@State`)
- Test: `MacgetTests/BondingSettingsTests.swift` (add the binding-rule test)

**Interfaces:**
- Consumes: `BondingSettings`, `NetworkLinkMonitor.shared.updates()`, `DownloadEngine.torrentBondingFallbackActive()` (Task 11; omit the notice if Task 11 was skipped), `LinkPalette`.
- Produces: `BondingSettings.setLink(_:enabled:)` (mutating helper used by the toggle).

- [ ] **Step 1: Write the failing test** — append to `BondingSettingsTests`:

```swift
    func test_setLinkTogglesDisabledSet() {
        var b = BondingSettings(enabled: true)
        b.setLink("en7", enabled: false)
        XCTAssertEqual(b.disabledLinkIDs, ["en7"])
        b.setLink("en7", enabled: true)
        XCTAssertTrue(b.disabledLinkIDs.isEmpty)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `$TEST -only-testing:MacgetTests/BondingSettingsTests`
Expected: build failure — `value of type 'BondingSettings' has no member 'setLink'`.

- [ ] **Step 3: Implement**

In `BondingSettings`:

```swift
    mutating func setLink(_ id: String, enabled: Bool) {
        if enabled { disabledLinkIDs.remove(id) } else { disabledLinkIDs.insert(id) }
    }
```

In `SettingsView`, add state next to `learnedHostCount`:

```swift
    @State private var usableLinks: [NetworkLink] = []
    @State private var torrentBondingFallback = false
```

Insert as the **first** `Section` in `networkTab`'s `Form`:

```swift
            Section {
                Toggle("Combine internet connections", isOn: $vm.settings.bonding.enabled)
                if vm.settings.bonding.enabled {
                    if usableLinks.isEmpty {
                        Text("Looking for connections…").foregroundStyle(.secondary)
                    }
                    ForEach(usableLinks) { link in
                        Toggle(isOn: Binding(
                            get: { vm.settings.bonding.isLinkEnabled(link.id) },
                            set: { vm.settings.bonding.setLink(link.id, enabled: $0) }
                        )) {
                            HStack(spacing: 6) {
                                Circle().fill(LinkPalette.color(for: link.kind)).frame(width: 8, height: 8)
                                Text(link.displayName)
                                Text(link.isDefaultRoute ? "Connected · default route" : "Connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if torrentBondingFallback {
                        Label("Torrents are using only the default connection — the torrent engine couldn't bind to every link.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Combine connections")
            } footer: {
                Text("Uses every enabled connection at once for multi-connection downloads and torrents — for example Wi-Fi plus a USB-tethered phone. Data from a tethered phone counts against your mobile plan. Downloads through a proxy, and servers that don't support resuming, use only the default connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

Extend the existing `.task { … }` on `networkTab` (keep the `learnedHostCount` line):

```swift
        .task {
            learnedHostCount = await HostCapStore.shared.learnedHostCount()
            await NetworkLinkMonitor.shared.start()
            for await snapshot in await NetworkLinkMonitor.shared.updates() {
                usableLinks = snapshot.links
                torrentBondingFallback = await Aria2Daemon.shared.isBondingFallbackActive
            }
        }
```

(Reading `Aria2Daemon.shared` directly matches how this view already reads `HostCapStore.shared`. If Task 11 was skipped, drop the `torrentBondingFallback` state, line and notice.)

- [ ] **Step 4: Run to verify it passes**

Run: `$TEST -only-testing:MacgetTests/BondingSettingsTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Macget/Engine/Bonding/BondingSettings.swift Macget/Views/SettingsView.swift MacgetTests/BondingSettingsTests.swift
git commit -m "feat(bonding): add Combine connections settings"
```

---

### Task 17: Docs and hardware verification

**Files:**
- Modify: `CLAUDE.md` (new `### Connection bonding (Macget/Engine/Bonding/)` subsection after the BitTorrent section)
- Modify: `docs/architecture.md` (one paragraph under the download pipeline)
- Modify: `docs/superpowers/specs/2026-10-03-connection-bonding-design.md` (Status line)

- [ ] **Step 1: Add the CLAUDE.md section** — concise invariants only:

```markdown
### Connection bonding (`Macget/Engine/Bonding/`)

Uses several internet links at once (Wi-Fi + USB-tethered phone). Off by default (`AppSettings.bonding`).

- **URLSession can't pin to an interface on macOS**, so workers on non-default links use `NWPinnedTransport` (`NWConnection` + `requiredInterface`, hand-rolled HTTP/1.1 via the pure `HTTPResponseParser`). Default-link workers stay on URLSession, untouched.
- `BondingPolicy.quotas` splits the existing 1…16 thread budget across links (≥2 per link); there is no speed weighting — work stealing gives the faster link more pieces.
- **A pinned-link failure only drops that link from that download.** 401/403/3xx-loop/200-instead-of-206/Content-Range mismatch/TLS → `ChunkError.linkRejected`; connection errors → `.linkTransport` strikes (3 in 30 s → excluded). Neither prompts for credentials, triggers `restartFromScratch`, nor feeds `noteRapidFailure`.
- **Host demotion judges the default link on its own throughput while bonding.** Aggregate speed would hide a dead default link behind a healthy phone and write a `HostCapStore` entry against a blameless server.
- Any proxy (app or system) disables bonding for that download — the pinned transport has no proxy support and must not bypass one.
- Torrents: aria2 `--multiple-interface=<IPv4s>`, launch-only, so a link change stops torrents, restarts the daemon and re-adds them (`DownloadEngine.applyTorrentBonding`). A failed launch retries without the flag. Per-link torrent stats come from `nettop` on aria2's pid, apportioned by per-torrent speed (flagged `isEstimate` with >1 torrent).
- `NetworkLinkMonitor` is also the engine's reachability source (`LinkSnapshot.isOnline`).
```

- [ ] **Step 2: Add the `docs/architecture.md` paragraph** summarizing the same in 3–4 sentences, linking to the spec.

- [ ] **Step 3: Update the spec status** to `**Status:** implemented`.

- [ ] **Step 4: Run the full suite one last time**

Run: `$TEST`
Expected: all tests pass. Paste the summary line into the final report.

- [ ] **Step 5: Hand the hardware checklist to the user** (the agent cannot plug in a phone or see the screen). Ask them to run the app with Wi-Fi + iPhone USB tethering and bonding on, and report:
  1. A large HTTP download from a range-capable CDN shows both links in the row breakdown, inspector and toolbar strip, and `nettop -m route` shows traffic on both interfaces.
  2. Unplugging the phone mid-download: the download keeps going on Wi-Fi; the inspector shows "Link down".
  3. A healthy torrent shows a two-link split (Task 11/12 only).
  4. A known IP-signed URL (if they have one) shows "Not accepted by server" and still completes.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/architecture.md docs/superpowers/specs/2026-10-03-connection-bonding-design.md
git commit -m "docs: document connection bonding"
```
