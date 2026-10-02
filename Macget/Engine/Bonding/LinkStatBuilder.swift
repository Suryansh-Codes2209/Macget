import Foundation

/// Turns the coordinator's per-link counters into display rows.
enum LinkStatBuilder {
    /// - Parameters:
    ///   - links: currently usable links involved in this download, in display order.
    ///   - knownNames: names for links that have since disappeared but still have
    ///     bytes or a status to show (so an unplugged phone reads "Link down"
    ///     rather than vanishing from the breakdown).
    /// - Returns: empty unless at least two links are involved.
    static func build(
        links: [NetworkLink],
        speeds: [String: Double],
        bytes: [String: Int64],
        connections: [String: Int],
        statuses: [String: LinkStat.Status],
        knownNames: [String: (String, NetworkLink.Kind)] = [:]
    ) -> [LinkStat] {
        var rows: [LinkStat] = links.map { link in
            LinkStat(
                linkID: link.id, displayName: link.displayName, kind: link.kind,
                speedBytesPerSec: speeds[link.id] ?? 0,
                bytesThisSession: bytes[link.id] ?? 0,
                activeConnections: connections[link.id] ?? 0,
                status: statuses[link.id] ?? .active,
                isEstimate: false
            )
        }
        let present = Set(links.map(\.id))
        // A vanished link stays listed if it carried bytes *or* has a status: a
        // link that hung before delivering anything still has to read "down".
        let vanished = Set(bytes.keys).union(statuses.keys).subtracting(present).sorted()
        for id in vanished {
            let total = bytes[id] ?? 0
            guard total > 0 || statuses[id] != nil else { continue }
            let (name, kind) = knownNames[id] ?? (id, .other)
            rows.append(LinkStat(linkID: id, displayName: name, kind: kind, speedBytesPerSec: 0,
                                 bytesThisSession: total, activeConnections: 0,
                                 status: statuses[id] ?? .down, isEstimate: false))
        }
        return rows.count >= 2 ? rows : []
    }
}
