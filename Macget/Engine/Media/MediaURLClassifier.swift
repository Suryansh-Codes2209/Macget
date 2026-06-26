import Foundation

/// Decides whether a user-supplied URL should be downloaded via the video/audio
/// extractor (`DownloadKind.media` → yt-dlp) rather than as a plain HTTP file.
///
/// This is a deliberately conservative, host-based allow-list of sites that are
/// predominantly video/audio. Ambiguous hosts (facebook / twitter / reddit /
/// instagram roots) are excluded on purpose: most of their links are ordinary
/// pages that would fail a yt-dlp probe, so routing them to the picker would be
/// surprising. Extend `mediaHostSuffixes` to support more sites.
///
/// `MediaExtractionJob.needsJSRuntime(_:)` is the narrower, YouTube-only check
/// (it decides whether to fetch Deno for signature solving); this is the broader
/// "should this be a media download at all" gate.
enum MediaURLClassifier {
    /// Registrable host suffixes treated as media sources.
    static let mediaHostSuffixes: [String] = [
        "youtube.com", "youtu.be", "youtube-nocookie.com",
        "vimeo.com", "twitch.tv", "dailymotion.com", "dai.ly",
        "tiktok.com", "soundcloud.com", "streamable.com", "v.redd.it",
    ]

    /// True when `url`'s host equals or is a subdomain of an allow-listed media host.
    static func isMediaURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return mediaHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// True when `url` looks like a *playlist/collection* page rather than a single
    /// video. Deliberately conservative: a `watch?v=…&list=…` link (a video that
    /// merely sits in a playlist) is treated as a single video, since that's what
    /// the user almost always means when they share it. Only pure playlist URLs
    /// (YouTube `/playlist`, a `list=` with no `v=`, SoundCloud `/sets/`, or a
    /// generic `/playlist` path) qualify.
    static func isLikelyPlaylist(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = comps?.queryItems ?? []
        let hasList = query.contains { $0.name == "list" && !($0.value ?? "").isEmpty }
        let hasVideo = query.contains { $0.name == "v" && !($0.value ?? "").isEmpty }

        if host.contains("youtube") || host.contains("youtu.be") {
            if path == "/playlist" { return true }
            return hasList && !hasVideo
        }
        if host.contains("soundcloud") {
            return path.contains("/sets/")
        }
        return path.contains("/playlist")
    }
}
