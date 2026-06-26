import Foundation

/// One selectable format from `yt-dlp -J`. Only the fields we use are decoded;
/// yt-dlp emits many more, which Codable ignores.
struct MediaFormat: Codable, Sendable, Identifiable, Equatable {
    let formatID: String
    let ext: String?
    let height: Int?
    let width: Int?
    let fps: Double?
    let tbr: Double?            // total bitrate, kbit/s
    let vcodec: String?
    let acodec: String?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let formatNote: String?

    var id: String { formatID }

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case ext, height, width, fps, tbr, vcodec, acodec
        case filesize
        case filesizeApprox = "filesize_approx"
        case formatNote = "format_note"
    }

    var hasVideo: Bool { let v = vcodec ?? "none"; return v != "none" && !v.isEmpty }
    var hasAudio: Bool { let a = acodec ?? "none"; return a != "none" && !a.isEmpty }

    /// Best size estimate available (exact preferred, else approximate).
    var estimatedBytes: Int64? { filesize ?? filesizeApprox }

    /// Human label for a format picker, e.g. "1080p · mp4 · 148 MB".
    var displayLabel: String {
        var parts: [String] = []
        if let height { parts.append("\(height)p") }
        else if hasAudio && !hasVideo { parts.append("audio only") }
        if let ext { parts.append(ext) }
        if let estimatedBytes { parts.append(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)) }
        else if let formatNote { parts.append(formatNote) }
        return parts.isEmpty ? formatID : parts.joined(separator: " · ")
    }
}

/// Top-level `yt-dlp -J` object for a single (non-playlist) video.
struct MediaInfo: Codable, Sendable {
    let title: String?
    let ext: String?
    let formats: [MediaFormat]?
    let isLive: Bool?

    enum CodingKeys: String, CodingKey {
        case title, ext, formats
        case isLive = "is_live"
    }

    /// Progressive (muxed) + adaptive formats that carry video, sorted by height
    /// descending — what a quality picker should show.
    var videoFormats: [MediaFormat] {
        (formats ?? [])
            .filter { $0.hasVideo }
            .sorted { ($0.height ?? 0, $0.tbr ?? 0) > ($1.height ?? 0, $1.tbr ?? 0) }
    }

    /// One curated picker option per distinct resolution (best bitrate kept),
    /// plus an "Audio only" choice when audio formats exist.
    var pickerOptions: [MediaPickOption] {
        var seen = Set<Int>()
        var opts: [MediaPickOption] = []
        for f in videoFormats {
            guard let h = f.height, !seen.contains(h) else { continue }
            seen.insert(h)
            let size = f.estimatedBytes.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            let ext = f.ext.map { " · \($0)" } ?? ""
            // Adaptive (video-only) needs bestaudio merged; progressive already has it.
            let selector = f.hasAudio ? f.formatID : "\(f.formatID)+bestaudio/\(f.formatID)"
            opts.append(MediaPickOption(id: f.formatID, label: "\(h)p\(ext)\(size)", selector: selector))
        }
        if (formats ?? []).contains(where: { $0.hasAudio && !$0.hasVideo }) {
            opts.append(MediaPickOption(id: "audio", label: "Audio only", selector: "bestaudio/best"))
        }
        return opts
    }
}

/// A single user-facing quality choice in the download picker, mapped to a
/// yt-dlp `-f` selector.
struct MediaPickOption: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let selector: String
}

/// Optional extras applied to every media (yt-dlp) download. Sourced from global
/// Settings (`AppSettings.mediaOptions`) so the user sets them once.
struct MediaDownloadOptions: Sendable, Equatable {
    var writeSubtitles: Bool = false
    /// Comma-separated yt-dlp `--sub-langs` value (e.g. "en", "en,es", "all").
    var subtitleLanguages: String = "en"
    var embedMetadata: Bool = false
    var writeThumbnail: Bool = false

    static let none = MediaDownloadOptions()

    var isDefault: Bool { self == .none }
}

/// A generic, format-probe-free quality applied to every entry of a playlist
/// download. (Per-entry quality picking would require probing each video, which
/// is too slow for large playlists.)
enum MediaPlaylistQuality: String, CaseIterable, Identifiable, Sendable {
    case best, hd1080, hd720, audio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best:   return "Best available"
        case .hd1080: return "Up to 1080p"
        case .hd720:  return "Up to 720p"
        case .audio:  return "Audio only"
        }
    }

    var selector: String {
        switch self {
        case .best:   return "bestvideo*+bestaudio/best"
        case .hd1080: return "bestvideo[height<=1080]+bestaudio/best[height<=1080]/best"
        case .hd720:  return "bestvideo[height<=720]+bestaudio/best[height<=720]/best"
        case .audio:  return "bestaudio/best"
        }
    }
}

/// One entry of a `yt-dlp --flat-playlist -J` result. flat extraction is cheap
/// (no per-video format probing) — enough to list a playlist and fan it out into
/// individual media downloads.
struct PlaylistEntry: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String?
    let url: String?

    enum CodingKeys: String, CodingKey { case id, title, url }

    /// Best-effort absolute page URL for this entry. flat-playlist `url` is usually
    /// already absolute; for bare IDs we reconstruct a watch URL on the playlist's
    /// host (YouTube), else resolve relative to the playlist URL.
    func resolvedURL(relativeTo playlistURL: URL) -> URL? {
        if let url, let u = URL(string: url), (u.scheme ?? "").hasPrefix("http") {
            return u
        }
        let host = (playlistURL.host ?? "").lowercased()
        if host.contains("youtube") || host.contains("youtu.be") {
            return URL(string: "https://www.youtube.com/watch?v=\(id)")
        }
        if let url { return URL(string: url, relativeTo: playlistURL)?.absoluteURL }
        return nil
    }
}

/// Top-level object of a `yt-dlp --flat-playlist -J` result for a playlist URL.
/// A non-playlist URL decodes with `entries == nil`.
struct PlaylistProbe: Codable, Sendable {
    let title: String?
    let entries: [PlaylistEntry]?

    enum CodingKeys: String, CodingKey { case title, entries }
}
