import SwiftUI

/// How the download list is ordered.
///
/// Replaces the `Table`'s clickable column headers, which went away with the
/// table itself. `.queue` is the user's manual order (the drag-reorder
/// equivalent); every move action snaps back to it so a reorder is always
/// visible.
enum DownloadSortMode: String, CaseIterable, Identifiable {
    case queue, name, size, speed, dateAdded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .queue:     return "Queue Order"
        case .name:      return "Name"
        case .size:      return "Size"
        case .speed:     return "Speed"
        case .dateAdded: return "Date Added"
        }
    }

    var symbol: String {
        switch self {
        case .queue:     return "list.number"
        case .name:      return "textformat"
        case .size:      return "externaldrive"
        case .speed:     return "speedometer"
        case .dateAdded: return "clock"
        }
    }

    /// Comparators for this mode, or nil when the manual queue order applies.
    var comparators: [KeyPathComparator<DownloadRowItem>]? {
        switch self {
        case .queue:     return nil
        case .name:      return [.init(\.filename, order: .forward)]
        case .size:      return [.init(\.totalBytes, order: .reverse)]
        case .speed:     return [.init(\.speedBytesPerSec, order: .reverse)]
        case .dateAdded: return [.init(\.createdAt, order: .reverse)]
        }
    }
}

struct DownloadListView: View {
    @Bindable var vm: DownloadListViewModel
    /// Owned by `ContentView` so the Sort menu can live in the window toolbar.
    @Binding var sortMode: DownloadSortMode
    /// Also owned by `ContentView`, so the inspector can follow the selection.
    @Binding var selection: Set<UUID>
    /// Torrent whose file-selection sheet is open, if any.
    @State private var filePickerRow: DownloadRowItem?

    /// Rows in the order they should be displayed.
    private var displayRows: [DownloadRowItem] {
        guard let comparators = sortMode.comparators else { return vm.rows }
        return vm.rows.sorted(using: comparators)
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.rows.isEmpty {
                emptyState
            } else {
                list
            }

            statusBar
        }
        .background(Theme.Palette.surface)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(displayRows) { row in
                DownloadRowCard(
                    row: row,
                    isSelected: selection.contains(row.id),
                    setThreads: { vm.setThreads(row.id, $0) }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: Theme.Spacing.cardGap / 2,
                                          leading: Theme.Spacing.sectionGap,
                                          bottom: Theme.Spacing.cardGap / 2,
                                          trailing: Theme.Spacing.sectionGap))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenuItems(for: ids)
        } primaryAction: { ids in
            if let id = ids.first, let row = vm.rows.first(where: { $0.id == id }) {
                if row.status == .completed {
                    NSWorkspace.shared.activateFileViewerSelecting([row.destinationURL])
                }
            }
        }
        .sheet(item: $filePickerRow) { row in
            TorrentFilePickerSheet(
                filename: row.filename,
                files: row.torrentFiles ?? [],
                isPresented: Binding(
                    get: { filePickerRow != nil },
                    set: { if !$0 { filePickerRow = nil } }
                ),
                onApply: { indices in
                    vm.updateTorrentFileSelection(row.id, selectedIndices: indices)
                }
            )
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.progressGradient)
                .frame(width: 104, height: 104)
                .background(Theme.Palette.amber.opacity(0.10), in: Circle())
                .overlay(Circle().strokeBorder(Theme.Palette.amber.opacity(0.25), lineWidth: 1))

            Text("No downloads yet")
                .font(.title3.weight(.medium))

            Text("Paste a link, drop a file onto the window, or add one manually.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                NotificationCenter.default.post(name: .openAddDownload, object: nil)
            } label: {
                Label("Add Download", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.top, 2)

            Text("⌘N")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func contextMenuItems(for ids: Set<UUID>) -> some View {
        let rows = vm.rows.filter { ids.contains($0.id) }
        // Only offered once metadata has resolved and there's actually a choice
        // to make — a single-file torrent has nothing to pick.
        if rows.count == 1, let row = rows.first, row.isTorrent, (row.torrentFiles?.count ?? 0) > 1 {
            Button("Choose Files…") { filePickerRow = row }
            Divider()
        }
        if rows.contains(where: { $0.status == .downloading || $0.status == .queued }) {
            Button("Pause") {
                rows.forEach { vm.pause($0.id) }
            }
            .keyboardShortcut("p", modifiers: .command)
        }
        // Resume covers both paused and failed; for a failed-only selection the
        // engine path is identical, so label it "Retry" to match user intent.
        let resumable = rows.filter { $0.status == .paused || $0.status == .failed }
        if !resumable.isEmpty {
            let allFailed = resumable.allSatisfy { $0.status == .failed }
            Button(allFailed ? "Retry" : "Resume") {
                resumable.forEach { vm.resume($0.id) }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        if rows.contains(where: { !$0.status.isTerminal }) {
            Button("Cancel") {
                rows.forEach { vm.cancel($0.id) }
            }
            .keyboardShortcut(".", modifiers: .command)
        }
        let adjustable = rows.filter { $0.status == .queued || $0.status == .paused }
        if !adjustable.isEmpty {
            Menu("Priority") {
                ForEach(DownloadPriority.allCases, id: \.self) { p in
                    Button {
                        adjustable.forEach { vm.setPriority($0.id, p) }
                    } label: {
                        if adjustable.count == 1, adjustable[0].priority == p {
                            Label(p.displayName, systemImage: "checkmark")
                        } else {
                            Text(p.displayName)
                        }
                    }
                }
            }
        }

        // Manual queue reordering. Moving always re-enters queue order so the
        // change is visible even if a column sort was active. Order is honored
        // within a priority band (see DownloadScheduler.order).
        let movable = rows.filter { !$0.status.isTerminal }
        if !movable.isEmpty {
            Divider()
            Button("Move to Top") { sortMode = .queue; vm.move(ids, .top) }
            if ids.count == 1 {
                Button("Move Up") { sortMode = .queue; vm.move(ids, .up) }
                Button("Move Down") { sortMode = .queue; vm.move(ids, .down) }
            }
            Button("Move to Bottom") { sortMode = .queue; vm.move(ids, .bottom) }
            if sortMode != .queue {
                Button("Queue Order") { sortMode = .queue }
            }
        }

        Divider()
        if rows.count == 1, let row = rows.first {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.url.absoluteString, forType: .string)
            }
            Button("Copy Destination Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.destinationURL.path, forType: .string)
            }
            if row.status == .completed {
                Button("Open File") {
                    NSWorkspace.shared.open(row.destinationURL)
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([row.destinationURL])
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            Button("Copy Diagnostics") {
                vm.copyDiagnostics(row.id)
            }
        }
        Divider()
        Button("Remove from List") {
            rows.forEach { vm.remove($0.id, deleteFile: false) }
        }
        .keyboardShortcut(.delete, modifiers: [])
        Button("Remove and Delete File", role: .destructive) {
            rows.forEach { vm.remove($0.id, deleteFile: true) }
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }

    /// Chrome, not content — so glass belongs here.
    private var statusBar: some View {
        HStack(spacing: 14) {
            metric("Queued", "\(vm.count(for: .active) - downloadingCount())")
            metric("Active", "\(downloadingCount())")

            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .imageScale(.small)
                Text(ByteFormatter.speedString(vm.totalSpeed))
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.Palette.amber)
            .fontWeight(.medium)

            Spacer()

            if vm.completedCount > 0 {
                metric("Completed",
                       "\(vm.completedCount) · \(ByteFormatter.string(vm.completedBytes))")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
            Text(value).monospacedDigit().foregroundStyle(.primary)
        }
    }

    private func downloadingCount() -> Int {
        vm.rows.filter { $0.status == .downloading }.count
    }
}
