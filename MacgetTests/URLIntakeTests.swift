import XCTest
@testable import Macget

/// Covers what MacGet accepts from an *external* entry point — an OS URL open, a
/// Dock drop, the Add sheet.
///
/// These paths used to reuse `parsePlausibleHTTPURL`, which rejects everything
/// that isn't http(s). Since `Info.plist` registers MacGet as a `magnet:`
/// handler, clicking a magnet launched the app and the URL was then dropped on
/// the floor — the app opened and nothing else happened.
final class URLIntakeTests: XCTestCase {

    // MARK: - Magnets

    func test_acceptsMagnet() {
        let magnet = "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056&dn=Some+Name"
        XCTAssertEqual(URLValidation.parseAcceptableDownloadURL(magnet)?.absoluteString, magnet)
    }

    func test_acceptsMagnetWithBase32InfoHash() {
        let magnet = "magnet:?xt=urn:btih:ZHQVOY7XELZD5GFCTXWN7LRUDOMNKMCW"
        XCTAssertNotNil(URLValidation.parseAcceptableDownloadURL(magnet))
    }

    /// A magnet with no usable `xt` names no torrent, so there is nothing to add.
    func test_rejectsMagnetWithoutInfoHash() {
        XCTAssertNil(URLValidation.parseAcceptableDownloadURL("magnet:?dn=no+hash+here"))
    }

    /// Real magnets carry a long tracker list; the 2048-char http cap would cut
    /// them off.
    func test_acceptsMagnetLongerThanTheHTTPLengthCap() {
        let trackers = (0..<80)
            .map { "&tr=udp%3A%2F%2Ftracker\($0).example.com%3A6969%2Fannounce" }
            .joined()
        let magnet = "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056" + trackers
        XCTAssertGreaterThan(magnet.count, 2048)
        XCTAssertNotNil(URLValidation.parseAcceptableDownloadURL(magnet))
    }

    // MARK: - Torrent files

    func test_acceptsLocalTorrentFile() {
        let url = URL(fileURLWithPath: "/Users/someone/Downloads/ubuntu.torrent")
        XCTAssertEqual(URLValidation.parseAcceptableDownloadURL(url.absoluteString), url)
    }

    /// Only `.torrent` — a `file://` URL is otherwise not something to download.
    func test_rejectsOtherLocalFiles() {
        let url = URL(fileURLWithPath: "/etc/passwd")
        XCTAssertNil(URLValidation.parseAcceptableDownloadURL(url.absoluteString))
    }

    func test_acceptsRemoteTorrentFile() {
        let raw = "https://archive.org/download/item/item_archive.torrent"
        XCTAssertEqual(URLValidation.parseAcceptableDownloadURL(raw)?.absoluteString, raw)
    }

    // MARK: - Ordinary HTTP, unchanged

    func test_acceptsHTTPURL() {
        let raw = "https://example.com/file.zip"
        XCTAssertEqual(URLValidation.parseAcceptableDownloadURL(raw)?.absoluteString, raw)
    }

    func test_rejectsUnrelatedSchemes() {
        XCTAssertNil(URLValidation.parseAcceptableDownloadURL("ftp://example.com/file.zip"))
        XCTAssertNil(URLValidation.parseAcceptableDownloadURL("javascript:alert(1)"))
        XCTAssertNil(URLValidation.parseAcceptableDownloadURL(""))
    }

    func test_rejectsHTTPURLWithoutHost() {
        XCTAssertNil(URLValidation.parseAcceptableDownloadURL("https:///nohost"))
    }

    func test_trimsSurroundingWhitespace() {
        XCTAssertEqual(
            URLValidation.parseAcceptableDownloadURL("  https://example.com/a.zip\n")?.absoluteString,
            "https://example.com/a.zip"
        )
    }
}

/// Adding the same magnet twice must not create a second row.
///
/// Clicking a magnet link again while the first is still fetching metadata used
/// to enqueue it a second time; aria2 rejected the duplicate info hash and the
/// row went `failed`, so a working download sat next to a broken-looking twin.
final class DuplicateTorrentAddTests: XCTestCase {

    private func makeEngine() async -> DownloadEngine {
        let store = DownloadStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-\(UUID().uuidString).json"))
        return DownloadEngine(store: store, settings: AppSettings())
    }

    func test_sameMagnetAddedTwice_reusesTheExistingRow() async {
        let engine = await makeEngine()
        let magnet = URL(string: "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056&dn=Dup")!
        let dest = FileManager.default.temporaryDirectory

        let first = await engine.addTorrent(magnet: magnet, destinationFolder: dest, startImmediately: false)
        let second = await engine.addTorrent(magnet: magnet, destinationFolder: dest, startImmediately: false)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "the second add should return the existing row, not a new one")
        let all = await engine.currentDownloads()
        XCTAssertEqual(all.filter { $0.kind == .torrent }.count, 1)
    }

    func test_differentMagnetsBothAdd() async {
        let engine = await makeEngine()
        let dest = FileManager.default.temporaryDirectory
        let a = URL(string: "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056")!
        let b = URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")!

        let first = await engine.addTorrent(magnet: a, destinationFolder: dest, startImmediately: false)
        let second = await engine.addTorrent(magnet: b, destinationFolder: dest, startImmediately: false)

        XCTAssertNotEqual(first, second)
        let all = await engine.currentDownloads()
        XCTAssertEqual(all.filter { $0.kind == .torrent }.count, 2)
    }
}
