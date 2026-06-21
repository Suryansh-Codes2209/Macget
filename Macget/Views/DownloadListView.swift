import SwiftUI

struct DownloadListView: View {
    @Bindable var vm: DownloadListViewModel
    @State private var selection: Set<UUID> = []
    @State private var sortOrder: [KeyPathComparator<DownloadRowItem>] = [
        .init(\.createdAt, order: .reverse)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if vm.rows.isEmpty {
                emptyState
            } else {
                Table(vm.rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Filename", value: \.filename) { row in
                        HStack(spacing: 6) {
                            fileIcon(for: row)
                            Text(row.filename).lineLimit(1).truncationMode(.middle)
                        }
                    }

                    TableColumn("Size", value: \.bytesDownloaded) { row in
                        Text(ByteFormatter.string(row.totalBytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 90)

                    TableColumn("Speed", value: \.speedBytesPerSec) { row in
                        Text(row.status == .downloading ? ByteFormatter.speedString(row.speedBytesPerSec) : "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("ETA") { row in
                        Text(row.status == .downloading ? ByteFormatter.etaString(row.etaSeconds) : "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Status") { row in
                        progressCell(for: row)
                    }
                    .width(min: 160, ideal: 220)

                    TableColumn("Threads") { row in
                        threadsCell(for: row)
                    }
                    .width(min: 90, ideal: 110)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    contextMenuItems(for: ids)
                } primaryAction: { ids in
                    if let id = ids.first, let row = vm.rows.first(where: { $0.id == id }) {
                        if row.status == .completed {
                            NSWorkspace.shared.activateFileViewerSelecting([row.destinationURL])
                        }
                    }
                }
            }

            statusBar
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.to.line.circle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No downloads yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Press ⌘N to add one.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    /// Smart file-type icon (video/audio/zip/doc/…) tinted by category, with a
    /// small status badge in the corner so state stays glanceable.
    @ViewBuilder
    private func fileIcon(for row: DownloadRowItem) -> some View {
        Image(systemName: FileTypeIcon.symbolName(for: row.filename))
            .foregroundStyle(typeColor(for: row.filename))
            .frame(width: 16)
            .overlay(alignment: .bottomTrailing) {
                if let badge = statusBadge(row.status) {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(1)
                        .background(badge.color, in: Circle())
                        .offset(x: 3, y: 2)
                }
            }
            .help(row.filename)
    }

    private func typeColor(for filename: String) -> Color {
        switch FileTypeIcon.category(for: filename) {
        case .video:    return .pink
        case .audio:    return .purple
        case .image:    return .teal
        case .archive:  return .brown
        case .pdf:      return .red
        case .document: return .blue
        case .code:     return .green
        case .app:      return .indigo
        case .disk:     return .gray
        case .generic:  return .secondary
        }
    }

    /// Corner badge for terminal/paused states. Active states (downloading,
    /// queued) return nil — their progress is shown in the Status column.
    private func statusBadge(_ status: DownloadStatus) -> (symbol: String, color: Color)? {
        switch status {
        case .completed: return ("checkmark", .green)
        case .failed:    return ("exclamationmark", .red)
        case .paused:    return ("pause.fill", .orange)
        case .cancelled: return ("xmark", .gray)
        case .downloading, .queued: return nil
        }
    }

    @ViewBuilder
    private func progressCell(for row: DownloadRowItem) -> some View {
        switch row.status {
        case .completed:
            Text("Completed").foregroundStyle(.green)
        case .failed:
            Text(row.error ?? "Failed")
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.error ?? "Failed")
        case .cancelled:
            Text("Cancelled").foregroundStyle(.secondary)
        case .queued:
            Text("Queued").foregroundStyle(.secondary)
        case .paused:
            ProgressView(value: row.fractionComplete)
                .progressViewStyle(.linear)
                .overlay(alignment: .trailing) {
                    Text(percentString(row.fractionComplete))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
        case .downloading:
            ProgressView(value: row.fractionComplete)
                .progressViewStyle(.linear)
                .overlay(alignment: .trailing) {
                    Text(percentString(row.fractionComplete))
                        .font(.caption)
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
        }
    }

    @ViewBuilder
    private func threadsCell(for row: DownloadRowItem) -> some View {
        if row.status.isTerminal {
            Text("—").foregroundStyle(.secondary).monospacedDigit()
        } else {
            HStack(spacing: 4) {
                Text("\(row.threadCount)")
                    .monospacedDigit()
                    .frame(width: 22, alignment: .trailing)
                Stepper(
                    "Threads",
                    value: Binding(
                        get: { row.threadCount },
                        set: { vm.setThreads(row.id, $0) }
                    ),
                    in: 1...Download.maxThreadCount
                )
                .labelsHidden()
                .disabled(!row.supportsRange)
            }
            .help(row.supportsRange
                  ? "Adjust parallel chunks live (1–\(Download.maxThreadCount)). Splits the largest in-flight chunk."
                  : "Server doesn't support Range requests — extra threads won't help.")
        }
    }

    @ViewBuilder
    private func contextMenuItems(for ids: Set<UUID>) -> some View {
        let rows = vm.rows.filter { ids.contains($0.id) }
        if rows.contains(where: { $0.status == .downloading || $0.status == .queued }) {
            Button("Pause") {
                rows.forEach { vm.pause($0.id) }
            }
        }
        if rows.contains(where: { $0.status == .paused || $0.status == .failed }) {
            Button("Resume") {
                rows.forEach { vm.resume($0.id) }
            }
        }
        if rows.contains(where: { !$0.status.isTerminal }) {
            Button("Cancel") {
                rows.forEach { vm.cancel($0.id) }
            }
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
        Divider()
        if rows.count == 1, let row = rows.first {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.url.absoluteString, forType: .string)
            }
            if row.status == .completed {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([row.destinationURL])
                }
            }
            Button("Copy Diagnostics") {
                vm.copyDiagnostics(row.id)
            }
        }
        Divider()
        Button("Remove from List") {
            rows.forEach { vm.remove($0.id, deleteFile: false) }
        }
        Button("Remove and Delete File", role: .destructive) {
            rows.forEach { vm.remove($0.id, deleteFile: true) }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text("Queued: \(vm.count(for: .active) - downloadingCount())")
            Text("Active: \(downloadingCount())")
            Text("Down: \(ByteFormatter.speedString(vm.totalSpeed))")
                .monospacedDigit()
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private func downloadingCount() -> Int {
        vm.rows.filter { $0.status == .downloading }.count
    }

    private func percentString(_ frac: Double) -> String {
        String(format: "%.0f%%", frac * 100)
    }
}
