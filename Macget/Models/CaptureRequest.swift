import Foundation

/// A download captured by a browser extension and handed to Macget via the
/// native-messaging host (dropped as JSON into the inbox directory). The shape
/// matches the JSON the extension's service worker sends.
/// Whether a capture is a plain file download or a media (video) extraction.
enum CaptureKind: String, Codable, Sendable {
    case file
    case media
}

struct CaptureRequest: Codable, Sendable {
    let url: String
    var filename: String?
    var referer: String?
    var userAgent: String?
    var cookie: String?
    var mimeType: String?
    var totalBytes: Int64?
    var origin: String?

    /// Discriminator from the extension. Absent (`nil`) for older payloads → `.file`.
    var kind: CaptureKind?
    /// For media captures: the watch/page URL handed to yt-dlp.
    var pageURL: String?
    /// For media captures: a direct stream/manifest hint, if the extension sniffed one.
    var mediaURL: String?
    /// HLS/DASH manifest URLs sniffed on the page (best-effort hints).
    var manifestURLs: [String]?
    var formatID: String?
    var title: String?

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
