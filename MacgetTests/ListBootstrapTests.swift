import XCTest
@testable import Macget

/// `DownloadListViewModel.bootstrap()` is called from `ContentView`'s `.task`.
///
/// That runs again whenever the content view is recreated — closing the window
/// and reopening it from the Dock is enough, since
/// `applicationShouldTerminateAfterLastWindowClosed` keeps the app alive. The
/// engine's `events` is a single `AsyncStream`, and an `AsyncStream` supports
/// exactly one consumer: re-iterating it delivers nothing, so a second
/// `bootstrap()` leaves the list permanently deaf to the engine.
@MainActor
final class ListBootstrapTests: XCTestCase {

    private func makeEngine() -> DownloadEngine {
        let store = DownloadStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("boot-\(UUID().uuidString).json"))
        return DownloadEngine(store: store, settings: AppSettings())
    }

    private func magnet(_ hex: String) -> URL {
        URL(string: "magnet:?xt=urn:btih:\(hex)&dn=Test")!
    }

    func test_downloadAddedAfterASecondBootstrapStillAppears() async throws {
        let engine = makeEngine()
        let vm = DownloadListViewModel(engine: engine)

        vm.bootstrap()
        try await Task.sleep(for: .milliseconds(300))

        // The window was closed and reopened: ContentView's `.task` runs again.
        vm.bootstrap()
        try await Task.sleep(for: .milliseconds(300))

        _ = await engine.addTorrent(
            magnet: magnet("c9e15763f722f23e98a29decdfae341b98d53056"),
            destinationFolder: FileManager.default.temporaryDirectory,
            startImmediately: false
        )
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(vm.rows.count, 1, "row added after a second bootstrap never reached the list")
        XCTAssertEqual(vm.count(for: StatusFilter.all), 1)
    }

    func test_singleBootstrapReceivesEvents() async throws {
        let engine = makeEngine()
        let vm = DownloadListViewModel(engine: engine)
        vm.bootstrap()
        try await Task.sleep(for: .milliseconds(300))

        _ = await engine.addTorrent(
            magnet: magnet("0123456789abcdef0123456789abcdef01234567"),
            destinationFolder: FileManager.default.temporaryDirectory,
            startImmediately: false
        )
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(vm.rows.count, 1)
    }
}
