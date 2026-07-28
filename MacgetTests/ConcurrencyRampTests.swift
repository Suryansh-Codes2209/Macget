import XCTest
@testable import Macget

/// Records how many range requests were in flight at once, and when the peak
/// was first reached.
final class ConcurrencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var peak = 0
    private(set) var peakReachedAt: Date?
    /// When the first range request arrived. The ramp is measured from here
    /// rather than from construction, so the probe, disk check, and file
    /// allocation aren't charged to the spawn stagger this asserts on.
    private(set) var firstRequestAt: Date?

    /// Offset of each request start from the first. Measuring the ramp from
    /// these — rather than from when the peak concurrency was observed — keeps
    /// the assertion independent of how completions are accounted for.
    private(set) var beginOffsets: [TimeInterval] = []

    /// The `Range` header of each request, in order.
    private(set) var rangeHeaders: [String] = []

    func begin(rangeHeader: String) {
        lock.lock(); defer { lock.unlock() }
        rangeHeaders.append(rangeHeader)
        let now = Date()
        active += 1
        if firstRequestAt == nil { firstRequestAt = now }
        beginOffsets.append(now.timeIntervalSince(firstRequestAt!))
        if active > peak {
            peak = active
            peakReachedAt = now
        }
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        active -= 1
    }

    /// How long after the first connection the `n`th one opened, or nil if it
    /// never did.
    func secondsToOpen(connection n: Int) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard beginOffsets.count >= n else { return nil }
        return beginOffsets[n - 1]
    }
}

/// Serves byte ranges, slowly enough that parallel workers actually overlap.
///
/// The existing `StubURLProtocol` returns the whole body immediately and ignores
/// `Range`, which is fine for the unknown-size path but useless here: a request
/// that completes instantly is never concurrent with anything.
final class RangeStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var totalBytes: Int64 = 0
    nonisolated(unsafe) static var recorder = ConcurrencyRecorder()
    /// How long each range request is held open before its body is delivered.
    /// Must exceed the coordinator's total spawn stagger, or workers would
    /// finish before their siblings have started and the peak would be 1.
    nonisolated(unsafe) static var responseDelay: TimeInterval = 1.0

    private let stateLock = NSLock()
    private var finished = false

    /// Claims the right to finish this request. Returns true exactly once, so a
    /// cancellation and the delayed delivery can race without the connection
    /// slot being released twice — or, worse, held past cancellation. A slot
    /// that lingers after `stopLoading` inflates the peak these tests assert on,
    /// because the coordinator spawns the replacement immediately.
    private func claimFinish() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Parses `Range: bytes=a-b`.
    private static func parseRange(_ header: String?) -> ClosedRange<Int64>? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let lower = Int64(parts[0]), let upper = Int64(parts[1]) else { return nil }
        guard lower <= upper else { return nil }
        return lower...upper
    }

    override func startLoading() {
        let total = Self.totalBytes
        let range = Self.parseRange(request.value(forHTTPHeaderField: "Range"))

        if request.httpMethod == "HEAD" {
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(total),
                    "Accept-Ranges": "bytes",
                    "ETag": "\"stub-etag\"",
                ]
            )!
            // Claim the finish so the eventual `stopLoading` doesn't release a
            // connection slot this request never took — that would drive the
            // counter negative and undercount every later measurement.
            _ = claimFinish()
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        Self.recorder.begin(rangeHeader: request.value(forHTTPHeaderField: "Range") ?? "none")

        let effective = range ?? 0...(total - 1)
        let length = effective.upperBound - effective.lowerBound + 1
        let headers: [String: String] = [
            "Content-Length": String(length),
            "Accept-Ranges": "bytes",
            "ETag": "\"stub-etag\"",
            "Content-Range": "bytes \(effective.lowerBound)-\(effective.upperBound)/\(total)",
        ]
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: range == nil ? 200 : 206,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!

        // Hold the connection open so siblings overlap, then deliver.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.responseDelay) { [weak self] in
            guard let self, self.claimFinish() else { return }
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            // Release the slot before handing over the body. `ChunkWorker`
            // completes a piece on the bytes themselves, not on
            // `urlProtocolDidFinishLoading`, so the coordinator steals the next
            // piece during `didLoad`. Freeing afterwards would count a connection
            // that has already finished its work against the concurrency cap.
            RangeStubURLProtocol.recorder.end()
            self.client?.urlProtocol(self, didLoad: Data(count: Int(length)))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        // Release the slot now, not at the original deadline — the coordinator
        // has already moved on and may have spawned a replacement.
        if claimFinish() { Self.recorder.end() }
    }
}

final class ConcurrencyRampTests: XCTestCase {

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangeStubURLProtocol.self]
        config.httpMaximumConnectionsPerHost = 20
        return URLSession(configuration: config)
    }

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("host_caps_ramp_\(UUID().uuidString).json")
    }

    /// The property the whole ramp rework exists to deliver: a download opens the
    /// connection count it was configured for, immediately.
    ///
    /// Against the previous implementation this failed twice over — the adaptive
    /// probe started at 4 and added one connection per 3 s, so peak concurrency
    /// was 4 and reaching 8 would have taken ~12 s.
    func test_opensConfiguredConnectionCountImmediately() async throws {
        // 16 pieces at the 8 MB target against 8 workers. Deliberately more
        // pieces than workers so `fillIdleSlots` always has something to steal
        // and never splits — splitting cancels and respawns, which would perturb
        // the concurrency measurement without telling us anything about the ramp.
        let total: Int64 = 128 * 1024 * 1024
        RangeStubURLProtocol.totalBytes = total
        RangeStubURLProtocol.recorder = ConcurrencyRecorder()
        RangeStubURLProtocol.responseDelay = 1.0

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macget-ramp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var download = Download(
            url: URL(string: "https://ramp.example.com/big.bin")!,
            destinationFolder: dir,
            filename: "big.bin"
        )
        download.threadCount = 8

        let done = expectation(description: "reaches a terminal state")
        let box = RampStateBox()

        let coordinator = DownloadCoordinator(
            download: download,
            session: makeStubSession(),
            hostCapStore: HostCapStore(fileURL: tempStoreURL()),
            onStateChange: { d in
                if d.status.isTerminal {
                    await box.set(d)
                    done.fulfill()
                }
            },
            onSnapshot: { _ in }
        )

        await coordinator.start()
        await fulfillment(of: [done], timeout: 30)

        let recorder = RangeStubURLProtocol.recorder
        let result = await box.value
        XCTAssertEqual(result?.status, .completed,
                       "download failed: \(result?.error ?? "nil")")

        XCTAssertEqual(recorder.peak, 8,
                       "expected all 8 configured connections open at once, saw \(recorder.peak). First requests: \(recorder.rangeHeaders.prefix(10))")
        let eighthOpenedAt = try XCTUnwrap(recorder.secondsToOpen(connection: 8),
                                           "never opened an 8th connection")
        XCTAssertLessThan(eighthOpenedAt, 1.5,
                          "8th connection opened \(eighthOpenedAt)s in; 7 spawns at the 100ms stagger is ~0.7s")
    }

    /// A learned host cap still wins over the user's setting — removing the probe
    /// must not remove the evidence-driven ceiling.
    func test_learnedHostCapStillLimitsConcurrency() async throws {
        let total: Int64 = 128 * 1024 * 1024  // 16 pieces, so no splitting
        RangeStubURLProtocol.totalBytes = total
        RangeStubURLProtocol.recorder = ConcurrencyRecorder()
        RangeStubURLProtocol.responseDelay = 0.4

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macget-ramp-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let capStore = HostCapStore(fileURL: tempStoreURL())
        await capStore.recordCap(3, for: "capped.example.com")

        var download = Download(
            url: URL(string: "https://capped.example.com/big.bin")!,
            destinationFolder: dir,
            filename: "big.bin"
        )
        download.threadCount = 8

        let done = expectation(description: "reaches a terminal state")
        let box = RampStateBox()

        let coordinator = DownloadCoordinator(
            download: download,
            session: makeStubSession(),
            hostCapStore: capStore,
            onStateChange: { d in
                if d.status.isTerminal {
                    await box.set(d)
                    done.fulfill()
                }
            },
            onSnapshot: { _ in }
        )

        await coordinator.start()
        await fulfillment(of: [done], timeout: 30)

        let recorder = RangeStubURLProtocol.recorder
        // Steady state is exactly 3. The tolerance of one covers the endgame
        // split: when fewer pieces remain than workers, `applySplit` cancels a
        // connection and opens two halves immediately, and the cancelled
        // socket's teardown is asynchronous. The overlap is one connection and
        // lasts milliseconds. What matters is that the learned cap binds at all
        // — without it this download would have opened the 8 it asked for.
        XCTAssertLessThanOrEqual(recorder.peak, 4,
                                 "learned host cap of 3 must bind, saw \(recorder.peak)")
        XCTAssertLessThan(recorder.peak, 8,
                          "cap was ignored — ran at the user's requested count")
    }
}

private actor RampStateBox {
    private(set) var value: Download?
    func set(_ d: Download) { value = d }
}
