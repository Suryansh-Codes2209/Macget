import Foundation

/// A download captured by a browser extension and handed to Macget via the
/// native-messaging host (dropped as JSON into the inbox directory). The shape
/// matches the JSON the extension's service worker sends.
struct CaptureRequest: Codable, Sendable {
    let url: String
    var filename: String?
    var referer: String?
    var userAgent: String?
    var cookie: String?
    var mimeType: String?
    var totalBytes: Int64?
    var origin: String?

    /// Build the per-download request headers from the capture. Cookies are
    /// included so authenticated downloads work; `RequestHeaderPolicy` redacts
    /// them before anything is persisted.
    var requestHeaders: [String: String] {
        var h: [String: String] = [:]
        if let referer, !referer.isEmpty { h["Referer"] = referer }
        if let userAgent, !userAgent.isEmpty { h["User-Agent"] = userAgent }
        if let cookie, !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }
}
