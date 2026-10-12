import Foundation

/// The public trackers MacGet adds to non-private torrents, and the gate that
/// decides when not to.
///
/// The list is compiled in rather than fetched. A live list (ngosang/trackerslist
/// and friends) never goes stale, but it would also mean whatever that file says
/// tomorrow is where MacGet announces the user's torrents. Staleness between
/// releases is the accepted price of keeping that decision inside the app.
enum TorrentTrackers {

    /// Long-lived, high-availability public trackers. Deliberately short: past a
    /// handful, extra announces cost more than the peers they return.
    static let bundled: [String] = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.tracker.cl:1337/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
    ]

    /// The `bt-tracker` value for one download, or nil when nothing should be
    /// injected. Passed per-download on `aria2.addUri`/`aria2.addTorrent` — never
    /// as a global launch flag, because the decision is per torrent.
    static func option(isPrivate: Bool, enabled: Bool) -> String? {
        guard enabled, !isPrivate else { return nil }
        return bundled.joined(separator: ",")
    }

    /// Where aria2 saves a magnet's metadata once BEP-9 resolves it. MacGet
    /// passes `--bt-save-metadata=true`, so this file appears beside the data
    /// and is the only way to read a magnet's `private` flag.
    static func metainfoURL(infoHash: String, in folder: URL) -> URL {
        folder.appendingPathComponent("\(infoHash).torrent")
    }
}
