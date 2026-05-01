import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var defaultDestination: URL
    var defaultThreadCount: Int
    var maxConcurrentDownloads: Int
    var clipboardWatchEnabled: Bool
    var startDownloadsAutomatically: Bool
    var resumeOnLaunch: Bool

    init(
        defaultDestination: URL = AppSettings.systemDownloadsFolder(),
        defaultThreadCount: Int = 8,
        maxConcurrentDownloads: Int = 3,
        clipboardWatchEnabled: Bool = false,
        startDownloadsAutomatically: Bool = true,
        resumeOnLaunch: Bool = true
    ) {
        self.defaultDestination = defaultDestination
        self.defaultThreadCount = max(1, min(Download.maxThreadCount, defaultThreadCount))
        self.maxConcurrentDownloads = max(1, min(Download.maxThreadCount, maxConcurrentDownloads))
        self.clipboardWatchEnabled = clipboardWatchEnabled
        self.startDownloadsAutomatically = startDownloadsAutomatically
        self.resumeOnLaunch = resumeOnLaunch
    }

    static func systemDownloadsFolder() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}
