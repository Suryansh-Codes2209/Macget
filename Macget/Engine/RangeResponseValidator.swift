import Foundation

/// The 206 / Content-Range checks every ranged response must pass, shared by the
/// URLSession path and the pinned-link path so the two can't drift apart.
enum RangeResponseValidator {
    /// Returns nil when the response may be streamed, else the error to raise.
    static func validate(
        status: Int,
        contentRange: String?,
        retryAfter: String?,
        expectedStart: Int64,
        expectedEnd: Int64,
        unbounded: Bool
    ) -> ChunkError? {
        if unbounded {
            // No Range was sent — any 2xx is the full body.
            return (200..<300).contains(status) ? nil : statusError(status, retryAfter: retryAfter)
        }
        if status == 200 { return .rangeRefused(200) }
        if status != 206 { return statusError(status, retryAfter: retryAfter) }
        if let contentRange {
            let expected = "bytes \(expectedStart)-\(expectedEnd)/"
            if !contentRange.hasPrefix(expected) {
                return .wrongContentRange(expected: expected + "<total>", got: contentRange)
            }
        }
        return nil
    }

    /// 429/503 carry the parsed `Retry-After`; 401/407 surface as `authRequired`.
    static func statusError(_ status: Int, retryAfter: String?) -> ChunkError {
        switch status {
        case 429, 503: return .serverBusy(code: status, retryAfter: RetryAfter.parse(retryAfter))
        case 401, 407: return .authRequired(code: status)
        default: return .unexpectedStatus(status)
        }
    }
}
