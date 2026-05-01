import Foundation

struct RangeProbeResult: Sendable {
    let totalBytes: Int64?
    let acceptsRanges: Bool
    let etag: String?
    let lastModified: String?
    let suggestedFilename: String?
    let mimeType: String?
}

enum RangeProbeError: Error, LocalizedError {
    case noResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .noResponse: return "Server did not return an HTTP response."
        case .httpStatus(let code): return "Server returned HTTP \(code)."
        }
    }
}

enum RangeProbe {
    /// Performs a HEAD request to learn `Content-Length`, `Accept-Ranges`,
    /// and validators. Falls back to a tiny `GET Range: bytes=0-0` if HEAD
    /// is rejected (some servers return 405 on HEAD).
    static func probe(url: URL, session: URLSession = URLSessionFactory.shared) async throws -> RangeProbeResult {
        // Try HEAD first.
        if let result = try? await probeHead(url: url, session: session) {
            return result
        }
        // Fallback: tiny ranged GET.
        return try await probeRangedGet(url: url, session: session)
    }

    private static func probeHead(url: URL, session: URLSession) async throws -> RangeProbeResult {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: req)
        return try parse(response: response)
    }

    private static func probeRangedGet(url: URL, session: URLSession) async throws -> RangeProbeResult {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RangeProbeError.noResponse }

        let acceptsRanges: Bool
        let totalBytes: Int64?
        if http.statusCode == 206 {
            acceptsRanges = true
            // Content-Range: bytes 0-0/12345
            if let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let total = cr.split(separator: "/").last,
               let n = Int64(total) {
                totalBytes = n
            } else {
                totalBytes = nil
            }
        } else if (200..<300).contains(http.statusCode) {
            acceptsRanges = false
            totalBytes = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        } else {
            throw RangeProbeError.httpStatus(http.statusCode)
        }

        return RangeProbeResult(
            totalBytes: totalBytes,
            acceptsRanges: acceptsRanges,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            suggestedFilename: filename(from: http, fallbackURL: url),
            mimeType: http.value(forHTTPHeaderField: "Content-Type")
        )
    }

    private static func parse(response: URLResponse) throws -> RangeProbeResult {
        guard let http = response as? HTTPURLResponse else { throw RangeProbeError.noResponse }
        guard (200..<300).contains(http.statusCode) else { throw RangeProbeError.httpStatus(http.statusCode) }

        let totalBytes: Int64? = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        let acceptsRanges = (http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes")

        return RangeProbeResult(
            totalBytes: totalBytes,
            acceptsRanges: acceptsRanges,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            suggestedFilename: filename(from: http, fallbackURL: http.url ?? URL(fileURLWithPath: "/")),
            mimeType: http.value(forHTTPHeaderField: "Content-Type")
        )
    }

    /// Extract a filename from `Content-Disposition` if present, otherwise the URL's last path component.
    private static func filename(from response: HTTPURLResponse, fallbackURL: URL) -> String? {
        if let cd = response.value(forHTTPHeaderField: "Content-Disposition") {
            // Naive parse of `filename="..."` or `filename=...`.
            let lower = cd.lowercased()
            if let range = lower.range(of: "filename=") {
                let after = cd[range.upperBound...]
                let trimmed = after.trimmingCharacters(in: .whitespaces)
                let cleaned = trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    .components(separatedBy: ";").first ?? ""
                if !cleaned.isEmpty { return cleaned }
            }
        }
        let last = fallbackURL.lastPathComponent
        return last.isEmpty ? nil : last
    }
}
