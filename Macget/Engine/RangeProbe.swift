import Foundation

struct RangeProbeResult: Sendable {
    let totalBytes: Int64?
    let acceptsRanges: Bool
    let etag: String?
    let lastModified: String?
    /// Filename parsed *only* from the `Content-Disposition` header. `nil` when
    /// the header is absent — distinguishes "the server told us a name" from a
    /// name guessed off the URL path (which is junk for signed/CDN links).
    let contentDispositionFilename: String?
    /// Best-effort filename: `contentDispositionFilename` if present, else the
    /// (possibly redirected) URL's last path component.
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
    static func probe(
        url: URL,
        headers: [String: String]? = nil,
        session: URLSession = URLSessionFactory.shared
    ) async throws -> RangeProbeResult {
        // Try HEAD first.
        if let result = try? await probeHead(url: url, headers: headers, session: session) {
            return result
        }
        // Fallback: tiny ranged GET.
        return try await probeRangedGet(url: url, headers: headers, session: session)
    }

    private static func probeHead(url: URL, headers: [String: String]?, session: URLSession) async throws -> RangeProbeResult {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        apply(headers, to: &req)
        let (_, response) = try await session.data(for: req)
        return try parse(response: response)
    }

    private static func probeRangedGet(url: URL, headers: [String: String]?, session: URLSession) async throws -> RangeProbeResult {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        apply(headers, to: &req)
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

        let cd = parseContentDispositionFilename(http.value(forHTTPHeaderField: "Content-Disposition"))
        return RangeProbeResult(
            totalBytes: totalBytes,
            acceptsRanges: acceptsRanges,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            contentDispositionFilename: cd,
            suggestedFilename: cd ?? urlFilename(url),
            mimeType: http.value(forHTTPHeaderField: "Content-Type")
        )
    }

    private static func parse(response: URLResponse) throws -> RangeProbeResult {
        guard let http = response as? HTTPURLResponse else { throw RangeProbeError.noResponse }
        guard (200..<300).contains(http.statusCode) else { throw RangeProbeError.httpStatus(http.statusCode) }

        let totalBytes: Int64? = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        let acceptsRanges = (http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes")

        let cd = parseContentDispositionFilename(http.value(forHTTPHeaderField: "Content-Disposition"))
        return RangeProbeResult(
            totalBytes: totalBytes,
            acceptsRanges: acceptsRanges,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            contentDispositionFilename: cd,
            suggestedFilename: cd ?? urlFilename(http.url ?? URL(fileURLWithPath: "/")),
            mimeType: http.value(forHTTPHeaderField: "Content-Type")
        )
    }

    /// Apply caller-supplied headers (e.g. Cookie/Referer/User-Agent from a
    /// captured browser download) to a request. Callers set `Range` afterward so
    /// the probe's own range always wins.
    private static func apply(_ headers: [String: String]?, to req: inout URLRequest) {
        URLSessionFactory.applyTransportPreferences(to: &req)
        guard let headers else { return }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    }

    /// Parse a filename out of a `Content-Disposition` header value. Pure and
    /// header-only (no URL fallback) so the result distinguishes a
    /// server-provided name from a URL guess. Returns `nil` when absent/empty.
    ///
    /// The RFC 5987 extended form (`filename*=UTF-8''…`) takes precedence over
    /// the plain `filename=` form when both are present, because it can carry
    /// non-ASCII names that the plain form mangles.
    static func parseContentDispositionFilename(_ headerValue: String?) -> String? {
        guard let cd = headerValue else { return nil }
        if let ext = parseExtendedFilename(cd) { return ext }
        // Naive parse of `filename="..."` or `filename=...`.
        let lower = cd.lowercased()
        guard let range = lower.range(of: "filename=") else { return nil }
        let after = cd[range.upperBound...]
        let trimmed = after.trimmingCharacters(in: .whitespaces)
        let cleaned = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .components(separatedBy: ";").first ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Parses the RFC 5987 `filename*=charset'lang'pct-encoded` extended form.
    /// Percent-decoding interprets the bytes as UTF-8 (the only charset in real
    /// use); other charsets fall back to the same decode. Returns `nil` when the
    /// header has no extended form.
    private static func parseExtendedFilename(_ cd: String) -> String? {
        let lower = cd.lowercased()
        guard let r = lower.range(of: "filename*=") else { return nil }
        let after = cd[r.upperBound...]
        let value = (after.components(separatedBy: ";").first ?? "")
            .trimmingCharacters(in: .whitespaces)
        // Strip the optional `charset'lang'` prefix, keeping the encoded name.
        let parts = value.components(separatedBy: "'")
        let encoded = parts.count >= 3 ? parts[2...].joined(separator: "'") : value
        guard let decoded = encoded.removingPercentEncoding, !decoded.isEmpty else { return nil }
        return decoded
    }

    private static func urlFilename(_ url: URL) -> String? {
        let last = url.lastPathComponent
        return last.isEmpty ? nil : last
    }
}
