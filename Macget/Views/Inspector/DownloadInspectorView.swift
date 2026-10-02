import SwiftUI

/// The right-hand inspector: live throughput, how the transfer is split, and the
/// concurrency the engine actually settled on.
///
/// Two modes, one panel. With a row selected it's about that download; with
/// nothing selected it falls back to the aggregate, so the panel is never an
/// empty box while downloads are running.
struct DownloadInspectorView: View {
    let model: InspectorModel

    /// One label/value line in a stat grid. A struct rather than a tuple because
    /// `ForEach` needs a stable `Identifiable` element.
    private struct Stat: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let row = model.targetRow {
                    selected(row)
                } else {
                    aggregate
                }
            }
            .padding(16)
        }
        .background(Theme.Palette.surface)
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }

    // MARK: - Selected download

    @ViewBuilder
    private func selected(_ row: DownloadRowItem) -> some View {
        SpeedChartView(
            series: model.selectedSeries,
            isLive: row.status == .downloading,
            caption: row.filename,
            workers: model.inspection?.isLive == true ? model.workerSeries : nil,
            workerScale: model.inspection?.effectiveThreads ?? 1
        )

        if let inspection = model.inspection, !inspection.segments.isEmpty {
            section("Pieces", subtitle: piecesSubtitle(inspection)) {
                SegmentMapView(segments: inspection.segments,
                               isLive: inspection.isLive)
            }
        }

        section("Transfer") {
            statGrid(transferStats(row))
        }

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

        if let inspection = model.inspection {
            section("Connections", subtitle: connectionsSubtitle(inspection)) {
                statGrid(connectionStats(inspection))
            }
        }

        if row.isTorrent, let files = row.torrentFiles, !files.isEmpty {
            section("Files", subtitle: "\(files.count)") {
                filesList(files, in: row)
            }
        }

        section("Source") {
            VStack(alignment: .leading, spacing: 6) {
                detailRow("Host", row.url.host ?? row.url.absoluteString)
                detailRow("Saved to", row.destinationURL.deletingLastPathComponent().path)
            }
        }
    }

    /// What's actually inside a torrent.
    ///
    /// A torrent lands as a folder, so the row's filename names a directory and
    /// says nothing about its contents. Season packs and discographies run to
    /// hundreds of entries, so the list is capped — the inspector is a
    /// fixed-width panel, not a file browser.
    private static let fileDisplayLimit = 50

    @ViewBuilder
    private func filesList(_ files: [TorrentFileEntry], in row: DownloadRowItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(files.prefix(Self.fileDisplayLimit)) { file in
                fileRow(file, in: row)
            }
            if files.count > Self.fileDisplayLimit {
                Text("+\(files.count - Self.fileDisplayLimit) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: TorrentFileEntry, in row: DownloadRowItem) -> some View {
        let url = DownloadRowItem.resolve(file.path, under: row.destinationURL)
        let exists = FileManager.default.fileExists(atPath: url.path)
        HStack(spacing: 8) {
            Text(file.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                // A deselected file was never meant to be downloaded; dimming it
                // explains its absence rather than looking like a failure.
                .foregroundStyle(file.selected ? .primary : .secondary)
            Spacer(minLength: 8)
            Text(ByteFormatter.string(file.length))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .disabled(!exists)
            .help(exists ? "Open \(file.displayName)" : "Not downloaded")
        }
    }

    /// Piece geometry in one line — the thing that explains why a 40 GB file has
    /// pieces the size it does.
    private func piecesSubtitle(_ i: DownloadInspection) -> String? {
        guard let nominal = i.nominalSegmentBytes else { return nil }
        return "\(i.segments.count) × \(ByteFormatter.string(nominal))"
    }

    private func connectionsSubtitle(_ i: DownloadInspection) -> String? {
        i.isLive ? "\(i.activeWorkers) active" : nil
    }

    private func transferStats(_ row: DownloadRowItem) -> [Stat] {
        var stats: [Stat] = [
            Stat(label: "Downloaded", value: ByteFormatter.string(row.bytesDownloaded)),
            Stat(label: "Total", value: ByteFormatter.string(row.totalBytes)),
            Stat(label: "Progress", value: String(format: "%.1f%%", row.fractionComplete * 100)),
        ]
        if let eta = row.etaSeconds, eta > 0 {
            stats.append(Stat(label: "Time left", value: ByteFormatter.etaString(eta)))
        }
        if row.isTorrent {
            stats.append(Stat(label: "Uploaded", value: ByteFormatter.string(row.uploadedBytes)))
            stats.append(Stat(label: "Upload", value: ByteFormatter.speedString(row.uploadSpeedBytesPerSec)))
            if let seeders = row.seeders { stats.append(Stat(label: "Seeders", value: "\(seeders)")) }
            if let peers = row.peers { stats.append(Stat(label: "Peers", value: "\(peers)")) }
        }
        return stats
    }

    /// The engine's concurrency decisions, which are otherwise only visible in
    /// "Copy Diagnostics". Each line is a different reason the worker count might
    /// be lower than what the user asked for.
    private func connectionStats(_ i: DownloadInspection) -> [Stat] {
        var stats: [Stat] = []
        if i.isLive { stats.append(Stat(label: "Active now", value: "\(i.activeWorkers)")) }
        stats.append(Stat(label: "Effective", value: "\(i.effectiveThreads)"))
        stats.append(Stat(label: "Requested", value: "\(i.requestedThreads)"))
        if let cap = i.perHostCap { stats.append(Stat(label: "Host cap", value: "\(cap)")) }
        if let demoted = i.demotedTo { stats.append(Stat(label: "Demoted to", value: "\(demoted)")) }
        if i.isLive { stats.append(Stat(label: "Limited by", value: i.limitedBy.displayText)) }
        if i.splitCount > 0 { stats.append(Stat(label: "Endgame splits", value: "\(i.splitCount)")) }
        if !i.supportsRange { stats.append(Stat(label: "Range support", value: "No — single stream")) }
        return stats
    }

    // MARK: - Aggregate

    @ViewBuilder
    private var aggregate: some View {
        let active = model.activeRows

        SpeedChartView(
            series: model.totalSeries,
            isLive: !active.isEmpty,
            caption: active.isEmpty ? "Nothing downloading" : "All active downloads"
        )

        if active.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Select a download")
                    .font(.callout.weight(.medium))
                Text("Pick a row to see its pieces, connections, and speed history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            section("Active", subtitle: "\(active.count)") {
                VStack(spacing: 8) {
                    ForEach(active) { row in
                        activeRow(row)
                    }
                }
            }
        }
    }

    private func activeRow(_ row: DownloadRowItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(ByteFormatter.speedString(row.speedBytesPerSec))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.amber)
            }
            ProgressTrack(value: row.fractionComplete, height: 4)
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            content()
        }
    }

    private func statGrid(_ stats: [Stat]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(stats) { stat in
                GridRow {
                    Text(stat.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(stat.value)
                        .font(.caption)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
