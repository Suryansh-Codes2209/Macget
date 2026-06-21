import Foundation

enum URLSessionFactory {
    /// Default shared session (no proxy, 30s request timeout). Used as the
    /// default for `RangeProbe`/tests; the engine builds its own from settings.
    /// URLSession internally pools and reuses connections per host up to
    /// `httpMaximumConnectionsPerHost`.
    nonisolated static let shared: URLSession = makeSession()

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
        // Keep TCP connections warm if the app loses focus mid-download — saves
        // a TLS handshake when we come back to the foreground.
        config.shouldUseExtendedBackgroundIdleMode = true
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
