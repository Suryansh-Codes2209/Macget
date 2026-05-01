import Foundation

/// Parses incoming `macget://` URLs into a target HTTP(s) URL to enqueue.
///
/// Accepted forms (both supported so users can paste either shape into a
/// bookmarklet):
///   macget://download?url=<percent-encoded-http-url>
///   macget://download/<percent-encoded-http-url>
enum MacgetURLScheme {
    static let scheme = "macget"

    static func extractDownloadURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // Form 1: ?url=… query parameter
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let item = comps.queryItems?.first(where: { $0.name.lowercased() == "url" }),
           let value = item.value,
           let target = URLValidation.parsePlausibleHTTPURL(value) {
            return target
        }

        // Form 2: macget://download/<encoded-url>
        // pathComponents: ["/", "<encoded>"] (host = "download")
        if url.host?.lowercased() == "download" {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty {
                let decoded = path.removingPercentEncoding ?? path
                if let target = URLValidation.parsePlausibleHTTPURL(decoded) {
                    return target
                }
            }
        }

        return nil
    }
}
