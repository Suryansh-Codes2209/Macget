import XCTest
@testable import Macget

/// Ranged URLSession stub for the default link: HEAD advertises ranges, GET serves `BondingTestData`.
class BondingStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var totalBytes: Int64 = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let total = Self.totalBytes
        var headers = ["Accept-Ranges": "bytes", "ETag": "\"v1\""]
        var status = 200
        var body = Data()
        if request.httpMethod == "HEAD" {
            headers["Content-Length"] = String(total)
        } else if let raw = request.value(forHTTPHeaderField: "Range"),
                  let (s, e) = BondingTestData.parseRange(raw, total: total) {
            status = 206
            headers["Content-Range"] = "bytes \(s)-\(e)/\(total)"
            headers["Content-Length"] = String(e - s + 1)
            body = BondingTestData.bytes(s...e)
        } else {
            headers["Content-Length"] = String(total)
            body = BondingTestData.bytes(0...(total - 1))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Default link that is dead from the start: HEAD succeeds, but the first
/// `failingGets` ranged GETs get 503 before any byte arrives. Afterwards it
/// serves normally so the download can finish either way.
final class DeadDefaultLinkURLProtocol: BondingStubURLProtocol {
    static let failingGets = 12
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gets = 0

    static func reset() { lock.lock(); gets = 0; lock.unlock() }

    override func startLoading() {
        guard request.httpMethod != "HEAD" else { return super.startLoading() }
        Self.lock.lock(); Self.gets += 1; let n = Self.gets; Self.lock.unlock()
        guard n <= Self.failingGets else { return super.startLoading() }
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Default link that answers each ranged GET only after a delay, so a test can
/// change settings while the first wave of workers is still in flight.
final class SlowDefaultLinkURLProtocol: BondingStubURLProtocol {
    static let delay: TimeInterval = 0.6
    private let lock = NSLock()
    private var stopped = false

    override func startLoading() {
        guard request.httpMethod != "HEAD" else { return super.startLoading() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) {
            self.serveUnlessStopped()
        }
    }

    private func serveUnlessStopped() {
        lock.lock(); let isStopped = stopped; lock.unlock()
        if !isStopped { super.startLoading() }
    }

    override func stopLoading() {
        lock.lock(); stopped = true; lock.unlock()
    }
}

final class StubLinkProvider: LinkProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _links: [NetworkLink]
    init(_ links: [NetworkLink]) { _links = links }
    var links: [NetworkLink] {
        get { lock.lock(); defer { lock.unlock() }; return _links }
        set { lock.lock(); _links = newValue; lock.unlock() }
    }
    func usableLinks() async -> [NetworkLink] { links }
}

actor SnapshotLog {
    private(set) var snapshots: [DownloadSnapshot] = []
    private(set) var final: Download?
    func add(_ s: DownloadSnapshot) { snapshots.append(s) }
    func finish(_ d: Download) { final = d }
}

final class BondingCoordinatorTests: XCTestCase {
    static let wifi = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: ["192.168.0.5"], isDefaultRoute: true)
    static let tether = NetworkLink(id: "en7", displayName: "iPhone USB", kind: .tethered, addresses: ["172.20.10.2"], isDefaultRoute: false)
    let total: Int64 = 32 * 1024 * 1024

    private var dir: URL!
    private var capStoreURL: URL!

    override func setUp() {
        BondingStubURLProtocol.totalBytes = total
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macget-bond-\(UUID().uuidString)")
        capStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent("caps-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: capStoreURL)
    }

    private func session(_ protocolClass: AnyClass = BondingStubURLProtocol.self) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        return URLSession(configuration: config)
    }

    private func run(
        transport: StubPinnedTransport,
        provider: StubLinkProvider,
        capStore: HostCapStore? = nil,
        sessionProtocol: AnyClass = BondingStubURLProtocol.self,
        timeout: TimeInterval = 30
    ) async throws -> (Download?, [DownloadSnapshot]) {
        var download = Download(url: URL(string: "https://bond.example.com/big.bin")!, destinationFolder: dir, filename: "big.bin")
        download.threadCount = 8
        let log = SnapshotLog()
        let done = expectation(description: "terminal")
        let coordinator = DownloadCoordinator(
            download: download,
            session: session(sessionProtocol),
            hostCapStore: capStore ?? HostCapStore(fileURL: capStoreURL),
            linkProvider: provider,
            pinnedTransport: transport,
            bonding: BondingSettings(enabled: true),
            systemProxyCheck: { _ in false },
            onStateChange: { d in
                if d.status.isTerminal { await log.finish(d); done.fulfill() }
            },
            onSnapshot: { s in await log.add(s) }
        )
        await coordinator.start()
        await fulfillment(of: [done], timeout: timeout)
        return (await log.final, await log.snapshots)
    }

    private func assertFileIsCorrect() throws {
        let data = try Data(contentsOf: dir.appendingPathComponent("big.bin"))
        XCTAssertEqual(data.count, Int(total))
        XCTAssertEqual(data, BondingTestData.bytes(0...(total - 1)))
    }

    func test_bothLinksCarryBytesAndFileIsCorrect() async throws {
        let transport = StubPinnedTransport(mode: .serve, totalBytes: total)
        let (final, snaps) = try await run(transport: transport, provider: StubLinkProvider([Self.wifi, Self.tether]))
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        try assertFileIsCorrect()
        XCTAssertGreaterThan(transport.requestCount, 0, "pinned link was never used")
        let withLinks = snaps.first { $0.links.count == 2 }
        XCTAssertNotNil(withLinks, "no snapshot carried a two-link breakdown")
        XCTAssertEqual(withLinks?.links.map(\.linkID), ["en0", "en7"])
    }

    func test_pinned403_dropsLinkAndCompletes() async throws {
        let transport = StubPinnedTransport(mode: .status(403), totalBytes: total)
        let (final, snaps) = try await run(transport: transport, provider: StubLinkProvider([Self.wifi, Self.tether]))
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        try assertFileIsCorrect()
        XCTAssertTrue(snaps.contains { $0.links.contains { $0.linkID == "en7" && $0.status == .rejectedByServer } })
        // One rejection excludes the link; later spawns never try it again.
        XCTAssertLessThanOrEqual(transport.requestCount, 4)
    }

    func test_pinnedRangeIgnored_doesNotFailDownload() async throws {
        let transport = StubPinnedTransport(mode: .status(200), totalBytes: total)
        let (final, _) = try await run(transport: transport, provider: StubLinkProvider([Self.wifi, Self.tether]))
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        try assertFileIsCorrect()
    }

    func test_linkDisappears_workersReassigned() async throws {
        let transport = StubPinnedTransport(mode: .hang, totalBytes: total)
        let provider = StubLinkProvider([Self.wifi, Self.tether])
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            provider.links = [Self.wifi]   // phone unplugged
        }
        let start = Date()
        let (final, snaps) = try await run(transport: transport, provider: provider, timeout: 20)
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        try assertFileIsCorrect()
        XCTAssertLessThan(Date().timeIntervalSince(start), 15, "should not wait for the 30s stall watchdog")
        XCTAssertTrue(snaps.contains { $0.links.contains { $0.linkID == "en7" && $0.status == .down } })
    }

    func test_flakyPinnedLink_neverWritesHostCap() async throws {
        let capStore = HostCapStore(fileURL: capStoreURL)
        let transport = StubPinnedTransport(mode: .fail, totalBytes: total)
        let (final, _) = try await run(transport: transport, provider: StubLinkProvider([Self.wifi, Self.tether]), capStore: capStore)
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        let cap = await capStore.cap(for: "bond.example.com")
        XCTAssertNil(cap, "a failing pinned link must not teach a host cap")
    }

    func test_deadDefaultLinkBesideHealthyPhone_neverWritesHostCap() async throws {
        // URLSession workers fail with no progress while the phone moves bytes.
        // Aggregate speed looks healthy, but it's the default link's own
        // throughput (zero) that must judge demotion — the host is blameless.
        DeadDefaultLinkURLProtocol.reset()
        let capStore = HostCapStore(fileURL: capStoreURL)
        let transport = StubPinnedTransport(mode: .serve, totalBytes: total)
        let (final, _) = try await run(transport: transport, provider: StubLinkProvider([Self.wifi, Self.tether]),
                                       capStore: capStore, sessionProtocol: DeadDefaultLinkURLProtocol.self)
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        try assertFileIsCorrect()
        XCTAssertGreaterThan(transport.requestCount, 0)
        let cap = await capStore.cap(for: "bond.example.com")
        XCTAssertNil(cap, "a dead default link must not teach the host a cap")
    }

    func test_disablingBondingMidDownload_stopsPinnedWorkersNow() async throws {
        // Pinned workers hang; only turning bonding off can free their pieces
        // before the 30 s stall watchdog would.
        let transport = StubPinnedTransport(mode: .hang, totalBytes: total)
        var download = Download(url: URL(string: "https://bond.example.com/big.bin")!, destinationFolder: dir, filename: "big.bin")
        download.threadCount = 8
        let log = SnapshotLog()
        let done = expectation(description: "terminal")
        let coordinator = DownloadCoordinator(
            // Slow default link: the download must still be running when bonding
            // is switched off, or there is nothing left to observe.
            download: download, session: session(SlowDefaultLinkURLProtocol.self), hostCapStore: HostCapStore(fileURL: capStoreURL),
            linkProvider: StubLinkProvider([Self.wifi, Self.tether]), pinnedTransport: transport,
            bonding: BondingSettings(enabled: true),
            systemProxyCheck: { _ in false },
            onStateChange: { d in if d.status.isTerminal { await log.finish(d); done.fulfill() } },
            onSnapshot: { s in await log.add(s) }
        )
        let start = Date()
        await coordinator.start()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThan(transport.requestCount, 0, "pinned link was never used")
        await coordinator.updateBonding(BondingSettings(enabled: false))
        // Endgame splitting would eventually free the hung pieces anyway, so the
        // sharp check is that the phone's connections are gone right away.
        let before = await log.snapshots.count
        try await Task.sleep(for: .milliseconds(500))
        let after = await log.snapshots.dropFirst(before + 1)
        XCTAssertFalse(after.isEmpty, "no snapshot published after disabling")
        let pinnedConnections = after.last?.links.first { $0.linkID == "en7" }?.activeConnections ?? 0
        XCTAssertEqual(pinnedConnections, 0, "pinned workers kept running after bonding was switched off")
        await fulfillment(of: [done], timeout: 20)
        let final = await log.final
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        try assertFileIsCorrect()
        XCTAssertLessThan(Date().timeIntervalSince(start), 15, "should not wait for the 30s stall watchdog")
    }

    func test_enablingBondingMidDownload_startsUsingPinnedLink() async throws {
        // Bonding was off when the run decided eligibility. Switching it on must
        // reach this download — new spawns fill the phone's quota, no restart.
        let total: Int64 = 64 * 1024 * 1024
        BondingStubURLProtocol.totalBytes = total
        let transport = StubPinnedTransport(mode: .serve, totalBytes: total)
        var download = Download(url: URL(string: "https://bond.example.com/big.bin")!, destinationFolder: dir, filename: "big.bin")
        download.threadCount = 4
        let log = SnapshotLog()
        let done = expectation(description: "terminal")
        let coordinator = DownloadCoordinator(
            download: download, session: session(SlowDefaultLinkURLProtocol.self),
            hostCapStore: HostCapStore(fileURL: capStoreURL),
            linkProvider: StubLinkProvider([Self.wifi, Self.tether]), pinnedTransport: transport,
            bonding: BondingSettings(enabled: false),
            systemProxyCheck: { _ in false },
            onStateChange: { d in if d.status.isTerminal { await log.finish(d); done.fulfill() } },
            onSnapshot: { s in await log.add(s) }
        )
        await coordinator.start()
        // Wait for the run to be past eligibility (first snapshot), still inside
        // the default link's first-response delay.
        var waited = 0
        while await log.snapshots.isEmpty, waited < 40 {
            try await Task.sleep(for: .milliseconds(25))
            waited += 1
        }
        XCTAssertEqual(transport.requestCount, 0, "bonding was off; the phone must be untouched so far")
        await coordinator.updateBonding(BondingSettings(enabled: true))
        await fulfillment(of: [done], timeout: 30)
        let final = await log.final
        XCTAssertEqual(final?.status, .completed, final?.error ?? "")
        XCTAssertGreaterThan(transport.requestCount, 0, "switching bonding on mid-download never used the phone")
        let data = try Data(contentsOf: dir.appendingPathComponent("big.bin"))
        XCTAssertEqual(data.count, Int(total))
        XCTAssertEqual(data, BondingTestData.bytes(0...(total - 1)))
    }

    func test_bondingOffNeverTouchesPinnedTransport() async throws {
        let transport = StubPinnedTransport(mode: .serve, totalBytes: total)
        var download = Download(url: URL(string: "https://bond.example.com/big.bin")!, destinationFolder: dir, filename: "big.bin")
        download.threadCount = 8
        let done = expectation(description: "terminal")
        let coordinator = DownloadCoordinator(
            download: download, session: session(), hostCapStore: HostCapStore(fileURL: capStoreURL),
            linkProvider: StubLinkProvider([Self.wifi, Self.tether]), pinnedTransport: transport,
            bonding: BondingSettings(enabled: false),
            systemProxyCheck: { _ in false },
            onStateChange: { d in if d.status.isTerminal { done.fulfill() } },
            onSnapshot: { _ in }
        )
        await coordinator.start()
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(transport.requestCount, 0)
    }
}
