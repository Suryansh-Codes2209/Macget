import Foundation

/// Live per-link throughput for one download (or, aggregated, for all of them).
/// Never persisted — like `DownloadSnapshot.speedBytesPerSec`, it only means
/// something while bytes are moving.
struct LinkStat: Sendable, Equatable, Identifiable {
    enum Status: String, Sendable {
        case active
        /// The server refused this link's IP (signed URL, different edge, TLS…).
        case rejectedByServer
        /// The link went away or failed repeatedly during this download.
        case down
    }

    let linkID: String
    let displayName: String
    let kind: NetworkLink.Kind
    let speedBytesPerSec: Double
    let bytesThisSession: Int64
    let activeConnections: Int
    let status: Status
    /// True for torrents when several share the daemon and the split is apportioned.
    let isEstimate: Bool

    var id: String { linkID }

    /// Sums per-link stats across downloads for the global strip and menu bar.
    /// Empty unless at least two links are actually carrying bytes — a single
    /// link has nothing to break down.
    static func aggregate(_ perDownload: [[LinkStat]]) -> [LinkStat] {
        var order: [String] = []
        var byID: [String: LinkStat] = [:]
        for stats in perDownload {
            for s in stats {
                if let prev = byID[s.linkID] {
                    byID[s.linkID] = LinkStat(
                        linkID: s.linkID, displayName: prev.displayName, kind: prev.kind,
                        speedBytesPerSec: prev.speedBytesPerSec + s.speedBytesPerSec,
                        bytesThisSession: prev.bytesThisSession + s.bytesThisSession,
                        activeConnections: prev.activeConnections + s.activeConnections,
                        status: .active,
                        isEstimate: prev.isEstimate || s.isEstimate
                    )
                } else {
                    order.append(s.linkID)
                    byID[s.linkID] = LinkStat(
                        linkID: s.linkID, displayName: s.displayName, kind: s.kind,
                        speedBytesPerSec: s.speedBytesPerSec, bytesThisSession: s.bytesThisSession,
                        activeConnections: s.activeConnections, status: .active, isEstimate: s.isEstimate
                    )
                }
            }
        }
        let result = order.compactMap { byID[$0] }
            .sorted { (LinkFilter.rank($0.kind), $0.linkID) < (LinkFilter.rank($1.kind), $1.linkID) }
        guard result.filter({ $0.speedBytesPerSec > 0 }).count >= 2 else { return [] }
        return result
    }
}
