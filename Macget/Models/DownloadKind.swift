import Foundation

/// Distinguishes a plain HTTP file download (handled by the chunked
/// `DownloadCoordinator`) from a media extraction (handled by `MediaExtractionJob`
/// via yt-dlp). Persisted on `Download`; defaults to `.httpFile` for older
/// queue.json entries that predate the field.
enum DownloadKind: String, Codable, Sendable {
    case httpFile
    case media
    /// BitTorrent, handled by `TorrentJob` via the shared `aria2c` daemon.
    case torrent
}
