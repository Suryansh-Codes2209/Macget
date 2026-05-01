import Foundation

enum ChunkError: Error, LocalizedError {
    case noHttpResponse
    case unexpectedStatus(Int)
    case rangeRefused(Int)
    case wrongContentRange(expected: String, got: String)
    case writerUnavailable
    case chunkNotFound

    var errorDescription: String? {
        switch self {
        case .noHttpResponse: return "Server did not return an HTTP response."
        case .unexpectedStatus(let c): return "Unexpected HTTP status \(c)."
        case .rangeRefused(let c): return "Server refused Range request (HTTP \(c))."
        case .wrongContentRange(let e, let g): return "Server returned wrong Content-Range. Expected \(e), got \(g)."
        case .writerUnavailable: return "File writer unavailable."
        case .chunkNotFound: return "Chunk not found in download."
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
    /// Called periodically with bytes flushed to disk for this chunk.
    let report: @Sendable (UUID, Int) async -> Void

    /// Per-write buffer size. Workers accumulate small Data deliveries from the
    /// URLSession delegate into 64 KB writes.
    static let writeBufferBytes = 64 * 1024

    func run() async throws {
        if chunk.isComplete { return }

        let requestStart = chunk.nextWriteOffset
        let requestEnd = chunk.endByte
        guard requestStart <= requestEnd else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=\(requestStart)-\(requestEnd)", forHTTPHeaderField: "Range")
        if let etag {
            req.setValue(etag, forHTTPHeaderField: "If-Range")
        } else if let lastModified {
            req.setValue(lastModified, forHTTPHeaderField: "If-Range")
        }

        try await stream(request: req, expectedStart: requestStart, expectedEnd: requestEnd, startingOffset: requestStart)
    }

    private func stream(request: URLRequest, expectedStart: Int64, expectedEnd: Int64, startingOffset: Int64) async throws {
        let delegate = StreamingDelegate()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            delegate.attach(continuation: continuation, expectedRangeStart: expectedStart, expectedRangeEnd: expectedEnd)
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
        let chunkEndExclusive = expectedEnd + 1

        for try await piece in stream {
            try Task.checkCancellation()

            // Don't write past the chunk end if server over-reads.
            let allowedRemaining = chunkEndExclusive - (offset + Int64(buffer.count))
            if allowedRemaining <= 0 { break }
            let usable: Data = (Int64(piece.count) > allowedRemaining)
                ? piece.prefix(Int(allowedRemaining))
                : piece
            buffer.append(usable)

            if buffer.count >= Self.writeBufferBytes {
                let toWrite = buffer
                try await writer.write(toWrite, at: offset)
                offset += Int64(toWrite.count)
                await report(chunk.id, toWrite.count)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            let toWrite = buffer
            try await writer.write(toWrite, at: offset)
            await report(chunk.id, toWrite.count)
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

    func attach(
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        expectedRangeStart: Int64,
        expectedRangeEnd: Int64
    ) {
        self.continuation = continuation
        self.expectedStart = expectedRangeStart
        self.expectedEnd = expectedRangeEnd
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
        if http.statusCode == 200 {
            continuation?.finish(throwing: ChunkError.rangeRefused(200))
            completionHandler(.cancel)
            return
        }
        if http.statusCode != 206 {
            continuation?.finish(throwing: ChunkError.unexpectedStatus(http.statusCode))
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
