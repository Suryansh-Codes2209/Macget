# Torrent performance

**Date:** 2026-08-10
**Status:** approved, not yet implemented

## Why

Torrent throughput is mostly swarm-bound: a torrent with three slow seeds cannot be
tuned into a fast one. But MacGet is currently leaving several client-side levers
unpulled, and one of them is actively throttling fast connections.

The headline defect is a single flag. `Aria2Daemon.arguments` sets
`--bt-request-peer-speed-limit=10M`, with a comment explaining that aria2 *stops looking
for more peers* once a torrent exceeds this value, and that aria2's own 50K default
therefore "caps peer discovery at dial-up speed." The reasoning is right and was not
followed far enough: 10M is 10 MB/s, roughly 80 Mbps. On a gigabit link MacGet stops
hunting for peers at 8% of the available capacity — the exact failure the comment
describes, ~200x further up the scale.

Four further gaps, in descending order of real-world impact:

1. **No inbound reachability story at all.** aria2 implements neither UPnP IGD nor
   NAT-PMP, and macOS ships no port-mapping API. Unless the user has manually forwarded
   `torrentListenPort`, MacGet is unconnectable: it can only reach peers that it dials
   out to, and never receives incoming connections. In a typical swarm that removes
   roughly half the reachable peers, and there is currently no indication in the UI that
   anything is wrong.
2. **Peer discovery is narrower than it needs to be.** `bt-max-peers` is hardwired to
   100 — `TorrentEngineOptions.init(settings:)` does not pass `maxPeers` at all, so the
   field is unreachable from settings. IPv6 DHT is off. Magnets whose embedded trackers
   are dead fall back to DHT alone.
3. **Nothing defends against ISP throttling.** aria2's `bt-min-crypto-level` defaults to
   `plain`, so the BitTorrent handshake is trivially identifiable by DPI. Where an ISP
   shapes BitTorrent traffic this is the whole ballgame.
4. **Three non-flag defects make torrents look or run slow.** The global speed limit
   silently applies to torrents; aria2's `max-concurrent-downloads` default of 5 silently
   queues the 6th torrent while MacGet's row claims it is running; and seeding torrents
   occupy download slots.

Out of scope: switching torrent engines (see `2026-08-09-libtorrent-investigation.md`),
UPnP IGD (see "Non-goals"), and per-torrent bandwidth limits.

## Verification note

Every flag named here was checked against the aria2 shipped by Homebrew on this machine
(**aria2 1.37.0**, `/opt/homebrew/bin/aria2c`) rather than assumed from documentation.

The load-bearing check: `bt-tracker` and `bt-require-crypto` both appear in the aria2
manual's *Input File* option list, which is the same set the RPC `aria2.addUri` /
`aria2.addTorrent` methods accept as per-download options. Tracker injection therefore
can be decided **per torrent** rather than globally, which is what makes the
private-torrent gate in §3 possible. If these were launch-only globals the entire
private-flag design would collapse.

## Architecture

No new subsystems. The existing settings → `TorrentEngineOptions` → `Aria2Daemon`
pipeline carries almost everything; port mapping is the one genuinely new component.

| Piece | Location | Role |
|---|---|---|
| `TorrentEngineOptions` | extend, `Aria2Daemon.swift` | four new fields |
| `Aria2Daemon.arguments` | extend, `Aria2Daemon.swift` | new launch flags |
| `TorrentTrackers` | **new**, `Engine/Torrent/TorrentTrackers.swift` | bundled tracker list + private gate; pure and synchronous |
| `TorrentMetainfo` | **new**, `Engine/Torrent/TorrentMetainfo.swift` | minimal bencode reader; extracts the `private` flag |
| `PortMapper` | **new**, `Engine/Torrent/PortMapper.swift` | actor: PCP/NAT-PMP mapping, renewal, reachability state |
| `NATPortMapCodec` | **new**, same file | pure packet encode/decode; no I/O |
| `TorrentJob.add` | extend, `TorrentJob.swift` | per-download `bt-tracker` option |
| `AppSettings` | extend | four new persisted fields |
| `TorrentSettingsView` | extend | Performance section + Connectivity row |

`Aria2Daemon.arguments` is already `static` and pure, so the whole flag surface is
unit-testable without launching a process. That property must survive this change — which
means the one launch-time *discovered* value, the host's global unicast IPv6 address, is
passed **in** rather than looked up inside:

```swift
static func arguments(
    port: Int,
    secret: String,
    options: TorrentEngineOptions,
    ipv6DHTAddress: String? = nil     // nil ⇒ omit IPv6 DHT entirely
) -> [String]
```

`start(options:)` performs the `getifaddrs` lookup and passes the result. A default of
`nil` keeps every existing call site and test compiling unchanged.

## 1. Peer discovery

```
--bt-request-peer-speed-limit=100M     # was 10M
--bt-max-peers=<settings.torrentMaxPeers>
--enable-dht6=true                     # only if DHT is on AND a global IPv6 addr exists
--dht-listen-addr6=<host global unicast IPv6>
```

`bt-request-peer-speed-limit` moves to 100M — 100 MB/s is above any consumer link, so
aria2 keeps seeking peers until the pipe is genuinely full. The flag is a peer-discovery
ceiling, not a bandwidth cap; raising it does not increase resource use on a slow link,
because a slow link never reaches the threshold either way.

`bt-max-peers` becomes `AppSettings.torrentMaxPeers`, default **200**. `TorrentEngineOptions`
already clamps to `1...500`; `init(settings:)` must now actually pass the value, which it
does not today.

IPv6 DHT reuses `torrentDHTEnabled` rather than adding a second toggle — a user who wants
DHT wants it on both stacks.

**There is no `--dht-listen-port6`.** `--dht-listen-port` is shared by IPv4 DHT, IPv6 DHT,
and UDP trackers; passing a `port6` variant makes aria2 reject the argument outright and
the daemon never starts. IPv6 DHT is instead selected by `--enable-dht6` plus
`--dht-listen-addr6`, which aria2 documents as requiring "a global unicast IPv6 address of
the host" — not a range, and not a value MacGet can hardcode.

So the daemon discovers the host's global unicast IPv6 address via `getifaddrs` at launch,
keeping only addresses in the global unicast range `2000::/3` on an interface that is up
and not loopback — which excludes link-local (`fe80::/10`), unique-local (`fc00::/7`), and
multicast (`ff00::/8`) in one predicate. Temporary/privacy addresses are **not** filtered
out: distinguishing them requires a `SIOCGIFAFLAG_IN6` ioctl, and a temporary address binds
DHT just as well as a stable one. Then:

- `torrentDHTEnabled` **and** an address found → pass both `--enable-dht6=true` and
  `--dht-listen-addr6=<addr>`
- either condition unmet → pass neither

Both conditions are required: the setting expresses intent, the address makes it possible.

Passing `--enable-dht6` alone is *not* fatal — aria2 1.37.0 starts normally — but IPv6 DHT
cannot function without the bind address, so the flag would be noise that implies a working
feature. Omitting it keeps the argument list an honest description of what is running. The
address is captured at launch and does not follow network changes; a Mac that gains IPv6
later picks it up at the next daemon start, consistent with how the listening port already
behaves.

PEX and LPD are already enabled and unchanged.

## 2. Reachability: `PortMapper`

### Protocol choice

PCP (RFC 6887) first, NAT-PMP (RFC 6886) as fallback. Both speak UDP to the default
gateway on port 5351, and PCP was designed so that a PCP client can detect a NAT-PMP-only
router from the version field in its error response. NAT-PMP alone would miss modern
IPv6-capable routers; PCP alone would miss older ones.

**Both TCP and UDP are mapped.** TCP carries peer connections, UDP carries DHT and µTP.
Mapping only one is a common and silent half-fix.

### Behaviour

- Gateway address is read from the `sysctl` routing table (`CTL_NET`/`PF_ROUTE`/
  `NET_RT_FLAGS`/`RTF_GATEWAY`), not by shelling out to `route`.
- Requested lifetime 7200s, renewed at half-life by a task owned by the actor.
- Mapping is deleted (lifetime 0) on `Aria2Daemon.shutdown()`, so the app does not leave
  a stale hole in the router.
- The mapper starts with the daemon and stops with it. Users who never open a torrent
  never emit a packet.
- `AppSettings.torrentAutoPortMapping` gates the whole component. When off, no packet is
  sent and reachability reports `.unknown` — MacGet does not claim to know the state of a
  port it was told not to touch.

### Reachability states

```swift
enum Reachability: Equatable, Sendable {
    case unknown                    // not yet probed
    case mapped(external: UInt16, via: MappingProtocol)
    case carrierGradeNAT            // mapped, but to a private/CGN address
    case unsupported                // router did not answer, or refused
    case failed(String)
}
```

**CGNAT detection is required, not a nicety.** If the router returns an external address
inside RFC1918 space or `100.64.0.0/10`, the mapping succeeded at the first NAT but the
ISP's NAT upstream still blocks inbound connections. Reporting `mapped` there would show
a green check on a connection that can never receive a peer. The user's real remedy is a
different ISP plan or a VPN with port forwarding, and only an honest state can say so.

### Non-goals

**UPnP IGD is deliberately excluded.** It requires SSDP multicast discovery, XML device
description parsing, and SOAP control requests — several times the code of PCP/NAT-PMP,
for a protocol that overlaps heavily with what PCP already covers. Routers that speak
only UPnP land in `.unsupported` and get the manual-forwarding message. Revisit only if
that state proves common in practice.

**The macOS Application Firewall is not probed.** Reading its state requires
`/usr/libexec/ApplicationFirewall/socketfilterfw`, and a blocked `aria2c` is
indistinguishable from an unmapped port from the app's point of view. The
`.unsupported` help text mentions it as a possible cause instead.

## 3. Tracker injection: `TorrentTrackers`

A small curated list of stable public trackers is compiled into the app — no runtime
fetch, no third-party repository in the trust path. The list will go stale between
releases; that is the accepted cost of not letting an external file decide who hears
about the user's torrents.

Trackers are passed **per download**, as the `bt-tracker` option on
`aria2.addUri` / `aria2.addTorrent`, never as a global launch flag.

### The private gate

A torrent whose metainfo carries the `private` flag must never be announced to a public
tracker: it defeats the tracker's ratio accounting and gets the user banned.

**aria2 will not do this for us.** Its documentation for `--enable-dht` and `--enable-dht6`
states explicitly that a private flag disables DHT for that download regardless of the
setting — and the documentation for `--bt-tracker` says nothing of the kind. The asymmetry
is the design: aria2 treats DHT as something it may suppress on the torrent's behalf, and
treats an explicitly supplied tracker as user intent it must honour. MacGet therefore owns
this gate entirely, and a test must pin it rather than trusting engine behaviour.

### Detecting the flag requires parsing bencode ourselves

aria2 does not report it. The `bittorrent` struct returned by `aria2.tellStatus` contains
only `announceList`, `comment`, `creationDate`, `mode`, and `info.name` — there is no
`private` key at any depth. So MacGet reads the metainfo directly:

- **`.torrent` files** — `Download.torrentFileData` already holds the bytes.
- **Magnets** — `--bt-save-metadata=true` is already passed, so aria2 writes
  `<infoHash>.torrent` into the download directory when metadata resolves. That file is
  read at the `followedBy` handoff.

This needs a minimal bencode reader (`TorrentMetainfo`), which must be a **real parser, not
a byte search**. The `info` dictionary contains a `pieces` value that is raw concatenated
SHA-1 digests — arbitrary binary. Any substring scan for `7:privatei1e` will eventually
match inside that digest blob and mark a public torrent private, silently disabling
trackers on a torrent that needed them. The parser only needs enough bencode to walk to
`info` → `private`, but it must walk it structurally, using each string's length prefix to
skip payloads rather than scanning through them.

A missing `private` key, or `private` set to `0`, both mean public.
- **Magnets** — the flag is unknowable until metadata arrives, but fetching metadata
  itself needs peers. MacGet injects at add time and, when `followedBy` hands off and the
  resolved metainfo reports `private`, drops the injected trackers from the child GID via
  `aria2.changeOption`.

This leaves a window in which a private magnet has announced to public trackers. It is
accepted, for a specific reason: private trackers almost universally forbid magnet
distribution, so a private torrent *arriving as a magnet* is already outside the tracker's
own rules. The alternative — never injecting into magnets — would remove the feature's
main benefit, since dead embedded trackers are overwhelmingly a magnet problem.

Injection is governed by `AppSettings.torrentAddPublicTrackers`, default **true**.

## 4. Anti-throttling

Default, applied always:

```
--bt-min-crypto-level=arc4      # was implicitly `plain`
```

This prefers an obfuscated handshake while still accepting plaintext peers, so no peers
are lost. It is a pure win and needs no setting.

When `AppSettings.torrentRequireEncryption` is on (default **false**):

```
--bt-require-crypto=true
--bt-force-encryption=true
```

This encrypts the payload as well as the handshake and refuses plaintext peers entirely.
It is the setting that defeats aggressive DPI shaping, and it shrinks the peer pool — the
UI must say so rather than presenting it as free.

## 5. Disk & I/O

```
--disk-cache=128M               # was 64M
--enable-mmap=true
```

`enable-mmap` is safe here specifically because `--file-allocation=falloc` already
preallocates the file; aria2's documented mmap failure mode is unallocated space.

**`--bt-max-open-files` stays at aria2's default of 100.** macOS's default soft
`RLIMIT_NOFILE` is 256 per process, and `Foundation.Process` offers no clean way to raise
it for the child. A larger value would simply fail at open time on a many-file torrent —
worse than the conservative default it replaced.

## 6. Three fixes that are not flags

### The global speed limit silently throttles torrents

`TorrentEngineOptions(settings:)` passes `settings.globalSpeedLimitBytesPerSec` as
`maxDownloadBytesPerSec`, which becomes `max-overall-download-limit`. This is correct
behaviour — a global limit should be global — but it is invisible from the torrent
settings, and it is the single most likely explanation for "my torrent is slow."

Torrent Settings gains an inline warning, shown only when a global limit is set, naming
the limit and linking to where it is configured.

### aria2 silently queues the 6th torrent

`--max-concurrent-downloads` is never passed, so aria2 uses its default of 5.
`AppSettings.maxConcurrentDownloads` clamps to `1...16`. With more than five active
torrents, aria2 queues the excess while `DownloadEngine` believes they are running, and
the rows sit at 0 B/s with no explanation.

Pass `--max-concurrent-downloads=<settings.maxConcurrentDownloads>` and refresh it via
`changeGlobalOption` when the setting changes — it is in aria2's mutable global set, so it
belongs in `TorrentEngineOptions.mutableGlobalOptions`.

### Seeding torrents occupy download slots

```
--bt-detach-seed-only=true
```

A torrent that has finished downloading and is only seeding no longer counts against
`max-concurrent-downloads`, so a completed torrent stops blocking a queued one.

## Settings

Four new fields on `AppSettings`, each clamped in `init` and decoded with
`decodeIfPresent` against the defaults, matching the existing torrent fields:

| Field | Type | Default | Clamp |
|---|---|---|---|
| `torrentMaxPeers` | `Int` | 200 | `1...500` |
| `torrentAddPublicTrackers` | `Bool` | `true` | — |
| `torrentRequireEncryption` | `Bool` | `false` | — |
| `torrentAutoPortMapping` | `Bool` | `true` | — |

`TorrentEngineOptions.init(settings:)` must pass all four, plus the `maxPeers` it already
drops on the floor today.

## UI

`TorrentSettingsView` gains one section and one status row.

**Performance** — three controls only:

- `Maximum peers per torrent` (stepper/field, 1–500)
- `Add public trackers to magnet links` — subtitle notes it is skipped for private torrents
- `Require encrypted connections` — subtitle notes it defeats ISP throttling **and**
  reduces the number of reachable peers

**Connectivity** — read-only, derived from `PortMapper.Reachability`:

| State | Text |
|---|---|
| `.mapped(port, .pcp)` | `Port <n> — open (mapped automatically via PCP)` |
| `.mapped(port, .natPMP)` | `Port <n> — open (mapped automatically via NAT-PMP)` |
| `.carrierGradeNAT` | `Port <n> — closed. Your ISP uses carrier-grade NAT, so incoming connections aren't possible. Downloads still work, but more slowly.` |
| `.unsupported` | `Port <n> — closed. Your router doesn't support automatic port mapping. Forward port <n> to this Mac, and check that macOS's firewall allows incoming connections for aria2.` |
| `.unknown` | `Port <n> — checking…` |
| `.failed(reason)` | `Port <n> — couldn't be mapped: <reason>` |

The row carries a toggle for `torrentAutoPortMapping`, so a user with a manual forward can
stop MacGet talking to the router.

The existing "Port changes take effect the next time the torrent engine starts" caption
still applies and stays.

## Error handling

- Port mapping is **best-effort and never fatal.** Every failure path resolves to a
  `Reachability` state and a slower download, never a failed torrent. No mapping error
  reaches `TorrentJob.fail`.
- A malformed or truncated mapping response is `.failed`, not a crash: `NATPortMapCodec`
  returns `nil` on any length or version mismatch rather than reading past the buffer.
- Renewal failure downgrades the state to `.unsupported` and retries at the next interval;
  it does not tear down the daemon.
- `changeOption` failures when dropping trackers from a private magnet are logged at
  `error` and otherwise ignored — the torrent keeps running.

## Testing

New XCTest files under `MacgetTests/`:

- **`Aria2ArgumentsTests`** — `Aria2Daemon.arguments(port:secret:options:)` is static and
  pure. Assert: `bt-request-peer-speed-limit=100M`; `bt-max-peers` tracks the setting;
  `bt-require-crypto`/`bt-force-encryption` appear only when required and
  `bt-min-crypto-level=arc4` always does; `bt-max-open-files` is absent;
  `max-concurrent-downloads` tracks the setting; `--check-integrity` still only appears
  when `verifyOnResume`. For IPv6 DHT specifically: `enable-dht6` and `dht-listen-addr6`
  appear together when an address is supplied and **neither** appears when it is `nil`,
  and no `dht-listen-port6` is ever emitted — that flag does not exist and would prevent
  the daemon from starting, so the test exists to stop it being reintroduced.
- **`NATPortMapCodecTests`** — request encoding for PCP and NAT-PMP, response parsing,
  truncated/wrong-version input returning `nil`, and the CGNAT predicate across RFC1918,
  `100.64.0.0/10`, and a public address.
- **`TorrentTrackersTests`** — trackers returned for a public torrent, empty for a
  `private` one, empty when `torrentAddPublicTrackers` is off, and the magnet handoff path
  dropping trackers once metadata resolves private.
- **`TorrentMetainfoTests`** — `private: 1` detected, `private: 0` and a missing key both
  read as public, truncated/malformed input returns `nil` rather than crashing, and — the
  regression that justifies the parser — a torrent whose `pieces` blob literally contains
  the bytes `7:privatei1e` is still reported **public**.
- **`AppSettingsTests`** (extend) — the four new fields clamp and round-trip through
  `Codable`, and missing keys fall back to defaults.

`PortMapper`'s socket I/O sits behind an injectable protocol so the actor's state machine
is testable without a router, consistent with the `session:` injection the engine already
uses.

## What this will not fix

Worth stating plainly, because the feature's name invites the wrong expectation: none of
this creates seeds. A torrent with a thin swarm stays slow, and a user on a saturated or
carrier-grade-NAT connection will see a smaller improvement than the flag list suggests.
The Connectivity row exists partly so that "slow" has a visible, honest explanation rather
than looking like an app defect.
