import Foundation

/// Parses an HTTP `Retry-After` header into a delay in seconds. The header has
/// two legal forms (RFC 9110 §10.2.3): delta-seconds (`"120"`) or an HTTP-date
/// (`"Wed, 21 Oct 2026 07:28:00 GMT"`). Pure and side-effect-free so the retry
/// path is unit-testable.
enum RetryAfter {
    /// Returns the delay in seconds relative to `now`, or `nil` if the value is
    /// absent / unparseable. A date in the past clamps to `0`.
    static func parse(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }

        // delta-seconds form.
        if let secs = TimeInterval(raw) {
            return secs >= 0 ? secs : nil
        }

        // HTTP-date form (always GMT, RFC 1123).
        if let date = httpDateFormatter.date(from: raw) {
            return max(0, date.timeIntervalSince(now))
        }
        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()
}
