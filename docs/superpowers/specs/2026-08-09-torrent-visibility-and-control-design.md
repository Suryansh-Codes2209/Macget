# Torrent visibility & control

**Date:** 2026-08-09
**Status:** approved, not yet implemented

## Why

A torrent that downloads correctly is still useless if the user can't find it. Three
gaps, in descending order of pain:

1. **A finished torrent is a folder, and the app treats it as a file.** `Download.destinationURL`
   is `destinationFolder + filename`, which for a multi-file torrent resolves to the
   *directory* aria2 created. "Open File" therefore opens a Finder window instead of
   playing the movie, and there is no way to see what is inside without leaving the app.
2. **Torrents are invisible in a long queue.** With 30+ HTTP downloads in the list, the
   two torrent rows are indistinguishable noise. The sidebar filters by status only.
3. **aria2 runs on defaults tuned for a 2010 connection.** `--bt-request-peer-speed-limit`
   defaults to 50 KB/s, above which aria2 stops looking for more peers, and
   `--check-integrity=true` is passed unconditionally so every resume re-hashes all
   existing data — gigabytes of disk reads on a large torrent, at every launch.

Out of scope: the menu bar status item (separate spec) and any change of torrent engine
(separate investigation).

## 1. Type filter in the sidebar

A new filter axis, orthogonal to status.

```swift
enum KindFilter: String, CaseIterable, Identifiable {
    case all, files, media, torrents
}
```

Lives beside `StatusFilter` in `DownloadListViewModel.swift`. The view model gains
`selectedKind: KindFilter = .all`; `filtered(_:)` applies the kind predicate before the
existing status predicate; `count(for kind:)` mirrors `count(for filter:)`.

**The two axes are independent totals.** Status counts ignore the current kind selection
and vice versa. The alternative — each axis counting within the other's selection — makes
numbers shift as the user clicks around, which reads as a bug.

`KindFilter` maps to `DownloadKind` one-to-one (`files → .httpFile`, `media → .media`,
`torrents → .torrent`), with `.all` matching everything.

### Sidebar structure

`ContentView.sidebar` becomes a single `List` containing two `Section`s, "Status" and
"Type". SwiftUI's `List(selection:)` binds exactly one value, so rows become buttons
carrying their own highlight state rather than relying on list selection. The existing
visual treatment is preserved verbatim: leading SF Symbol, label, trailing `countPill`,
amber accent on the active row, `.listStyle(.sidebar)`.

## 2. Files section in the Inspector

`DownloadInspectorView` already has a torrent branch (Seeders/Peers stats) and a `section`
helper. Add a `filesSection`, rendered when the row is a torrent with a non-empty
`torrentFiles`.

Per entry: `TorrentFileEntry.displayName`, a `ByteCountFormatter` size, dimmed styling
when `selected == false`, and an Open button for that single file.

**Path resolution.** aria2 reports absolute paths in `TorrentFileEntry.path`. Resolve with
`URL(fileURLWithPath:)` when the path is absolute, and fall back to
`destinationFolder.appendingPathComponent(path)` otherwise. A per-file Open button is
disabled when the resolved file is not on disk — selective downloads legitimately leave
unselected files absent.

**Display cap.** Render at most 50 entries followed by a "+N more" line. Season packs and
music discographies routinely carry hundreds of files, and the inspector is a fixed-width
panel.

## 3. Open the main file

`DownloadRowItem` gains:

```swift
var primaryFileURL: URL   // largest torrent file, else destinationURL
```

The largest file is the right heuristic because the payload dwarfs its companions — in the
motivating case a 1.98 GB `.mp4` beside a 128 KB poster `.jpg`. Fall back to
`destinationURL` when the download is not a torrent, when metadata has not arrived, or
when the chosen file is missing on disk.

Context menu wiring in `DownloadListView`:

| Action | Target |
|---|---|
| Open File (⌘O) | `primaryFileURL` |
| Show in Finder (⇧⌘R) | `destinationURL` — the folder |
| Double-click (`DownloadListView.swift:127`) | unchanged, still reveals |

## 4. aria2 tuning

`TorrentEngineOptions` gains `maxPeers`, `diskCacheBytes`,
`requestPeerSpeedLimitBytesPerSec`, and `verifyOnResume`. `Aria2Daemon.arguments` gains:

| Flag | New value | aria2 default | Rationale |
|---|---|---|---|
| `--bt-max-peers` | 100 | 55 | larger swarm per torrent |
| `--bt-request-peer-speed-limit` | 10M | 50K | aria2 stops seeking peers above this; the default caps peer discovery at dial-up speeds |
| `--disk-cache` | 64M | 16M | fewer, larger writes on multi-GB torrents |
| `--file-allocation` | falloc | prealloc | APFS supports `fallocate`; avoids writing zeroes up front |
| `--bt-tracker-connect-timeout` | 30 | 60 | abandon dead trackers sooner |
| `--bt-tracker-timeout` | 30 | 60 | same |

### `--check-integrity` becomes opt-in

Currently passed as `--check-integrity=true` at launch, so aria2 re-hashes every existing
piece each time a torrent resumes. It becomes conditional on
`AppSettings.torrentVerifyOnResume`, **default false**, surfaced as a
"Verify downloaded data on resume" toggle in Settings ▸ Torrents.

This is a real behaviour change and deserves stating plainly: aria2 still verifies each
piece's hash as it arrives, so corruption during transfer is still caught. What is skipped
is the full re-verification of already-written data at resume — which protects only
against corruption that happened *outside* aria2 (disk faults, an editor touching the
partial file). The cost of leaving it on is re-reading the entire partial file on every
launch.

Seed ratio, seed time, upload limit, listening port and DHT are **already** exposed in
`TorrentSettingsView` and need no work. Setting seed ratio to 0 stops seeding at
completion, which matters on a metered or tethered connection.

## Testing

| Test | Covers |
|---|---|
| `KindFilterTests` | kind predicate, per-kind counts, composition with a status filter |
| `PrimaryFileURLTests` | largest file wins; non-torrent falls back; absent metadata falls back; missing file falls back |
| `Aria2ArgumentsTests` | each new flag present with the expected value; `--check-integrity` absent when `verifyOnResume` is false and present when true |

`Aria2Daemon.arguments` is a pure static function and is already exercised this way by
`TorrentTests` (`test_doesNotUseAria2SessionPersistence`), so the new assertions follow an
established pattern.

The Inspector files section is a pure view with no logic worth mocking; it is verified by
running the app against a real multi-file torrent.

## Files touched

- `Macget/ViewModels/DownloadListViewModel.swift` — `KindFilter`, `selectedKind`,
  `filtered(_:)`, `count(for kind:)`, `primaryFileURL` on `DownloadRowItem`
- `Macget/Views/ContentView.swift` — two-section sidebar
- `Macget/Views/Inspector/DownloadInspectorView.swift` — files section
- `Macget/Views/DownloadListView.swift` — context menu targets
- `Macget/Engine/Torrent/Aria2Daemon.swift` — `TorrentEngineOptions`, `arguments`
- `Macget/Models/AppSettings.swift` — `torrentVerifyOnResume`
- `Macget/Views/TorrentSettingsView.swift` — verify toggle
- `MacgetTests/` — three new test cases
