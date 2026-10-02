# Connection bonding

**Date:** 2026-10-03
**Status:** approved design, spec under review

## Why

A user with two internet connections at once — slow Wi-Fi plus a phone on USB
tethering, or Ethernet plus Wi-Fi — gets the speed of only one of them. macOS routes
every connection out of the single default route; plugging in a second link changes
*which* link is used, not how much capacity is available.

MacGet already splits a range-capable HTTP download into many pieces and lets idle
workers steal the next outstanding piece (`SlotFiller`). If different workers are pinned
to different links, the faster link simply finishes more pieces — aggregation falls out
of the existing scheduler with no new balancing logic. The same idea applies to
torrents, where aria2 can spread outgoing peer connections across interfaces.

The user also wants to *see* it working: per download, how much each link is
contributing, and globally, what each link is carrying across all downloads.

## Scope

In:

- Multi-connection (range-capable) HTTP/HTTPS file downloads.
- Torrents, via aria2 `--multiple-interface`.
- Per-link speed in the download row, the inspector, a global toolbar strip, and the
  menu-bar dropdown.
- Settings: a master switch (off by default) and a per-link toggle.

Out:

- yt-dlp media downloads (yt-dlp binds one interface per process; small gain, messy).
- Per-link speed caps and per-link data budgets.
- Manually choosing which link is "primary".
- Servers without Range support — they stay single-connection on the default link.

## The core constraint

`URLSession` cannot pin a request to a network interface on macOS, and Multipath TCP
(`multipathServiceType`) is iOS-only (already noted in `URLSessionFactory.swift`). A
worker that must use a specific link therefore needs a second transport built on
Network.framework: `NWConnection` with `NWParameters.requiredInterface`.

Chosen approach — **hybrid**:

- Workers on the default-route link keep using `URLSessionFactory.shared`, unchanged.
- Workers on every other enabled link use a new `PinnedHTTPTransport`.

Rejected: moving *all* workers to the new transport (regresses proxy, HTTP/2 and
Digest/NTLM for users who never enable bonding), and libcurl with `CURLOPT_INTERFACE`
(a C dependency; bundling it reintroduces the dylib signing problem that kept aria2 out
of `Vendor/bin`).

## Components

New, under `Macget/Engine/Bonding/`:

### `NetworkLinkMonitor` (actor)

Wraps `NWPathMonitor` and publishes `[NetworkLink]`:

```swift
struct NetworkLink: Sendable, Hashable, Identifiable {
    let id: String              // BSD name, e.g. "en0"
    let displayName: String     // "Wi-Fi", "iPhone USB", "Ethernet"
    let kind: Kind              // .wifi, .wiredEthernet, .tethered, .other
    let addresses: [IPAddress]  // local IPv4/IPv6
    let isDefaultRoute: Bool
    let nwInterface: NWInterface
}
```

- A link counts as usable only once a per-interface `NWPathMonitor(requiredInterface:)`
  reports `.satisfied` — reaching the internet, not merely being plugged in.
- Excludes VPN tunnels (`utun*`, `ipsec*`), loopback, AWDL/`llw*`, and bridge interfaces.
- Debounces changes 2s so a tether reconnect doesn't churn workers or the aria2 daemon.
- Absorbs `DownloadEngine`'s existing whole-machine reachability monitor
  (`startNetworkMonitoring`/`handleNetworkPath`), so there is one source of truth.
  "Network lost" now means *no* usable link.

### `BondingPolicy` (pure struct)

`assign(links:settings:threadCount:) -> [WorkerSlot]`, where each slot carries a link
(`nil` = default route / URLSession).

- Fewer than 2 enabled usable links, or bonding off → every slot is `nil`. Today's
  behavior, no new code on the path.
- Otherwise slots are split evenly across enabled links, minimum 2 per link, with the
  existing `1...16` thread clamp unchanged. If the clamp leaves fewer than 2 per link,
  drop the least-preferred links (non-default, then by kind: Ethernet > Wi-Fi >
  tethered) until it fits.
- No speed-based weighting: work stealing already gives the faster link more pieces.

### `PinnedHTTPTransport`

One HTTP/1.1 connection bound to one link.

- `NWConnection` to the final (post-redirect) URL's host, `requiredInterface` set,
  TLS via `NWProtocolTLS` with the system trust store and SNI set to the host name.
  Plain `http` uses TCP only.
- Sends `GET` with `Range`, `If-Range`, the download's captured headers (Cookie,
  Referer, User-Agent), the MacGet UA, `Accept-Encoding: identity`, and Basic auth when
  the host has a stored Basic credential.
- Parses the status line, headers, `Content-Range`, and bodies framed by either
  `Content-Length` or `Transfer-Encoding: chunked`. The parser is a separate pure type
  (`HTTPResponseParser`) fed byte buffers so every branch is fixture-testable.
- Delivers the body as the same `AsyncThrowingStream<Data, Error>` `ChunkWorker` already
  consumes.
- Keep-alive: a worker reuses its connection across stolen pieces, so a steal doesn't
  cost a fresh TLS handshake. Closed on `Connection: close`, error, or worker exit.
- Does **not** follow redirects (the probe already resolved the final URL; a redirect on
  a pinned connection is treated as "link not accepted"). Does not speak proxies,
  Digest, NTLM, or HTTP/2.

### `LinkSpeedMeter`

A dictionary of existing `SpeedMeter`s keyed by link ID, owned by each
`DownloadCoordinator`.

### `TorrentLinkAttributor`

Samples the aria2 process's received bytes per interface about once a second using
macOS's per-process network statistics (the source `nettop` reads), and splits each
link's delta across active torrents in proportion to their aria2-reported download
speeds.

- Exact when one torrent is active; an estimate otherwise, flagged so the UI shows "≈".
- These statistics are not a stable public API. If they are unavailable or fail to
  parse, the attributor reports `unavailable` and the UI says so — it never guesses.
  The first implementation step validates that the data source works on macOS 26.

### Changes to existing code

- **`ChunkWorker`** gains `link: NetworkLink?`. `nil` → URLSession exactly as today.
  Non-nil → `PinnedHTTPTransport`. The 206 / `Content-Range` validation moves out of the
  private `StreamingDelegate` into a shared function both transports call.
  `report` gains the link ID.
- **`DownloadCoordinator`** — `fillIdleSlots` asks `BondingPolicy` for slot assignments
  and spawns each worker on its slot's link. Owns `LinkSpeedMeter` and per-link
  `DemotionPolicy` instances.
- **`DownloadSnapshot`** gains `links: [LinkStat]` (empty when only one link is in use):

  ```swift
  struct LinkStat: Sendable, Equatable {
      let linkID: String
      let displayName: String
      let kind: NetworkLink.Kind
      let speedBytesPerSec: Double
      let bytesThisSession: Int64
      let activeConnections: Int
      let status: Status          // .active, .rejectedByServer, .down
      let isEstimate: Bool        // torrents with >1 active
  }
  ```

  Not persisted — live only, like `speedBytesPerSec`.
- **`Aria2Daemon`** — when bonding is on and ≥2 enabled links are usable, adds
  `--multiple-interface=<comma-separated IPv4 addresses>` (addresses, not BSD names,
  since aria2 binds by address; macOS scoped routing then sends traffic out of the owning
  interface). Restarts when the effective link set changes.
- **`AppSettings.bonding`**: `BondingSettings { enabled: Bool = false;
  disabledLinkIDs: Set<String> = [] }`. `Codable`, `Sendable`, decodes absent as default.

## Data flow

### HTTP download with bonding on

1. **Probe** — `RangeProbe` on URLSession as today. Records the final URL after
   redirects, `Accept-Ranges`, `ETag`/`Last-Modified`, size. No Range support → single
   chunk on the default link; bonding doesn't apply.
2. **Choose links** — coordinator reads `NetworkLinkMonitor`'s current links and asks
   `BondingPolicy` for slot assignments.
3. **Plan** — `ChunkPlanner` unchanged. Pieces are not tied to links; workers are.
4. **Spawn** — `fillIdleSlots` fills each slot on its assigned link. Default-link slots
   use URLSession; the rest use `PinnedHTTPTransport` against the final URL with the same
   `If-Range`. 100ms stagger kept.
5. **Steal** — a worker that finishes a piece steals the next outstanding piece (or
   splits the largest in-flight one) and keeps its link.
6. **Count** — `report(chunkID, linkID, bytes)` feeds the per-link `SpeedMeter`.
   URLSession workers confirm their actual link from
   `URLSessionTaskMetrics.transactionMetrics.last?.localAddress` mapped to an interface
   at each task's completion; until then they are attributed to the default-route link.
7. **Publish** — the 250ms loop emits `DownloadSnapshot` with `links` populated.

### Link set changes mid-download

- **Link drops**: its workers fail with connection errors; the coordinator marks the
  link down for this download, does not retry those pieces on it (no backoff spent), and
  their remaining ranges go back to the outstanding pool. The download pauses with
  "Waiting for network…" only when **no** link is usable.
- **Link appears / is re-enabled**: `fillIdleSlots` adds slots for it on its next
  evaluation. No restart.

### Torrents

- Link set change → `Aria2Daemon` restarts with the new `--multiple-interface` value;
  MacGet re-adds its torrents (it already owns the queue) and `--continue` plus the
  `.aria2` control files resume them. Active torrents stall for a few seconds.
- `TorrentLinkAttributor` samples once a second; `TorrentJob` includes the resulting
  `LinkStat`s in the snapshots it already emits.
- Expected coverage: outgoing peer connections are spread across links. Incoming peer
  connections, DHT and UDP trackers likely stay on the default route. This is verified
  empirically (see Testing) before being described to users.

### Global strip

`DownloadListViewModel` sums `LinkStat.speedBytesPerSec` across active snapshots, grouped
by `linkID`. `StatusBarModel` reads the same aggregate. No new engine API.

## Failure handling

Governing rule: **a failure on a pinned link removes that link from that download; it
never fails the download.** Only default-link (URLSession) failures follow today's error
paths.

| Situation | Detection | Response |
|---|---|---|
| Server rejects second IP (IP-signed CDN URL, auth tied to IP) | Pinned worker gets 401/403 | Drop link for this download; status `.rejectedByServer`; piece returns to pool |
| Different edge / file version via per-link DNS | Pinned worker gets 200 instead of 206, or `Content-Range` mismatch | Same as above. `rangeRefused`/`wrongContentRange` are caught *before* they reach the fatal non-retryable path |
| Redirect on a pinned connection | 3xx | Same as above |
| System proxy applies to host, or host needs Digest/NTLM, or server is HTTP/2-only | Checked up front (proxy via `CFNetworkCopyProxiesForURL`, stored credential type); otherwise first pinned attempt fails | Bonding skipped for that download; runs on default link as today |
| Link physically drops | Connection errors + `NetworkLinkMonitor` confirmation within 2s debounce | Workers on it stop; no retries on that link; resumes using it if it returns |
| TLS failure on pinned connection | `NWConnection` `.failed` with TLS error | Drop link for this download. No "allow insecure" option |
| One link failing while others flow | Per-link `DemotionPolicy` | Demote/drop that link only. **Never** writes `HostCapStore` |
| Failures on every active link simultaneously | All per-link policies trip | Existing behavior: host-level demotion, may write `HostCapStore` |
| aria2 fails to start with `--multiple-interface` | Daemon launch / RPC readiness fails | Retry once without the flag; Settings shows "bonding inactive for torrents" |
| Torrent attribution data unavailable | Attributor read fails | `LinkStat`s omitted; UI shows "per-connection split unavailable" |

The global `RateLimiter` applies to pinned workers too, so the user's speed cap still
bounds the combined total.

## UI

### Settings ▸ Network ▸ Combine connections

- Master toggle, off by default.
- List of detected links: icon, name, live status ("Connected · default route",
  "Connected", "No internet"), per-link toggle.
- Footnote: "Uses all enabled connections for multi-connection downloads and torrents.
  Data from a tethered phone counts against your mobile plan."
- Inline notice when torrents have fallen back to a single link.

### `DownloadRowCard`

When `links.count ≥ 2`:

- A thin stacked bar under the progress bar, each segment one link's share of current
  speed. Colors are stable per link kind: Wi-Fi blue, tethered green, Ethernet orange,
  other gray (theme tokens in `Views/Theme`).
- Caption: `Wi-Fi 1.2 MB/s · iPhone USB 3.4 MB/s`, prefixed `≈` when any stat is an
  estimate.

With 0–1 links the row is identical to today.

### Inspector (`DownloadInspectorView`)

- New "Connections" section: per-link rows with color dot, name, speed, bytes this
  session, active connections, status ("Active", "Not accepted by server", "Link down").
- `SpeedChartView` becomes a stacked area chart by link when ≥2 links contributed.
  `SpeedSeries` records per-link samples alongside the total.

### Global strip

- Slim bar in the main window toolbar: `Wi-Fi 1.8 MB/s │ iPhone USB 4.1 MB/s │ Total
  5.9 MB/s`. Hidden unless ≥2 links are carrying MacGet traffic.
- Same totals in the menu-bar dropdown via `StatusBarModel`.

### Accessibility

Color is never the only signal: segments carry text labels, and VoiceOver reads e.g.
"Wi-Fi, 1.2 megabytes per second, 26 percent of current speed".

## Testing

XCTest, no live network — transports are injected as stubs.

| Unit | Cases |
|---|---|
| `BondingPolicy` | Even split; minimum 2 per link; `1...16` clamp; link dropped when clamp is too tight; single link / bonding off → all `nil`; disabled links excluded |
| `HTTPResponseParser` | 206 + `Content-Range`; `Content-Length` body; chunked body; headers split across buffers; 200 instead of 206; 3xx; early close mid-body |
| Coordinator fallback (stub transport) | Pinned 403 drops only that link, download completes on the rest; pinned 200 does not fail the download; link-down returns pieces to pool; all links down → paused |
| Per-link `DemotionPolicy` | One link failing while others flow never writes `HostCapStore`; all links failing does |
| `LinkSpeedMeter` / snapshot | Per-link speeds sum to the total; URLSession attribution from `localAddress` |
| `TorrentLinkAttributor` | Proportional split; single torrent exact and not flagged; unavailable source → no stats |
| `Aria2Daemon` arguments | `--multiple-interface` present only with bonding on and ≥2 links; absent on fallback retry |
| `NetworkLinkMonitor` (filtering/debounce logic extracted to a pure helper) | Excludes `utun`/`lo`/`awdl`/`llw`/`bridge`; debounce collapses flaps |
| `AppSettings` | `bonding` decodes as default when absent from existing `settings.json` |

Manual verification on real hardware (Wi-Fi + iPhone USB tethering):

1. HTTP download of a large file from a range-capable CDN: `nettop -m route` shows
   traffic on both interfaces; row/inspector/strip show both links; total ≈ sum.
2. Unplug the phone mid-download: download continues on Wi-Fi without erroring.
3. Torrent with a healthy swarm: confirm outgoing peer connections on both interfaces
   and that attributed stats track `nettop`.
4. A known IP-signed URL: second link shows "Not accepted by server", download completes.

## Risks

- **Per-process interface stats** may be unusable from a non-root, non-sandboxed app on
  macOS 26. Validated first; the fallback (torrent split "unavailable") is already
  specified.
- **aria2 `--multiple-interface` coverage of BitTorrent** is expected for outgoing peer
  connections but not yet verified. If it turns out to do nothing for BT, torrent
  bonding is dropped and the torrent row simply never shows a split.
- **A second, hand-written HTTP/1.1 client** is new surface area. It is kept narrow
  (range GET only, no redirects/proxy/HTTP/2) and only ever runs on extra links, so its
  failure mode is "that link isn't used", never a failed download.
