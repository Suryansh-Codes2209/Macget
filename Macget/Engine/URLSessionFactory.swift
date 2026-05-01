import Foundation

enum URLSessionFactory {
    /// Single shared session for the whole app. URLSession internally pools and
    /// reuses connections per host up to `httpMaximumConnectionsPerHost`.
    nonisolated static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = Download.maxThreadCount
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = .infinity
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Signal latency-sensitive interactive data so macOS doesn't deprioritize
        // network IO when the app is backgrounded.
        config.networkServiceType = .responsiveData
        // Keep TCP connections warm if the app loses focus mid-download — saves
        // a TLS handshake when we come back to the foreground.
        config.shouldUseExtendedBackgroundIdleMode = true
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent
        ]
        return URLSession(configuration: config)
    }()

    nonisolated static let userAgent: String = {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        return "Macget/\(appVersion) (macOS \(osVersion.majorVersion).\(osVersion.minorVersion))"
    }()
}
