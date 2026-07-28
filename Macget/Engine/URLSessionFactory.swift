import Foundation

enum URLSessionFactory {
    /// Default shared session (no proxy, 30s request timeout). Used as the
    /// default for `RangeProbe`/tests; the engine builds its own from settings.
    /// URLSession internally pools and reuses connections per host up to
    /// `httpMaximumConnectionsPerHost`.
    nonisolated static let shared: URLSession = makeSession()

    /// Session for short, interactive metadata requests — OPDS catalog feeds and
    /// the like.
    ///
    /// Deliberately *not* `shared`: that session sets `waitsForConnectivity = true`
    /// and `timeoutIntervalForResource = .infinity`, which is correct for a
    /// multi-gigabyte download and wrong for anything a spinner is waiting on. A
    /// dead catalog URL must surface an error in seconds, not hang the browser.
    nonisolated static let metadata: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    /// Builds a configured session. The engine rebuilds one of these when the
    /// proxy or request-timeout setting changes.
    nonisolated static func makeSession(
        requestTimeout: TimeInterval = 30,
        proxyHost: String? = nil,
        proxyPort: Int? = nil
    ) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = Download.maxThreadCount
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = .infinity
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Signal latency-sensitive interactive data so macOS doesn't deprioritize
        // network IO when the app is backgrounded.
        config.networkServiceType = .responsiveData
        // (We used to set `shouldUseExtendedBackgroundIdleMode = true` to keep TCP
        // connections warm across loss of focus. Apple deprecated it in macOS 15.4
        // with "Not supported" — there is no replacement API; the system now
        // manages connection idle behavior itself, and URLSession's own per-host
        // connection pooling + `waitsForConnectivity` already cover the intent.)
        // HTTP/3 (QUIC) is opted into per-request via `URLRequest.assumesHTTP3Capable`
        // (see `applyTransportPreferences`) — there's no session-level switch.
        // (Multipath TCP — `multipathServiceType` — is iOS-only; not available on
        // macOS URLSession, so network-change resilience is handled at the engine
        // level via auto-resume instead.)
        if let dict = proxyDictionary(host: proxyHost, port: proxyPort) {
            config.connectionProxyDictionary = dict
        }
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent
        ]
        return URLSession(configuration: config)
    }

    /// Routes both HTTP and HTTPS (CONNECT) traffic through `host:port`. Returns
    /// nil when either is missing so callers can leave the proxy unset.
    nonisolated static func proxyDictionary(host: String?, port: Int?) -> [AnyHashable: Any]? {
        guard let host, !host.isEmpty, let port, port > 0 else { return nil }
        return [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
    }

    /// Per-request transport opt-ins. `assumesHTTP3Capable` lets URLSession try
    /// HTTP/3 on the first request to an origin instead of waiting to discover
    /// Alt-Svc on a prior HTTP/2 response; it falls back cleanly when the server
    /// isn't QUIC-capable. Call on every request the engine issues.
    nonisolated static func applyTransportPreferences(to request: inout URLRequest) {
        request.assumesHTTP3Capable = true
    }

    nonisolated static let userAgent: String = {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        return "Macget/\(appVersion) (macOS \(osVersion.majorVersion).\(osVersion.minorVersion))"
    }()
}
