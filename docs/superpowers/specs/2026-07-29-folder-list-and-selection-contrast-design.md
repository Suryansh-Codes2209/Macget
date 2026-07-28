# Folder list and selection contrast

Date: 2026-07-29
Status: approved, not yet implemented

Two changes to the download list, both in `Macget/Views/`. They are independent
and can land in either order, but they touch the same two files.

---

## 1. Selected rows go blank in light mode

### Symptom

Selecting a row makes its filename and size disappear. The status line
(`Completed`) stays readable and green.

### Root cause

That asymmetry is the whole diagnosis.

- `Completed` is drawn with an explicit color, `Theme.Palette.success`. It is
  unaffected.
- The filename and size are drawn with the *semantic* `.primary` and
  `.secondary`. AppKit automatically inverts semantic foreground colors to white
  on a selected table row.
- `DownloadRowCard.isEmphasized` — `backgroundProminence == .increased`,
  `DownloadRowCard.swift:26` — evaluated **false**. If it had been true,
  `statusText()` would have painted `Completed` white as well.

So the card kept its opaque `surfaceElevated` fill (`#FFFFFF` in light mode)
while AppKit independently turned the text white. White on white.

The `isEmphasized` machinery — lines 26–32, 64, 75, 87–88, 105, 129 — was
written to defend against exactly this, but it never fires, and it does not
control the channel through which the inversion actually arrives.

### Contrast arithmetic

`BrandAmber` is `#E8963C` (light) and `#F0A64E` (dark). Against white that is
**2.37:1**; WCAG AA body text needs 4.5:1. Against a warm near-black `#2B1F12`
it is **8.8:1**. Amber is a light color in both appearances, so text sitting on
it must be dark in both appearances. There is no mode in which white-on-amber is
correct, which is why the fix deletes the inversion rather than repairing it.

### Fix

**a. Text that cannot be inverted.**

Add two colorsets to `Assets.xcassets` and expose them on `Theme.Palette`:

| Token | Light | Dark |
|---|---|---|
| `TextPrimary` | `#2B1F12` | `#F5EFE7` |
| `TextSecondary` | `#6B5C4A` | `#B3A695` |

`DownloadRowCard` uses `Theme.Palette.textPrimary` / `.textSecondary` in place of
`.primary` / `.secondary`. Explicit colors are immune to AppKit's selection
inversion.

**b. Delete the dead inversion path.**

Remove `isEmphasized`, the `@Environment(\.backgroundProminence)` property, and
every `isEmphasized ? .white : …` branch. `statusText(_:)` collapses to the
identity function and goes away with them; call sites use the status color
directly.

Selection is then drawn by the card and nothing else:

- fill: `Theme.Palette.surfaceElevated`, with a `BrandAmber @ 8%` wash when
  selected
- border: `BrandAmber` at 1.5pt when selected, `Palette.stroke` at 1pt otherwise

This is the treatment already at `DownloadRowCard.swift:67–70`, promoted from
"unfocused selection only" to "all selection".

**c. `countPill`.**

`ContentView.swift:225` puts `Color.white` on a `BrandAmber` capsule — the same
2.37:1 failure. It becomes `Theme.Palette.textPrimary`.

### Open risk: suppressing the amber band

`.listRowBackground(Color.clear)` is **already** set at
`DownloadListView.swift:140`, and the amber selection band still draws. So on
macOS 26 that highlight is an `NSTableView` selection layer, not the row
background, and clearing the row background does not remove it.

This must be verified empirically during implementation, not assumed. Fallbacks,
in preference order:

1. `.selectionDisabled(true)` on rows plus manual click / ⌘-click / ⇧-click
   handling, keeping `List` so arrow-key navigation survives.
2. Replace `List` with `ScrollView` + `LazyVStack`. This costs
   `contextMenu(forSelectionType:)` and arrow-key navigation, so it is a last
   resort.

Fix (a) stands on its own: even if the band remains, dark text on amber is
8.8:1 and the row is readable. The band is a polish problem, not a legibility
one, once (a) lands.

---

## 2. Folders replace flat category sections

### Shape

```
▼ 📁 Movies                        3 items · 8.4 GB
      ┌────────────────────────────────────────┐
      │ Ginny.Weds.Sunny.2020…mkv       5.43 GB│
      └────────────────────────────────────────┘
      ┌────────────────────────────────────────┐
      │ Margin.Call.2011…mkv            2.16 GB│
      └────────────────────────────────────────┘
▶ 📁 Archives                      1 item · 45.1 MB
▶ 📁 Code                          4 items · 464 KB
```

### Always on

Grouping stops being optional. Removed:

- `@AppStorage("groupDownloadsByCategory")` (`ContentView.swift:23`)
- the `Toggle` in the Sort menu (`ContentView.swift:91–94`) and its ⌥⌘G shortcut
- the `groupByCategory` binding through to `DownloadListView`
  (`ContentView.swift:36`, `DownloadListView.swift:53`)
- the ungrouped `ForEach(displayRows)` branch (`DownloadListView.swift:101–105`)

Sorting is unaffected and still applies *within* each folder, so "Name" plus
folders reads as an alphabetized list per kind.

Folders group whatever rows are currently visible. A status filter or a search
narrows the rows first; the folders then describe that narrowed set, and
folders that end up empty are dropped — the existing behavior at
`DownloadListView.swift:70–73`.

### New view: `Macget/Views/Components/CategoryFolderRow.swift`

- Disclosure chevron, then `DownloadCategory.symbol` in an amber-tinted tile.
  The tile reuses `DownloadRowCard.icon`'s 34pt geometry so folder glyphs and
  file glyphs sit on the same vertical line.
- Trailing edge: item count and summed bytes, via the existing
  `ByteFormatter.string`.
- The whole row is the hit target; a click toggles expansion.
- Uses `Theme.Palette.textPrimary` / `.textSecondary`, per change 1.
- **Not selectable.** Folder rows carry `.selectionDisabled(true)`, so a click
  toggles the folder without disturbing the current row selection, `⌘A` selects
  downloads only, and the inspector never has a folder as its target. The
  selection set stays `Set<UUID>` of download IDs — folders introduce no new
  selection type and `contextMenu(forSelectionType: UUID.self)` is unchanged.

### State

`@AppStorage("collapsedDownloadCategories")` — a comma-joined set of
`DownloadCategory.rawValue`.

Storing *collapsed* rather than expanded means a category the user has never
seen defaults to open. Storing expanded would hide every folder on first launch
and again whenever a new category first appears.

`DownloadListView.sections` (line 66) gains a `totalBytes` field alongside
`category` and `rows`. A collapsed folder's rows are left out of the view tree
entirely rather than hidden, so collapsing a large category also cheapens the
list.

### Untouched

`DownloadCategory` needs no changes — it is already pure, and
`MacgetTests/DownloadCategoryTests.swift` already covers the filename mapping.

---

## Testing

- `DownloadCategoryTests` already covers filename → category and is unaffected.
- New unit test for the collapsed-set encode/decode round trip, including the
  empty set and an unknown `rawValue` left over from a future version.
- Contrast is arithmetic, not behavior: the token values above are checked once
  here rather than asserted in a test.
- Manual verification, in light mode, with the window focused: select a row and
  confirm the filename, size, and status are all legible; collapse a folder,
  quit, relaunch, and confirm it is still collapsed.
