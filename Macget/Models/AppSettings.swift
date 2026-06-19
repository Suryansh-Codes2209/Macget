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

    init(
        defaultDestination: URL = AppSettings.systemDownloadsFolder(),
        defaultThreadCount: Int = 8,
        maxConcurrentDownloads: Int = 3,
        clipboardWatchEnabled: Bool = false,
        startDownloadsAutomatically: Bool = true,
        resumeOnLaunch: Bool = true,
        browserCaptureEnabled: Bool = false
    ) {
        self.defaultDestination = defaultDestination
        self.defaultThreadCount = max(1, min(Download.maxThreadCount, defaultThreadCount))
        self.maxConcurrentDownloads = max(1, min(Download.maxThreadCount, maxConcurrentDownloads))
        self.clipboardWatchEnabled = clipboardWatchEnabled
        self.startDownloadsAutomatically = startDownloadsAutomatically
        self.resumeOnLaunch = resumeOnLaunch
        self.browserCaptureEnabled = browserCaptureEnabled
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
    }

    static func systemDownloadsFolder() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}
