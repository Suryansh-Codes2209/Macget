import XCTest
@testable import Macget

final class TorrentTrackersTests: XCTestCase {

    func test_injectsBundledTrackersIntoPublicTorrents() throws {
        let option = try XCTUnwrap(TorrentTrackers.option(isPrivate: false, enabled: true))
        XCTAssertEqual(option.split(separator: ",").count, TorrentTrackers.bundled.count)
        XCTAssertTrue(option.contains("udp://tracker.opentrackr.org:1337/announce"))
    }

    /// Announcing a private torrent to a public tracker defeats the tracker's
    /// ratio accounting and gets the user banned.
    func test_neverInjectsIntoPrivateTorrents() {
        XCTAssertNil(TorrentTrackers.option(isPrivate: true, enabled: true))
    }

    func test_respectsTheSetting() {
        XCTAssertNil(TorrentTrackers.option(isPrivate: false, enabled: false))
    }

    func test_bundledListIsWellFormed() {
        XCTAssertFalse(TorrentTrackers.bundled.isEmpty)
        for tracker in TorrentTrackers.bundled {
            XCTAssertNotNil(URL(string: tracker), "\(tracker) is not a URL")
            XCTAssertTrue(
                tracker.hasPrefix("udp://") || tracker.hasPrefix("http://") || tracker.hasPrefix("https://"),
                "\(tracker) uses a scheme no tracker speaks"
            )
            XCTAssertTrue(tracker.contains("/announce"), "\(tracker) is not an announce URL")
        }
        XCTAssertEqual(Set(TorrentTrackers.bundled).count, TorrentTrackers.bundled.count, "duplicates waste announces")
    }

    /// aria2 writes magnet metadata as `<infoHash>.torrent` beside the data,
    /// because MacGet passes --bt-save-metadata=true.
    func test_metainfoPathMatchesWhereAria2SavesIt() {
        let folder = URL(fileURLWithPath: "/tmp/dl", isDirectory: true)
        let url = TorrentTrackers.metainfoURL(infoHash: "abc123", in: folder)
        XCTAssertEqual(url.lastPathComponent, "abc123.torrent")
        XCTAssertEqual(url.deletingLastPathComponent().path, "/tmp/dl")
    }
}
