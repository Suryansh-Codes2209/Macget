import Foundation

enum ChunkError: Error, LocalizedError {
    case noHttpResponse
    case unexpectedStatus(Int)
    case rangeRefused(Int)
    case wrongContentRange(expected: String, got: String)
    case writerUnavailable
    case chunkNotFound
    /// Server asked us to back off (429 / 503). `retryAfter` is the parsed
    /// `Retry-After` delay in seconds when the server supplied one. Retryable.
    case serverBusy(code: Int, retryAfter: TimeInterval?)
    /// Server demands credentials (401) or proxy auth (407) we don't have (or the
    /// stored ones were rejected). Non-retryable; the engine prompts the user.
    case authRequired(code: Int)
    /// A pinned (non-default) link was refused by the server or can't serve this
    /// file — drop the link for this download. Never fails the download.
    case linkRejected(linkID: String, serverRefused: Bool)
    /// A pinned link's connection failed. Counts as a strike against the link;
    /// the piece goes straight back to the pool rather than backing off.
    case linkTransport(linkID: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .noHttpResponse: return "Server did not return an HTTP response."
        case .unexpectedStatus(let c): return "Unexpected HTTP status \(c)."
        case .rangeRefused(let c): return "Server refused Range request (HTTP \(c))."
        case .wrongContentRange(let e, let g): return "Server returned wrong Content-Range. Expected \(e), got \(g)."
        case .writerUnavailable: return "File writer unavailable."
        case .chunkNotFound: return "Chunk not found in download."
        case .serverBusy(let c, let ra):
            if let ra { return "Server busy (HTTP \(c)); retrying in \(Int(ra.rounded()))s." }
            return "Server busy (HTTP \(c)); will retry."
        case .authRequired(let c):
            return c == 407
                ? "Proxy authentication required."
                : "This download requires a username and password."
        case .linkRejected(let id, let refused):
            return refused ? "Server refused connections over \(id)." : "Network link \(id) is unusable for this download."
        case .linkTransport(let id, let detail):
            return "Connection over \(id) failed: \(detail)"
        }
    }
}

struct PinnedRoute: Sendable {
    let linkID: String
    let transport: any PinnedTransport
}

/// Streams a single byte-range from `request.url` into `writer` once. Retries
/// are the coordinator's responsibility — this struct does ONE attempt.
struct ChunkWorker {
    let chunk: Chunk
    let url: URL
    let etag: String?
    let lastModified: String?
    let writer: FileWriter
    let session: URLSession
    /// Optional caller-supplied headers (Cookie/Referer/User-Agent) for captured
    /// browser downloads. Applied before Range/If-Range so the worker's range wins.
    var headers: [String: String]? = nil
    /// When true, issue a plain `GET` (no `Range`/`If-Range`) and stream the whole
    /// body to EOF. Used for servers that never report a size (no `Content-Length`,
    /// chunked transfer, HEAD-blocked) where ranged chunking isn't possible.
    var unbounded: Bool = false
    /// Optional shared bandwidth limiter. When set, the worker waits on it after
    /// each write so aggregate throughput stays under the user's cap.
    var rateLimiter: RateLimiter? = nil
    /// Optional credential for HTTP Basic/Digest/NTLM challenges on this host.
    var credential: URLCredential? = nil
    /// When set, this attempt runs over a specific network link through the
    /// pinned transport instead of URLSession. Never set for unbounded streams.
    var pinned: PinnedRoute? = nil
    /// URLSession path only: called with the local IP the connection used, so
    /// the coordinator can attribute default-link bytes to the right interface.
    var onLocalAddress: (@Sendable (String) -> Void)? = nil
    /// Called periodically with bytes flushed to disk for this chunk.
    let report: @Sendable (UUID, Int) async -> Void

    /// Per-write buffer size. Workers accumulate small Data deliveries from the
    /// URLSession delegate into 64 KB writes.
    static let writeBufferBytes = 64 * 1024

    func run() async throws {
        if chunk.isComplete && !unbounded { return }

        let requestStart = chunk.nextWriteOffset

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        URLSessionFactory.applyTransportPreferences(to: &req)
        if let headers {
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        }

        if unbounded {
            // No Range: pull the entire body in one connection and append to EOF.
            try await stream(request: req, expectedStart: requestStart, expectedEnd: .max, startingOffset: requestStart, unbounded: true)
            return
        }

        let requestEnd = chunk.endByte
        guard requestStart <= requestEnd else { return }
        req.setValue("bytes=\(requestStart)-\(requestEnd)", forHTTPHeaderField: "Range")
        if let etag {
            req.setValue(etag, forHTTPHeaderField: "If-Range")
        } else if let lastModified {
            req.setValue(lastModified, forHTTPHeaderField: "If-Range")
        }

        if let pinned {
            try await streamPinned(route: pinned, request: req, expectedStart: requestStart, expectedEnd: requestEnd)
        } else {
            try await stream(request: req, expectedStart: requestStart, expectedEnd: requestEnd, startingOffset: requestStart, unbounded: false)
        }
    }

    private func stream(request: URLRequest, expectedStart: Int64, expectedEnd: Int64, startingOffset: Int64, unbounded: Bool) async throws {
        let delegate = StreamingDelegate()
        delegate.credential = credential
        delegate.onLocalAddress = onLocalAddress
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            delegate.attach(continuation: continuation, expectedRangeStart: expectedStart, expectedRangeEnd: expectedEnd, unbounded: unbounded)
            let task = session.dataTask(with: request)
            task.delegate = delegate
            // Tell URLSession's scheduler this task matters more than the default,
            // so when bandwidth is contested (e.g. another app streaming video) our
            // chunks aren't the first to back off.
            task.priority = URLSessionTask.highPriority
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
        try await write(stream, startingOffset: startingOffset, expectedEnd: expectedEnd, unbounded: unbounded)
    }

    static let maxRedirects = 5

    /// The pinned-link equivalent of `stream`. Every failure is translated so it
    /// can only ever cost this download the link, never the download itself.
    private func streamPinned(route: PinnedRoute, request: URLRequest, expectedStart: Int64, expectedEnd: Int64) async throws {
        var headers: [(String, String)] = (request.allHTTPHeaderFields ?? [:]).map { ($0.key, $0.value) }
        if !headers.contains(where: { $0.0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            headers.append(("User-Agent", URLSessionFactory.userAgent))
        }
        headers.append(("Accept-Encoding", "identity"))
        // Preemptive Basic only over TLS — never send a password in the clear.
        // Skipped when the caller already captured an Authorization header.
        if let credential, let user = credential.user, let password = credential.password,
           request.url?.scheme?.lowercased() == "https",
           !headers.contains(where: { $0.0.caseInsensitiveCompare("Authorization") == .orderedSame }) {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            headers.append(("Authorization", "Basic \(token)"))
        }

        guard var url = request.url, let originalURL = request.url else { throw ChunkError.linkRejected(linkID: route.linkID, serverRefused: false) }
        var response: PinnedResponse
        var redirects = 0
        while true {
            do {
                response = try await route.transport.get(url: url, headers: headers, linkID: route.linkID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PinnedTransportError where error.isTLS {
                throw ChunkError.linkRejected(linkID: route.linkID, serverRefused: false)
            } catch PinnedTransportError.unsupportedURL {
                throw ChunkError.linkRejected(linkID: route.linkID, serverRefused: false)
            } catch PinnedTransportError.interfaceUnavailable {
                throw ChunkError.linkRejected(linkID: route.linkID, serverRefused: false)
            } catch {
                throw ChunkError.linkTransport(linkID: route.linkID, detail: error.localizedDescription)
            }
            let status = response.head.status
            guard [301, 302, 303, 307, 308].contains(status) else { break }
            guard redirects < Self.maxRedirects,
                  let location = response.head.value("location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL
            else { throw ChunkError.linkRejected(linkID: route.linkID, serverRefused: true) }
            // Never downgrade TLS, and never carry credentials or cookies to a
            // different origin than the one the caller asked for.
            if url.scheme?.lowercased() == "https", next.scheme?.lowercased() != "https" {
                throw ChunkError.linkRejected(linkID: route.linkID, serverRefused: true)
            }
            if !Self.sameOrigin(next, originalURL) {
                headers.removeAll { ["authorization", "cookie"].contains($0.0.lowercased()) }
            }
            redirects += 1
            url = next
        }

        if let error = RangeResponseValidator.validate(
            status: response.head.status,
            contentRange: response.head.value("content-range"),
            retryAfter: response.head.value("retry-after"),
            expectedStart: expectedStart,
            expectedEnd: expectedEnd,
            unbounded: false
        ) {
            throw Self.pinnedFailure(error, linkID: route.linkID)
        }

        let linkID = route.linkID
        let body = response.body
        let translated = AsyncThrowingStream<Data, Error> { continuation in
            let pump = Task {
                do {
                    for try await data in body { continuation.yield(data) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: ChunkError.linkTransport(linkID: linkID, detail: error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
        try await write(translated, startingOffset: expectedStart, expectedEnd: expectedEnd, unbounded: false)
    }

    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && a.port == b.port
    }

    /// Validation failures on a pinned link mean "this link can't serve this
    /// file" — a signed URL bound to the other IP, a different CDN edge, auth the
    /// pinned transport can't do. Only transient server states stay retryable.
    static func pinnedFailure(_ error: ChunkError, linkID: String) -> ChunkError {
        switch error {
        case .rangeRefused, .wrongContentRange, .authRequired:
            return .linkRejected(linkID: linkID, serverRefused: true)
        case .unexpectedStatus(let code) where (300..<500).contains(code):
            return .linkRejected(linkID: linkID, serverRefused: true)
        default:
            return error
        }
    }

    /// Buffers deliveries into 64 KB writes at increasing offsets.
    private func write(_ stream: AsyncThrowingStream<Data, Error>, startingOffset: Int64, expectedEnd: Int64, unbounded: Bool) async throws {
        var offset = startingOffset
        var buffer = Data()
        buffer.reserveCapacity(Self.writeBufferBytes)
        // Guard against `expectedEnd + 1` overflowing for the unbounded sentinel.
        let chunkEndExclusive = (expectedEnd == .max) ? Int64.max : expectedEnd + 1

        for try await piece in stream {
            try Task.checkCancellation()

            let usable: Data
            if unbounded {
                // Unknown total size — take everything the server sends.
                usable = piece
            } else {
                // Don't write past the chunk end if server over-reads.
                let allowedRemaining = chunkEndExclusive - (offset + Int64(buffer.count))
                if allowedRemaining <= 0 { break }
                usable = (Int64(piece.count) > allowedRemaining)
                    ? piece.prefix(Int(allowedRemaining))
                    : piece
            }
            buffer.append(usable)

            if buffer.count >= Self.writeBufferBytes {
                let toWrite = buffer
                try await writer.write(toWrite, at: offset)
                offset += Int64(toWrite.count)
                await report(chunk.id, toWrite.count)
                await rateLimiter?.consume(toWrite.count)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            let toWrite = buffer
            try await writer.write(toWrite, at: offset)
            await report(chunk.id, toWrite.count)
            await rateLimiter?.consume(toWrite.count)
        }
    }
}

/// Per-task URLSession delegate that bridges callback-based data delivery into
/// an `AsyncThrowingStream<Data, Error>`. Verifies HTTP 206 + matching
/// `Content-Range`. Treats HTTP 200 as a Range refusal (the server ignored us).
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var expectedStart: Int64 = 0
    private var expectedEnd: Int64 = 0
    private var unbounded = false
    /// Credential for server-auth challenges on this task, if the host has one.
    var credential: URLCredential?
    /// Reports the local address the finished task used (URLSession picks the interface).
    var onLocalAddress: (@Sendable (String) -> Void)?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        if let address = metrics.transactionMetrics.last?.localAddress {
            onLocalAddress?(address)
        }
    }

    func attach(
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        expectedRangeStart: Int64,
        expectedRangeEnd: Int64,
        unbounded: Bool = false
    ) {
        self.continuation = continuation
        self.expectedStart = expectedRangeStart
        self.expectedEnd = expectedRangeEnd
        self.unbounded = unbounded
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            continuation?.finish(throwing: ChunkError.noHttpResponse)
            completionHandler(.cancel)
            return
        }
        if let error = RangeResponseValidator.validate(
            status: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            expectedStart: expectedStart,
            expectedEnd: expectedEnd,
            unbounded: unbounded
        ) {
            continuation?.finish(throwing: error)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    /// Answer HTTP Basic/Digest/NTLM challenges with the host credential (first
    /// attempt only — a `previousFailureCount > 0` means it was rejected, so we
    /// cancel and let the 401 surface as `authRequired`). Non-auth challenges
    /// (e.g. server trust) get default handling.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let isServerAuth = method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodNTLM
        guard isServerAuth else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let credential, challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}
