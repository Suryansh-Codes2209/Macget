import XCTest
@testable import Macget

/// Thread-safe request tallies. `URLProtocol` callbacks land on URLSession's own
/// threads, so a plain counter would race.
final class RequestTally: @unchecked Sendable {
    private let lock = NSLock()
    private var heads = 0
    private var gets = 0

    func recordHead() { lock.lock(); heads += 1; lock.unlock() }
    func recordGet() { lock.lock(); gets += 1; lock.unlock() }
    var headCount: Int { lock.lock(); defer { lock.unlock() }; return heads }
    var getCount: Int { lock.lock(); defer { lock.unlock() }; return gets }
    func reset() { lock.lock(); heads = 0; gets = 0; lock.unlock() }
}

/// A range-capable server whose HEAD probe is slow.
///
/// The delay is the whole point: it holds the download in the window between
/// "the engine created a coordinator" and "the coordinator has reported
/// `.downloading`", which is where a duplicate start becomes possible.
final class SlowProbeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static let tally = RequestTally()
    nonisolated(unsafe) static var probeDelay: TimeInterval = 0.5

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let total = Self.body.count

        if request.httpMethod == "HEAD" {
            Self.tally.recordHead()
            if Self.probeDelay > 0 { Thread.sleep(forTimeInterval: Self.probeDelay) }
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(total), "Accept-Ranges": "bytes"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        Self.tally.recordGet()

        // Honor the Range header the worker sends; ChunkWorker requires 206 plus a
        // matching Content-Range and rejects a 200 as a range refusal.
        var start = 0
        var end = total - 1
        if let header = request.value(forHTTPHeaderField: "Range"),
           let range = Self.parseRange(header, total: total) {
            start = range.lowerBound
            end = range.upperBound
        }
        let slice = Self.body.subdata(in: start..<(end + 1))
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": String(slice.count),
                "Content-Range": "bytes \(start)-\(end)/\(total)",
                "Accept-Ranges": "bytes",
            ]
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func parseRange(_ header: String, total: Int) -> ClosedRange<Int>? {
        let spec = header.replacingOccurrences(of: "bytes=", with: "")
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard let lower = Int(parts.first ?? "") else { return nil }
        let upper = parts.count > 1 ? (Int(parts[1]) ?? total - 1) : total - 1
        guard lower <= upper, upper < total else { return nil }
        return lower...upper
    }
}

final class DuplicateCoordinatorTests: XCTestCase {

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowProbeURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A download that is mid-probe is still `.queued`, because the coordinator
    /// only reports `.downloading` after the probe returns. The scheduler picks
    /// candidates by status, so anything that re-runs it during that window used
    /// to start a *second* coordinator for the same download.
    ///
    /// Both then raced to the same partial file: whichever finished first moved
    /// it to the destination and reported `.completed`, and the loser found no
    /// partial to move and overwrote the record with
    /// "Could not move file to destination … the former doesn't exist" — a
    /// download that failed with the finished file sitting on disk.
    func test_schedulerDoesNotStartASecondCoordinatorWhileTheFirstIsProbing() async throws {
        SlowProbeURLProtocol.body = Data((0..<100_000).map { UInt8($0 & 0xFF) })
        SlowProbeURLProtocol.probeDelay = 0.5
        SlowProbeURLProtocol.tally.reset()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macget-dupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = DownloadStore(fileURL: dir.appendingPathComponent("queue.json"))
        let settings = AppSettings(
            defaultDestination: dir,
            defaultThreadCount: 1,
            maxConcurrentDownloads: 3,
            startDownloadsAutomatically: true
        )
        let engine = DownloadEngine(store: store, settings: settings, session: makeStubSession())

        let terminal = expectation(description: "reaches a terminal state")
        let finalState = TerminalBox()
        let events = engine.events
        let listener = Task {
            for await event in events {
                if case .stateChanged(let d) = event, d.status.isTerminal {
                    await finalState.set(d)
                    terminal.fulfill()
                    return
                }
            }
        }
        defer { listener.cancel() }

        let id = await engine.add(
            url: URL(string: "https://example.com/movie.bin")!,
            destinationFolder: dir,
            filename: "movie.bin",
            threadCount: 1
        )
        XCTAssertNotNil(id)

        // Mid-probe: the coordinator exists but the record still reads `.queued`.
        try await Task.sleep(for: .milliseconds(150))
        // Pausing an unknown id is a no-op that still re-runs the scheduler —
        // the same thing a settings change, a network blip, or another download
        // finishing would do.
        await engine.pause(UUID())

        await fulfillment(of: [terminal], timeout: 20)

        XCTAssertEqual(SlowProbeURLProtocol.tally.headCount, 1,
                       "Two probes means two coordinators were started for one download")

        let result = await finalState.value
        XCTAssertEqual(result?.status, .completed,
                       "expected completion, got error: \(result?.error ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("movie.bin").path))
    }
}

private actor TerminalBox {
    private(set) var value: Download?
    func set(_ d: Download) { value = d }
}
