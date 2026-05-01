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
                            Image(systemName: statusIcon(row.status))
                                .foregroundStyle(statusColor(row.status))
                                .frame(width: 14)
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

    private func statusIcon(_ status: DownloadStatus) -> String {
        switch status {
        case .queued:      return "clock"
        case .downloading: return "arrow.down.circle.fill"
        case .paused:      return "pause.circle"
        case .completed:   return "checkmark.circle.fill"
        case .failed:      return "exclamationmark.triangle.fill"
        case .cancelled:   return "xmark.circle"
        }
    }

    private func statusColor(_ status: DownloadStatus) -> Color {
        switch status {
        case .queued:      return .secondary
        case .downloading: return .blue
        case .paused:      return .orange
        case .completed:   return .green
        case .failed:      return .red
        case .cancelled:   return .gray
        }
    }
}
