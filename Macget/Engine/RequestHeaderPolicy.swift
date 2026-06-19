import Foundation

/// Policy for the optional per-download request headers that a captured browser
/// download carries (Cookie / Referer / User-Agent). Two concerns:
///
/// 1. **Inbound sanitation** — a browser extension is untrusted input. Strip
///    hop-by-hop headers and anything the engine controls itself (Range,
///    If-Range, Host, …) so a malicious or buggy extension can't break chunking
///    or smuggle framing headers.
/// 2. **Persistence redaction** — `Cookie`/`Authorization` are session bearer
///    secrets. They live on the in-memory `Download` for the active session but
///    must never be written to `queue.json` (the app is unsandboxed; the file is
///    readable by any process running as the user).
enum RequestHeaderPolicy {

    /// Headers the engine sets itself or that must not be forwarded. Matched
    /// case-insensitively.
    private static let denied: Set<String> = [
        // hop-by-hop (RFC 7230 §6.1)
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade",
        // engine-controlled / framing
        "range", "if-range", "host", "content-length", "accept-encoding",
    ]

    /// Header names whose values are secrets and must not be persisted.
    private static let sensitive: Set<String> = [
        "cookie", "authorization", "proxy-authorization", "set-cookie",
    ]

    /// Clean headers arriving from an extension before they reach the engine.
    /// Returns `nil` when nothing usable remains (so callers can keep the field nil).
    static func sanitizeInbound(_ headers: [String: String]?) -> [String: String]? {
        guard let headers else { return nil }
        let kept = headers.filter { !denied.contains($0.key.lowercased()) }
        return kept.isEmpty ? nil : kept
    }

    /// Drop secret-bearing headers for on-disk persistence. The in-memory copy is
    /// untouched; only the encoded form is redacted.
    static func strippingSensitive(_ headers: [String: String]?) -> [String: String]? {
        guard let headers else { return nil }
        let kept = headers.filter { !sensitive.contains($0.key.lowercased()) }
        return kept.isEmpty ? nil : kept
    }
}
