import Foundation

/// One HTTP GET over a specific network link.
///
/// URLSession can't pin a request to an interface on macOS, so workers assigned
/// to a non-default link use this instead. Kept to the narrow job the engine
/// needs — ranged GETs — so its failure mode is "that link isn't used", never a
/// failed download.
protocol PinnedTransport: Sendable {
    /// Returns once the response head has arrived. The body streams afterwards.
    func get(url: URL, headers: [(String, String)], linkID: String) async throws -> PinnedResponse
}

struct PinnedResponse: Sendable {
    let head: HTTPResponseHead
    let body: AsyncThrowingStream<Data, Error>
}

enum PinnedTransportError: Error, LocalizedError, Equatable {
    case unsupportedURL
    case interfaceUnavailable(String)
    case tlsFailed(String)
    case connectionFailed(String)
    case closedBeforeResponse

    var isTLS: Bool {
        if case .tlsFailed = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedURL: return "Only http and https downloads can use extra links."
        case .interfaceUnavailable(let id): return "Network link \(id) is no longer available."
        case .tlsFailed(let detail): return "Secure connection failed on this link: \(detail)"
        case .connectionFailed(let detail): return "Connection failed on this link: \(detail)"
        case .closedBeforeResponse: return "The server closed the connection before responding."
        }
    }
}

/// Serializes an HTTP/1.1 GET.
enum PinnedRequest {
    static func bytes(url: URL, headers: [(String, String)]) -> Data? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true) { target += "?" + query }

        let scheme = url.scheme?.lowercased() ?? "https"
        let defaultPort = scheme == "https" ? 443 : 80
        let hostHeader = (url.port.map { $0 != defaultPort } ?? false) ? "\(host):\(url.port!)" : host

        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        }

        var text = "GET \(target) HTTP/1.1\r\nHost: \(hostHeader)\r\n"
        for (name, value) in headers {
            let n = clean(name)
            if n.caseInsensitiveCompare("Host") == .orderedSame || n.caseInsensitiveCompare("Connection") == .orderedSame { continue }
            text += "\(n): \(clean(value))\r\n"
        }
        text += "Connection: keep-alive\r\n\r\n"
        return Data(text.utf8)
    }
}
