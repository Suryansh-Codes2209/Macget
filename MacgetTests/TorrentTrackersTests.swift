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

    func test_addPublicTrackersFlowsFromSettingsToEngineOptions() {
        XCTAssertTrue(AppSettings().torrentOptions.addPublicTrackers)
        XCTAssertFalse(AppSettings(torrentAddPublicTrackers: false).torrentOptions.addPublicTrackers)
    }
}

/// The add-time decision, extracted so it can be tested without a daemon.
final class TorrentTrackerDecisionTests: XCTestCase {

    private func metainfo(privateFlag: Int?) -> Data {
        // "4:test" is a 4-byte string — the length prefix must match exactly or
        // the parser reads the next key from the middle of this value.
        var info = Data("d4:name4:test".utf8)
        // (no pieces: the parser doesn't require them and this keeps the fixture small)
        if let privateFlag { info.append(Data("7:privatei\(privateFlag)e".utf8)) }
        info.append(Data("e".utf8))
        var root = Data("d4:info".utf8)
        root.append(info)
        root.append(Data("e".utf8))
        return root
    }

    func test_publicTorrentFileGetsTrackers() {
        XCTAssertNotNil(TorrentJob.trackerOption(
            torrentFileData: metainfo(privateFlag: nil), addPublicTrackers: true))
    }

    func test_privateTorrentFileGetsNone() {
        XCTAssertNil(TorrentJob.trackerOption(
            torrentFileData: metainfo(privateFlag: 1), addPublicTrackers: true))
    }

    /// A magnet has no metainfo yet, so it gets trackers and is corrected later.
    func test_magnetWithNoMetainfoYetStillGetsTrackers() {
        XCTAssertNotNil(TorrentJob.trackerOption(torrentFileData: nil, addPublicTrackers: true))
    }

    func test_settingOffMeansNoneEverywhere() {
        XCTAssertNil(TorrentJob.trackerOption(torrentFileData: nil, addPublicTrackers: false))
        XCTAssertNil(TorrentJob.trackerOption(
            torrentFileData: metainfo(privateFlag: nil), addPublicTrackers: false))
    }
}
