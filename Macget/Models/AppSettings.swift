import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var defaultDestination: URL
    var defaultThreadCount: Int
    var maxConcurrentDownloads: Int
    var clipboardWatchEnabled: Bool
    var startDownloadsAutomatically: Bool
    var resumeOnLaunch: Bool
    /// When on, Macget watches its inbox directory for downloads handed off by
    /// the browser extension's native-messaging host.
    var browserCaptureEnabled: Bool
    /// When on, media captures (YouTube / video pages) are routed to the yt-dlp
    /// extractor. Off by default — requires yt-dlp/ffmpeg and a ToS acknowledgement.
    var mediaExtractionEnabled: Bool
    /// Aggregate download speed cap in bytes/sec across all active downloads.
    /// `nil` (or ≤ 0) means unlimited.
    var globalSpeedLimitBytesPerSec: Int?
    /// Post a system notification when a download completes.
    var completionNotificationsEnabled: Bool
    /// Per-request timeout (seconds) for the shared URLSession. Clamped 5...300.
    var requestTimeoutSeconds: Int
    /// Internal retry attempts per chunk worker spawn before the orchestrator
    /// respawns/demotes. Clamped 1...10.
    var maxRetriesPerChunk: Int
    /// Optional HTTP/HTTPS proxy. Both host and port must be set to take effect.
    var proxyHost: String?
    var proxyPort: Int?
    /// Media (yt-dlp) extras, applied to every video/audio download.
    var mediaWriteSubtitles: Bool
    /// Comma-separated `--sub-langs` value (e.g. "en", "en,es", "all").
    var mediaSubtitleLanguages: String
    var mediaEmbedMetadata: Bool
    var mediaWriteThumbnail: Bool
    /// When on, downloads only run inside the [start, end) quiet-hours window;
    /// outside it, active downloads are paused and auto-resumed when it reopens.
    var scheduleEnabled: Bool
    /// Minutes-from-midnight (0...1439). A window where start == end is unrestricted.
    var scheduleStartMinutes: Int
    var scheduleEndMinutes: Int
    /// When on, completed downloads are filed into a type-based subfolder
    /// (Movies / Music / Pictures / Archives / Documents / Code / Apps) of the
    /// destination. Uncategorized files stay in the destination root.
    var autoSortByType: Bool

    init(
        defaultDestination: URL = AppSettings.systemDownloadsFolder(),
        defaultThreadCount: Int = 8,
        maxConcurrentDownloads: Int = 3,
        clipboardWatchEnabled: Bool = false,
        startDownloadsAutomatically: Bool = true,
        resumeOnLaunch: Bool = true,
        browserCaptureEnabled: Bool = false,
        mediaExtractionEnabled: Bool = false,
        globalSpeedLimitBytesPerSec: Int? = nil,
        completionNotificationsEnabled: Bool = false,
        requestTimeoutSeconds: Int = 30,
        maxRetriesPerChunk: Int = 5,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        mediaWriteSubtitles: Bool = false,
        mediaSubtitleLanguages: String = "en",
        mediaEmbedMetadata: Bool = false,
        mediaWriteThumbnail: Bool = false,
        scheduleEnabled: Bool = false,
        scheduleStartMinutes: Int = 0,
        scheduleEndMinutes: Int = 0,
        autoSortByType: Bool = false
    ) {
        self.defaultDestination = defaultDestination
        self.defaultThreadCount = max(1, min(Download.maxThreadCount, defaultThreadCount))
        self.maxConcurrentDownloads = max(1, min(Download.maxThreadCount, maxConcurrentDownloads))
        self.clipboardWatchEnabled = clipboardWatchEnabled
        self.startDownloadsAutomatically = startDownloadsAutomatically
        self.resumeOnLaunch = resumeOnLaunch
        self.browserCaptureEnabled = browserCaptureEnabled
        self.mediaExtractionEnabled = mediaExtractionEnabled
        self.globalSpeedLimitBytesPerSec = globalSpeedLimitBytesPerSec.flatMap { $0 > 0 ? $0 : nil }
        self.completionNotificationsEnabled = completionNotificationsEnabled
        self.requestTimeoutSeconds = max(5, min(300, requestTimeoutSeconds))
        self.maxRetriesPerChunk = max(1, min(10, maxRetriesPerChunk))
        self.proxyHost = proxyHost.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.proxyPort = proxyPort.flatMap { (1...65535).contains($0) ? $0 : nil }
        self.mediaWriteSubtitles = mediaWriteSubtitles
        let langs = mediaSubtitleLanguages.trimmingCharacters(in: .whitespaces)
        self.mediaSubtitleLanguages = langs.isEmpty ? "en" : langs
        self.mediaEmbedMetadata = mediaEmbedMetadata
        self.mediaWriteThumbnail = mediaWriteThumbnail
        self.scheduleEnabled = scheduleEnabled
        self.scheduleStartMinutes = max(0, min(1439, scheduleStartMinutes))
        self.scheduleEndMinutes = max(0, min(1439, scheduleEndMinutes))
        self.autoSortByType = autoSortByType
    }

    /// The media extras as a value object handed to the extractor.
    var mediaOptions: MediaDownloadOptions {
        MediaDownloadOptions(
            writeSubtitles: mediaWriteSubtitles,
            subtitleLanguages: mediaSubtitleLanguages,
            embedMetadata: mediaEmbedMetadata,
            writeThumbnail: mediaWriteThumbnail
        )
    }

    // Custom decode so a settings.json written before a field existed still
    // loads (missing key → default) instead of resetting all settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        defaultDestination = try c.decodeIfPresent(URL.self, forKey: .defaultDestination) ?? defaults.defaultDestination
        defaultThreadCount = try c.decodeIfPresent(Int.self, forKey: .defaultThreadCount) ?? defaults.defaultThreadCount
        maxConcurrentDownloads = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? defaults.maxConcurrentDownloads
        clipboardWatchEnabled = try c.decodeIfPresent(Bool.self, forKey: .clipboardWatchEnabled) ?? defaults.clipboardWatchEnabled
        startDownloadsAutomatically = try c.decodeIfPresent(Bool.self, forKey: .startDownloadsAutomatically) ?? defaults.startDownloadsAutomatically
        resumeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .resumeOnLaunch) ?? defaults.resumeOnLaunch
        browserCaptureEnabled = try c.decodeIfPresent(Bool.self, forKey: .browserCaptureEnabled) ?? defaults.browserCaptureEnabled
        mediaExtractionEnabled = try c.decodeIfPresent(Bool.self, forKey: .mediaExtractionEnabled) ?? defaults.mediaExtractionEnabled
        globalSpeedLimitBytesPerSec = try c.decodeIfPresent(Int.self, forKey: .globalSpeedLimitBytesPerSec).flatMap { $0 > 0 ? $0 : nil }
        completionNotificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .completionNotificationsEnabled) ?? defaults.completionNotificationsEnabled
        requestTimeoutSeconds = max(5, min(300, try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? defaults.requestTimeoutSeconds))
        maxRetriesPerChunk = max(1, min(10, try c.decodeIfPresent(Int.self, forKey: .maxRetriesPerChunk) ?? defaults.maxRetriesPerChunk))
        proxyHost = (try c.decodeIfPresent(String.self, forKey: .proxyHost)).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        proxyPort = (try c.decodeIfPresent(Int.self, forKey: .proxyPort)).flatMap { (1...65535).contains($0) ? $0 : nil }
        mediaWriteSubtitles = try c.decodeIfPresent(Bool.self, forKey: .mediaWriteSubtitles) ?? defaults.mediaWriteSubtitles
        let langs = (try c.decodeIfPresent(String.self, forKey: .mediaSubtitleLanguages) ?? defaults.mediaSubtitleLanguages).trimmingCharacters(in: .whitespaces)
        mediaSubtitleLanguages = langs.isEmpty ? "en" : langs
        mediaEmbedMetadata = try c.decodeIfPresent(Bool.self, forKey: .mediaEmbedMetadata) ?? defaults.mediaEmbedMetadata
        mediaWriteThumbnail = try c.decodeIfPresent(Bool.self, forKey: .mediaWriteThumbnail) ?? defaults.mediaWriteThumbnail
        scheduleEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? defaults.scheduleEnabled
        scheduleStartMinutes = max(0, min(1439, try c.decodeIfPresent(Int.self, forKey: .scheduleStartMinutes) ?? defaults.scheduleStartMinutes))
        scheduleEndMinutes = max(0, min(1439, try c.decodeIfPresent(Int.self, forKey: .scheduleEndMinutes) ?? defaults.scheduleEndMinutes))
        autoSortByType = try c.decodeIfPresent(Bool.self, forKey: .autoSortByType) ?? defaults.autoSortByType
    }

    static func systemDownloadsFolder() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}
