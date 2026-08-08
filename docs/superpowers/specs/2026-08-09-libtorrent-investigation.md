# Investigation: should MacGet replace aria2 with libtorrent?

**Date:** 2026-08-09
**Status:** research only — no code change proposed
**Verdict:** not yet. Land the aria2 tuning first and re-measure. Revisit if the
triggers at the end fire.

## The question

MacGet drives `aria2c` as an external process over JSON-RPC. µTorrent uses a bespoke
engine; qBittorrent and Deluge use libtorrent. Is MacGet's torrent support a tier below
because of the engine, and is switching worth it?

## What aria2 actually delivers today

Measured on this machine, 2026-08-09, over an **iPhone Personal Hotspot** (`172.20.10.3`
— carrier-grade NAT, no inbound connections possible):

| Torrent | Rate | Outcome |
|---|---|---|
| Walter Mitty 1080p YIFY, 1.98 GB | 6.65 MB/s (~53 Mbps) | completed |
| Walter Mitty CEE REMUX, 25.86 GB | 0.53 MB/s | 5% before cancellation |

Read from the aria2 control-file bitfield over a 150-second window, long enough to see
past aria2's 60-second `--auto-save-interval`.

This matters for the decision: on a tethered, NAT-ed, carrier link, aria2 saturated the
connection on a healthy swarm. **The engine was not the bottleneck in the case that
prompted the question.** The slow torrent was slow because a 25 GB REMUX has few seeders,
which no engine fixes.

## What libtorrent would actually add

| Capability | aria2 1.37 | libtorrent 2.0 |
|---|---|---|
| µTP (BEP 29) | **no** — open since 2013 ([#263](https://github.com/aria2/aria2/issues/263), [#489](https://github.com/aria2/aria2/issues/489), [#1386](https://github.com/aria2/aria2/issues/1386)) | yes, "high quality" implementation |
| BitTorrent v2 (BEP 52) | no | yes |
| Piece picking | basic | rarest-first, endgame, tuned |
| Peer/choking algorithms | basic | mature |
| Bandwidth shaping per torrent | global only | per-torrent |

**µTP is the one that matters,** and it matters *most* on exactly the link measured above.
It is UDP-based, self-throttling, does NAT hole-punching, and resists the TCP RST
injection some ISPs use against BitTorrent. Without it MacGet only ever reaches
TCP-speaking peers, which on a modern swarm is a meaningful fraction missing — and on a
throttled mobile link, the fraction that would work best.

So: the engine is not the current bottleneck, but it is a real ceiling, and the ceiling is
lowest on the kind of connection being used.

## Integration cost — the honest version

### Swift cannot talk to libtorrent directly

Swift's C++ interop is not sufficient for libtorrent's API surface
([Swift.org, supported features and constraints](https://www.swift.org/documentation/cxx-interop/status/)):

- **C++ exceptions cannot be caught.** An uncaught C++ exception reaching Swift terminates
  the process with a fatal error. libtorrent throws (`libtorrent::system_error`) for
  malformed torrents, bad paths, and I/O failures — precisely the conditions a download
  manager must survive. Every call would need a C++-side `try`/`catch` wrapper.
- **Class templates are not available**, only instantiated specializations. libtorrent's
  API leans on templates and Boost types throughout, including `alert_cast<T>` for the
  alert loop that drives all progress reporting.
- **`std::variant` and `std::tuple` are not fully supported**, and C++20 modules cannot be
  imported at all.

The realistic shape is therefore **a hand-written Objective-C++ or C shim** exposing a flat
C API — add torrent, remove, pause, poll status, drain alerts — with Swift calling only
that. This is what every Swift/libtorrent project does. It is not exotic, but it is a real
component to design, write, and test, and it is the piece that would need to be as
trustworthy as `TorrentJob` is today.

### Build and distribution

libtorrent 2.0 requires **C++14 or newer and Boost 1.67+** — Asio, Optional, System,
Multiprecision, Intrusive, Pool, CRC ([libtorrent features](https://www.libtorrent.org/features.html)).
Boost-build is the recommended path specifically because it compiles the dependent Boost
libraries with matching compiler settings, and it generally wants the full Boost *source*
package rather than a package-manager install
([libtorrent building docs](https://www.libtorrent.org/building.html)).

The good news, and it is genuinely good: **static linking removes the objection that keeps
aria2 unbundled.** `CLAUDE.md` records that aria2 isn't vendored because it links against
`openssl@3`, `libssh2`, `c-ares`, `sqlite` and `gettext` — five dylibs to re-path and
notarize. A statically linked libtorrent produces no runtime dylibs at all, so the
notarization story gets *simpler*, not harder. The cost moves from "ship and sign five
dylibs" to "reproducibly build Boost + libtorrent for arm64 in CI".

### Licensing

libtorrent is **BSD**, aria2 is GPL. Today MacGet sidesteps aria2's GPL by never
redistributing it — a real constraint that also forces the Homebrew-install-on-demand flow
in `TorrentToolInstaller`. BSD means libtorrent can simply be bundled. **Licensing argues
for libtorrent**, and it would delete the entire "aria2 isn't installed, let me shell out
to Homebrew" code path and its failure modes.

### What gets deleted vs written

| Deleted | Written |
|---|---|
| `Aria2Daemon` (279 lines) | C/ObjC++ shim over libtorrent |
| `Aria2RPCClient` (242 lines) | Swift wrapper actor over the shim |
| `TorrentToolLocator` + `TorrentToolInstaller` (179 lines) | alert-loop → snapshot bridge |
| the Homebrew install UX and its error states | Boost + libtorrent CI build |

`TorrentJob`, `MagnetLink`, the models, and all the UI stay — the design already isolates
the engine behind `onStateChange`/`onSnapshot`, which is exactly the seam a swap needs.
That is a genuine point in favour: the architecture is already ready for this.

I am not going to put a week-count on it. The shim and the reproducible Boost build are
both "unknown until attempted", and any estimate I gave would be invented.

## Options

**A. Stay on aria2, land the tuning.** Already specced. `--bt-request-peer-speed-limit`
alone (50 KB/s default) is likely leaving peers undiscovered. Cheap, reversible, and it
gives a clean baseline to measure any future engine against.

**B. Spike the shim behind the existing seam.** Timebox a prototype: static libtorrent +
a minimal C shim + a `LibtorrentJob` conforming to the same callbacks as `TorrentJob`,
selectable by a hidden setting. Both engines coexist; measure on the same torrents. This
is the only way to get a real number instead of an argument.

**C. Commit to the migration now.** Not justified by current evidence.

**Recommendation: A now, B when a trigger fires.** The measured data does not support
paying B's cost yet, and A produces the baseline B would be judged against.

## Triggers that should reopen this

- Tuned aria2 still stalls on swarms that µTorrent/qBittorrent handle on the same link
  and the same torrent — the only true apples-to-apples test.
- Users report torrents that never connect on ISPs known to interfere with BitTorrent over
  TCP; µTP is the specific fix for that.
- BitTorrent v2 / hybrid torrents become common enough that aria2's lack of BEP 52 causes
  visible failures.
- Torrent support becomes a headline feature rather than a secondary download kind, making
  the Homebrew-dependency UX unacceptable.

## Sources

- [Supported Features and Constraints of C++ Interoperability — Swift.org](https://www.swift.org/documentation/cxx-interop/status/)
- [Mixing Swift and C++ — Swift.org](https://www.swift.org/documentation/cxx-interop/)
- [libtorrent features](https://www.libtorrent.org/features.html)
- [libtorrent building](https://www.libtorrent.org/building.html)
- [Upgrading to libtorrent 2.0](https://www.libtorrent.org/upgrade_to_2.0-ref.html)
- [aria2 issue #263 — uTP support](https://github.com/aria2/aria2/issues/263)
- [aria2 issue #489 — Any plans for uTP protocol?](https://github.com/aria2/aria2/issues/489)
- [aria2 issue #1386 — feature request: uTP support](https://github.com/aria2/aria2/issues/1386)
- [Micro Transport Protocol — Wikipedia](https://en.wikipedia.org/wiki/Micro_Transport_Protocol)
