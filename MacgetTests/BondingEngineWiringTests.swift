import XCTest
@testable import Macget

final class BondingEngineWiringTests: XCTestCase {
    func test_engineHandsBondingSettingsAndTransportToCoordinators() async throws {
        let total: Int64 = 32 * 1024 * 1024
        BondingStubURLProtocol.totalBytes = total
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BondingStubURLProtocol.self]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macget-engine-bond-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var settings = AppSettings()
        settings.defaultDestination = dir
        settings.defaultThreadCount = 8
        settings.bonding = BondingSettings(enabled: true)
        let transport = StubPinnedTransport(mode: .serve, totalBytes: total)
        let store = DownloadStore(fileURL: dir.appendingPathComponent("queue.json"))
        let engine = DownloadEngine(
            store: store, settings: settings, session: URLSession(configuration: config),
            linkProvider: StubLinkProvider([BondingCoordinatorTests.wifi, BondingCoordinatorTests.tether]),
            pinnedTransport: transport
        )

        let done = expectation(description: "completed")
        let events = engine.events
        let listener = Task {
            for await event in events {
                if case .stateChanged(let d) = event, d.status == .completed { done.fulfill(); return }
            }
        }
        defer { listener.cancel() }
        await engine.add(url: URL(string: "https://bond.example.com/big.bin")!, destinationFolder: dir)
        await fulfillment(of: [done], timeout: 30)
        XCTAssertGreaterThan(transport.requestCount, 0)
    }
}
