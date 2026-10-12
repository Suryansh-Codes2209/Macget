import XCTest
@testable import Macget

/// Deterministic file content: byte i is `i % 251`, so any misplaced range shows.
enum BondingTestData {
    private static let pattern = Data((0..<251).map { UInt8($0) })

    /// Built by copying the 251-byte pattern rather than mapping each byte:
    /// a per-byte `map` over the 32 MB bonding fixtures is slow enough in Debug
    /// to push those tests past their timeouts on a CI runner.
    static func bytes(_ range: ClosedRange<Int64>) -> Data {
        var out = Data(capacity: range.count)
        var offset = Int(range.lowerBound % 251)
        var remaining = range.count
        while remaining > 0 {
            let n = min(251 - offset, remaining)
            out.append(pattern[offset..<(offset + n)])
            remaining -= n
            offset = 0
        }
        return out
    }

    static func parseRange(_ header: String, total: Int64) -> (Int64, Int64)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0]) else { return nil }
        let end = Int64(parts[1]) ?? (total - 1)
        return (start, min(end, total - 1))
    }
}

final class StubPinnedTransport: PinnedTransport, @unchecked Sendable {
    enum Mode { case serve, status(Int), redirect(String), hang, fail }

    private let lock = NSLock()
    private var _mode: Mode
    private var _requests: [(url: URL, headers: [(String, String)], linkID: String)] = []
    let totalBytes: Int64

    init(mode: Mode, totalBytes: Int64) {
        _mode = mode
        self.totalBytes = totalBytes
    }

    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requests.count }
    var lastURL: URL? { lock.lock(); defer { lock.unlock() }; return _requests.last?.url }
    var lastHeaders: [(String, String)] { lock.lock(); defer { lock.unlock() }; return _requests.last?.headers ?? [] }

    func get(url: URL, headers: [(String, String)], linkID: String) async throws -> PinnedResponse {
        lock.lock(); _requests.append((url, headers, linkID)); let mode = _mode; lock.unlock()
        let range = headers.first { $0.0 == "Range" }.flatMap { BondingTestData.parseRange($0.1, total: totalBytes) }

        switch mode {
        case .fail:
            throw PinnedTransportError.connectionFailed("stub")
        case .status(let code):
            return PinnedResponse(head: HTTPResponseHead(status: code, headers: [:]),
                                  body: AsyncThrowingStream { $0.finish() })
        case .redirect(let location):
            self.mode = .serve
            return PinnedResponse(head: HTTPResponseHead(status: 302, headers: ["Location": location]),
                                  body: AsyncThrowingStream { $0.finish() })
        case .hang:
            let (s, e) = range ?? (0, totalBytes - 1)
            return PinnedResponse(head: HTTPResponseHead(status: 206, headers: ["Content-Range": "bytes \(s)-\(e)/\(totalBytes)"]),
                                  body: AsyncThrowingStream { _ in })
        case .serve:
            guard let (s, e) = range else { throw PinnedTransportError.unsupportedURL }
            let data = BondingTestData.bytes(s...e)
            return PinnedResponse(
                head: HTTPResponseHead(status: 206, headers: ["Content-Range": "bytes \(s)-\(e)/\(totalBytes)"]),
                body: AsyncThrowingStream { c in
                    var offset = 0
                    while offset < data.count {
                        let end = min(offset + 64 * 1024, data.count)
                        c.yield(data.subdata(in: offset..<end))
                        offset = end
                    }
                    c.finish()
                }
            )
        }
    }
}

final class PinnedChunkWorkerTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macget-pinned-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func runWorker(_ transport: StubPinnedTransport, chunk: Chunk, total: Int64,
                           credential: URLCredential? = nil, headers: [String: String]? = nil) async throws -> Data {
        let url = dir.appendingPathComponent("f.bin")
        let writer = try FileWriter(url: url, totalBytes: total)
        let worker = ChunkWorker(
            chunk: chunk,
            url: URL(string: "https://example.com/f.bin")!,
            etag: "\"v1\"",
            lastModified: nil,
            writer: writer,
            session: .shared,
            pinned: PinnedRoute(linkID: "en7", transport: transport),
            report: { _, _ in }
        )
        var w = worker
        w.credential = credential
        w.headers = headers
        try await w.run()
        await writer.close()
        return try Data(contentsOf: url)
    }

    func test_pinnedRouteWritesTheRequestedRange() async throws {
        let total: Int64 = 300_000
        let transport = StubPinnedTransport(mode: .serve, totalBytes: total)
        let chunk = Chunk(startByte: 1000, endByte: 200_999)
        let file = try await runWorker(transport, chunk: chunk, total: total)
        XCTAssertEqual(file.subdata(in: 1000..<201_000), BondingTestData.bytes(1000...200_999))
        XCTAssertEqual(transport.lastHeaders.first { $0.0 == "If-Range" }?.1, "\"v1\"")
        XCTAssertEqual(transport.lastHeaders.first { $0.0 == "Accept-Encoding" }?.1, "identity")
    }

    func test_403BecomesLinkRejected() async throws {
        let transport = StubPinnedTransport(mode: .status(403), totalBytes: 1000)
        do {
            _ = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 999), total: 1000)
            XCTFail("expected throw")
        } catch ChunkError.linkRejected(let id, let refused) {
            XCTAssertEqual(id, "en7")
            XCTAssertTrue(refused)
        }
    }

    func test_rangeIgnoredBecomesLinkRejectedNotRangeRefused() async throws {
        let transport = StubPinnedTransport(mode: .status(200), totalBytes: 1000)
        do {
            _ = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 999), total: 1000)
            XCTFail("expected throw")
        } catch ChunkError.linkRejected { }
    }

    func test_busyStaysRetryable() async throws {
        let transport = StubPinnedTransport(mode: .status(503), totalBytes: 1000)
        do {
            _ = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 999), total: 1000)
            XCTFail("expected throw")
        } catch ChunkError.serverBusy { }
    }

    func test_connectionFailureBecomesLinkTransport() async throws {
        let transport = StubPinnedTransport(mode: .fail, totalBytes: 1000)
        do {
            _ = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 999), total: 1000)
            XCTFail("expected throw")
        } catch ChunkError.linkTransport(let id, _) {
            XCTAssertEqual(id, "en7")
        }
    }

    func test_followsRedirectOnSameLink() async throws {
        let total: Int64 = 2000
        let transport = StubPinnedTransport(mode: .redirect("/real/f.bin"), totalBytes: total)
        let file = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 1999), total: total)
        XCTAssertEqual(file, BondingTestData.bytes(0...1999))
        XCTAssertEqual(transport.lastURL?.absoluteString, "https://example.com/real/f.bin")
        XCTAssertEqual(transport.requestCount, 2)
    }

    private func has(_ name: String, _ transport: StubPinnedTransport) -> Bool {
        transport.lastHeaders.contains { $0.0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func test_crossHostRedirectDropsCredentials() async throws {
        let transport = StubPinnedTransport(mode: .redirect("https://other.example.com/f.bin"), totalBytes: 2000)
        _ = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 1999), total: 2000,
                                credential: URLCredential(user: "u", password: "p", persistence: .none),
                                headers: ["Cookie": "a=b"])
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(transport.lastURL?.host, "other.example.com")
        XCTAssertFalse(has("Authorization", transport))
        XCTAssertFalse(has("Cookie", transport))
    }

    func test_sameHostRedirectKeepsCredentials() async throws {
        let transport = StubPinnedTransport(mode: .redirect("https://example.com/real/f.bin"), totalBytes: 2000)
        _ = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 1999), total: 2000,
                                credential: URLCredential(user: "u", password: "p", persistence: .none))
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertTrue(has("Authorization", transport))
    }

    func test_httpsToHttpRedirectIsRejected() async throws {
        let transport = StubPinnedTransport(mode: .redirect("http://example.com/f.bin"), totalBytes: 2000)
        do {
            _ = try await runWorker(transport, chunk: Chunk(startByte: 0, endByte: 1999), total: 2000,
                                    credential: URLCredential(user: "u", password: "p", persistence: .none))
            XCTFail("expected throw")
        } catch ChunkError.linkRejected(_, let refused) {
            XCTAssertTrue(refused)
            XCTAssertEqual(transport.requestCount, 1)
        }
    }

    func test_pinnedFailureMapping() {
        func map(_ e: ChunkError) -> ChunkError { ChunkWorker.pinnedFailure(e, linkID: "en7") }
        guard case .linkRejected(_, true) = map(.authRequired(code: 401)) else { return XCTFail() }
        guard case .linkRejected(_, true) = map(.unexpectedStatus(404)) else { return XCTFail() }
        guard case .linkRejected(_, true) = map(.wrongContentRange(expected: "a", got: "b")) else { return XCTFail() }
        guard case .unexpectedStatus(500) = map(.unexpectedStatus(500)) else { return XCTFail() }
        guard case .serverBusy = map(.serverBusy(code: 429, retryAfter: nil)) else { return XCTFail() }
    }
}
