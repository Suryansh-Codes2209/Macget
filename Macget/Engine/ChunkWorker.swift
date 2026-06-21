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
        }
    }
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

        try await stream(request: req, expectedStart: requestStart, expectedEnd: requestEnd, startingOffset: requestStart, unbounded: false)
    }

    private func stream(request: URLRequest, expectedStart: Int64, expectedEnd: Int64, startingOffset: Int64, unbounded: Bool) async throws {
        let delegate = StreamingDelegate()
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
        if unbounded {
            // No Range was sent — any 2xx is the full body. 200 is expected here.
            guard (200..<300).contains(http.statusCode) else {
                continuation?.finish(throwing: Self.statusError(http))
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
            return
        }
        if http.statusCode == 200 {
            continuation?.finish(throwing: ChunkError.rangeRefused(200))
            completionHandler(.cancel)
            return
        }
        if http.statusCode != 206 {
            continuation?.finish(throwing: Self.statusError(http))
            completionHandler(.cancel)
            return
        }
        if let cr = http.value(forHTTPHeaderField: "Content-Range") {
            let expected = "bytes \(expectedStart)-\(expectedEnd)/"
            if !cr.hasPrefix(expected) {
                continuation?.finish(throwing: ChunkError.wrongContentRange(expected: expected + "<total>", got: cr))
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    /// Maps an error status into the right `ChunkError`. 429/503 carry the
    /// parsed `Retry-After` so the coordinator can honor the server's backoff.
    private static func statusError(_ http: HTTPURLResponse) -> ChunkError {
        switch http.statusCode {
        case 429, 503:
            return .serverBusy(
                code: http.statusCode,
                retryAfter: RetryAfter.parse(http.value(forHTTPHeaderField: "Retry-After"))
            )
        default:
            return .unexpectedStatus(http.statusCode)
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
