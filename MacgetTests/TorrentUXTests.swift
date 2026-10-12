import XCTest
@testable import Macget

// MARK: - Kind filter

/// The sidebar gained a second, orthogonal axis. Kind and status compose:
/// "Active" × "Torrents" has to be expressible, which is why kind is its own
/// filter rather than another `StatusFilter` case.
final class KindFilterTests: XCTestCase {

    func test_allMatchesEveryKind() {
        for kind in [DownloadKind.httpFile, .media, .torrent] {
            XCTAssertTrue(KindFilter.all.matches(kind))
        }
    }

    func test_eachFilterMatchesOnlyItsOwnKind() {
        XCTAssertTrue(KindFilter.files.matches(.httpFile))
        XCTAssertFalse(KindFilter.files.matches(.media))
        XCTAssertFalse(KindFilter.files.matches(.torrent))

        XCTAssertTrue(KindFilter.media.matches(.media))
        XCTAssertFalse(KindFilter.media.matches(.httpFile))

        XCTAssertTrue(KindFilter.torrents.matches(.torrent))
        XCTAssertFalse(KindFilter.torrents.matches(.httpFile))
    }
}

@MainActor
final class KindFilterListTests: XCTestCase {

    private func makeVM() -> (DownloadEngine, DownloadListViewModel) {
        let store = DownloadStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("kind-\(UUID().uuidString).json"))
        let engine = DownloadEngine(store: store, settings: AppSettings())
        return (engine, DownloadListViewModel(engine: engine))
    }

    /// Seed one download of each kind and let the view model drain the events.
    private func seed(_ engine: DownloadEngine) async throws {
        let dir = FileManager.default.temporaryDirectory
        _ = await engine.add(url: URL(string: "https://example.com/a.zip")!,
                             destinationFolder: dir, filename: "a.zip",
                             threadCount: 1, startImmediately: false)
        _ = await engine.addTorrent(
            magnet: URL(string: "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056")!,
            destinationFolder: dir, startImmediately: false)
        try await Task.sleep(for: .milliseconds(400))
    }

    func test_torrentsFilterShowsOnlyTorrents() async throws {
        let (engine, vm) = makeVM()
        vm.bootstrap()
        try await Task.sleep(for: .milliseconds(300))
        try await seed(engine)

        XCTAssertEqual(vm.rows.count, 2, "both kinds visible under All Types")

        vm.selectedKind = .torrents
        vm.filterRefreshed()
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertTrue(vm.rows.allSatisfy(\.isTorrent))

        vm.selectedKind = .files
        vm.filterRefreshed()
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertFalse(vm.rows[0].isTorrent)
    }

    /// Counts on each axis ignore the other axis, so the numbers don't shift as
    /// the user clicks around.
    func test_countsAreIndependentOfTheOtherAxis() async throws {
        let (engine, vm) = makeVM()
        vm.bootstrap()
        try await Task.sleep(for: .milliseconds(300))
        try await seed(engine)

        XCTAssertEqual(vm.count(for: KindFilter.torrents), 1)
        XCTAssertEqual(vm.count(for: StatusFilter.all), 2)

        vm.selectedKind = .torrents
        vm.filterRefreshed()

        XCTAssertEqual(vm.count(for: StatusFilter.all), 2, "status counts must ignore the kind selection")
        XCTAssertEqual(vm.count(for: KindFilter.files), 1, "kind counts must ignore the status selection")
    }
}

// MARK: - Primary file

/// A finished torrent lands as a folder. Opening it should play the payload, not
/// pop a Finder window — the motivating case was a 1.98 GB .mp4 beside a 128 KB
/// poster .jpg.
final class PrimaryFileURLTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("primary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func row(kind: DownloadKind, files: [TorrentFileEntry]?, folder: URL) -> DownloadRowItem {
        DownloadRowItem(
            id: UUID(), filename: "Torrent Folder",
            url: URL(string: "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056")!,
            destinationURL: folder.appendingPathComponent("Torrent Folder"),
            status: .completed, totalBytes: 100, bytesDownloaded: 100,
            speedBytesPerSec: 0, etaSeconds: nil, error: nil, createdAt: Date(),
            threadCount: 1, supportsRange: true, priority: .normal, phase: nil,
            kind: kind, uploadSpeedBytesPerSec: 0, uploadedBytes: 0,
            seeders: nil, peers: nil, isSeeding: false, torrentFiles: files
        )
    }

    private func touch(_ name: String, bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }

    func test_picksTheLargestFile() throws {
        let movie = try touch("movie.mp4", bytes: 2048)
        _ = try touch("poster.jpg", bytes: 16)
        let files = [
            TorrentFileEntry(index: 1, path: dir.appendingPathComponent("poster.jpg").path,
                             length: 16, selected: true),
            TorrentFileEntry(index: 2, path: movie.path, length: 2048, selected: true),
        ]
        XCTAssertEqual(row(kind: .torrent, files: files, folder: dir).primaryFileURL, movie)
    }

    func test_nonTorrentUsesDestinationURL() {
        let r = row(kind: .httpFile, files: nil, folder: dir)
        XCTAssertEqual(r.primaryFileURL, r.destinationURL)
    }

    func test_torrentWithoutMetadataUsesDestinationURL() {
        let r = row(kind: .torrent, files: nil, folder: dir)
        XCTAssertEqual(r.primaryFileURL, r.destinationURL)
    }

    /// Unselected files are legitimately absent from disk, so a chosen file that
    /// isn't there must not become a dead menu item.
    func test_missingFileFallsBackToDestinationURL() {
        let files = [TorrentFileEntry(index: 1, path: dir.appendingPathComponent("gone.mkv").path,
                                      length: 9999, selected: false)]
        let r = row(kind: .torrent, files: files, folder: dir)
        XCTAssertEqual(r.primaryFileURL, r.destinationURL)
    }
}

// MARK: - aria2 arguments

/// `Aria2Daemon.arguments` is pure, so the tuning is assertable without ever
/// launching aria2 — same approach as `test_doesNotUseAria2SessionPersistence`.
final class Aria2TuningTests: XCTestCase {

    private func args(verifyOnResume: Bool = false) -> [String] {
        var options = TorrentEngineOptions()
        options.verifyOnResume = verifyOnResume
        return Aria2Daemon.arguments(port: 12345, secret: "abc", options: options)
    }

    func test_raisesPeerAndCacheLimits() {
        let a = args()
        XCTAssertTrue(a.contains("--bt-max-peers=200"))
        // 128M — raised from an earlier 64M for modern disks; see Aria2DaemonTests
        // for the mmap/falloc reasoning behind that value.
        XCTAssertTrue(a.contains("--disk-cache=128M"))
        XCTAssertTrue(a.contains("--file-allocation=falloc"))
    }

    /// aria2 stops hunting for peers once the torrent exceeds this. The default
    /// is 50K — dial-up speeds. 100M is above any consumer link, so aria2 keeps
    /// seeking peers until the pipe is genuinely full. It is the single most
    /// consequential knob.
    func test_raisesRequestPeerSpeedLimit() {
        XCTAssertTrue(args().contains("--bt-request-peer-speed-limit=100M"))
    }

    func test_shortensTrackerTimeouts() {
        let a = args()
        XCTAssertTrue(a.contains("--bt-tracker-connect-timeout=30"))
        XCTAssertTrue(a.contains("--bt-tracker-timeout=30"))
    }

    /// Re-hashing every existing piece on every resume costs gigabytes of reads
    /// on a large torrent, so it is opt-in now rather than always on.
    func test_integrityCheckIsOptIn() {
        XCTAssertFalse(args(verifyOnResume: false).contains { $0.hasPrefix("--check-integrity") })
        XCTAssertTrue(args(verifyOnResume: true).contains("--check-integrity=true"))
    }

    /// Everything the earlier design decided must survive the tuning.
    func test_existingInvariantsSurvive() {
        let a = args()
        XCTAssertTrue(a.contains("--continue=true"))
        XCTAssertTrue(a.contains("--bt-save-metadata=true"))
        XCTAssertTrue(a.contains("--rpc-listen-all=false"))
        XCTAssertFalse(a.contains { $0.hasPrefix("--save-session") })
    }
}
