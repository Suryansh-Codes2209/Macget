import XCTest
@testable import Macget

final class TorrentBondingTests: XCTestCase {
    func test_multipleInterfacePresentOnlyWithAddresses() {
        var options = TorrentEngineOptions()
        XCTAssertFalse(Aria2Daemon.arguments(port: 1, secret: "s", options: options)
            .contains { $0.hasPrefix("--multiple-interface") })

        options.bondingAddresses = ["192.168.0.5", "172.20.10.2"]
        XCTAssertTrue(Aria2Daemon.arguments(port: 1, secret: "s", options: options)
            .contains("--multiple-interface=192.168.0.5,172.20.10.2"))
    }

    func test_bondingAddressesAreLaunchOnly() {
        var options = TorrentEngineOptions()
        options.bondingAddresses = ["192.168.0.5", "172.20.10.2"]
        XCTAssertNil(options.mutableGlobalOptions["multiple-interface"])
    }

    func test_aria2StopsWithMacGet() {
        // Backstop for every path that skips a clean shutdown.
        let args = Aria2Daemon.arguments(port: 1, secret: "s", options: TorrentEngineOptions())
        XCTAssertTrue(args.contains("--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)"))
        XCTAssertTrue(Aria2Daemon.arguments(port: 1, secret: "s", options: TorrentEngineOptions(), parentPID: 4242)
            .contains("--stop-with-process=4242"))
    }

    func test_settingsDoNotCarryAddresses() {
        // Addresses come from live links, never from persisted settings.
        var settings = AppSettings()
        settings.bonding = BondingSettings(enabled: true)
        XCTAssertEqual(settings.torrentOptions.bondingAddresses, [])
    }
}

final class TorrentRestartPlanTests: XCTestCase {
    func test_onlyActiveTorrentsRestart() {
        let ids = (0..<5).map { _ in UUID() }
        let plan = TorrentRestartPlan.plan([
            (ids[0], .downloading), (ids[1], .queued), (ids[2], .paused),
            (ids[3], .completed), (ids[4], .failed),
        ])
        XCTAssertEqual(Set(plan.restart), [ids[0], ids[1]])
        XCTAssertEqual(Set(plan.drop), [ids[2], ids[3], ids[4]])
    }

    func test_restartRechecksStatusAtStartTime() {
        // Paused or cancelled during the daemon shutdown → not restarted.
        XCTAssertTrue(TorrentRestartPlan.shouldStartNow(currentStatus: .downloading, shuttingDown: false))
        XCTAssertTrue(TorrentRestartPlan.shouldStartNow(currentStatus: .queued, shuttingDown: false))
        XCTAssertFalse(TorrentRestartPlan.shouldStartNow(currentStatus: .paused, shuttingDown: false))
        XCTAssertFalse(TorrentRestartPlan.shouldStartNow(currentStatus: .cancelled, shuttingDown: false))
        XCTAssertFalse(TorrentRestartPlan.shouldStartNow(currentStatus: .completed, shuttingDown: false))
        XCTAssertFalse(TorrentRestartPlan.shouldStartNow(currentStatus: nil, shuttingDown: false), "removed")
        // Nothing starts once the app is quitting.
        XCTAssertFalse(TorrentRestartPlan.shouldStartNow(currentStatus: .downloading, shuttingDown: true))
    }

    func test_addressComparisonIsOrderInsensitive() {
        XCTAssertTrue(TorrentRestartPlan.sameAddressSet(["a", "b"], ["b", "a"]))
        XCTAssertFalse(TorrentRestartPlan.sameAddressSet(["a"], ["a", "b"]))
        XCTAssertTrue(TorrentRestartPlan.sameAddressSet([], []))
    }
}

final class TorrentPauseMidRestartTests: XCTestCase {
    /// A downloading torrent whose job was stopped for an aria2 restart has no
    /// live job; pausing it must still stick, or the restart resumes it.
    func test_pausingJoblessDownloadingTorrent_marksPaused() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macget-torrent-pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var torrent = Download(url: URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")!,
                               destinationFolder: dir, filename: "t", kind: .torrent)
        torrent.status = .downloading
        let store = DownloadStore(fileURL: dir.appendingPathComponent("queue.json"))
        await store.replaceAllImmediately([torrent])

        var settings = AppSettings()
        settings.resumeOnLaunch = true
        let engine = DownloadEngine(store: store, settings: settings,
                                    linkProvider: StubLinkProvider([]),
                                    pinnedTransport: StubPinnedTransport(mode: .serve, totalBytes: 1))
        await engine.loadPersistedAndResume()

        await engine.pause(torrent.id)
        let status = await engine.currentDownloads().first { $0.id == torrent.id }?.status
        XCTAssertEqual(status, .paused)
        await engine.suspendAllForShutdown()
    }
}
