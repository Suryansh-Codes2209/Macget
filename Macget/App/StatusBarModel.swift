import Foundation

/// Everything the menu bar item displays, derived from the download list.
///
/// Deliberately a pure value type: the interesting decisions — what counts as
/// active, how the ring's fraction is computed, when the menu truncates — are
/// then testable without an `NSStatusItem` or a running app.
struct StatusBarModel: Equatable {

    struct Entry: Equatable, Identifiable {
        let id: UUID
        let filename: String
        /// Pre-rendered so the menu builder does no formatting of its own.
        let percentText: String
    }

    /// Beyond this the menu stops being glanceable and starts being a file list.
    static let maxEntries = 8

    /// True while anything is downloading or waiting to. Drives whether the icon
    /// draws a ring at all.
    let isActive: Bool

    /// Aggregate progress, or nil when nothing active has a known size — a
    /// server that never sent Content-Length can't contribute to a ring.
    let fractionComplete: Double?

    /// Speed shown beside the icon. Empty while idle: the icon's mere presence
    /// is what says "MacGet is running", and a permanent "0 B/s" is noise.
    let titleText: String

    let headerText: String
    let entries: [Entry]
    /// "+N more" when the active list was truncated, else nil.
    let overflowText: String?

    init(rows: [DownloadRowItem], totalSpeed: Double) {
        // Queued counts as active: the user asked for it and it is about to
        // move, so the menu bar should not claim MacGet is idle.
        let active = rows.filter { $0.status == .downloading || $0.status == .queued }

        isActive = !active.isEmpty

        // Byte-weighted, not an average of percentages — a 1 GB file at 10%
        // beside a 1 MB file at 90% is nowhere near "50% done".
        let sized = active.filter { ($0.totalBytes ?? 0) > 0 }
        let total = sized.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        let done = sized.reduce(Int64(0)) { $0 + $1.bytesDownloaded }
        fractionComplete = total > 0 ? min(1.0, Double(done) / Double(total)) : nil

        titleText = isActive ? ByteFormatter.speedString(totalSpeed) : ""

        headerText = isActive
            ? "\(active.count) downloading — \(ByteFormatter.speedString(totalSpeed))"
            : "No active downloads"

        entries = active.prefix(Self.maxEntries).map { row in
            Entry(
                id: row.id,
                filename: row.filename,
                percentText: (row.totalBytes ?? 0) > 0
                    ? "\(Int(row.fractionComplete * 100))%"
                    : "—"
            )
        }

        let hidden = active.count - entries.count
        overflowText = hidden > 0 ? "+\(hidden) more" : nil
    }
}
