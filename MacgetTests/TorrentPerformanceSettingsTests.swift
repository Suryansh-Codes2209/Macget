import XCTest
@testable import Macget

final class TorrentPerformanceSettingsTests: XCTestCase {

    func test_defaultsMatchTheDesignedPerformanceProfile() {
        let settings = AppSettings()
        XCTAssertEqual(settings.torrentMaxPeers, 200)
        XCTAssertTrue(settings.torrentAddPublicTrackers)
        XCTAssertFalse(settings.torrentRequireEncryption, "encryption is opt-in: requiring it shrinks the peer pool")
        XCTAssertTrue(settings.torrentAutoPortMapping)
    }

    func test_maxPeersClampsToSupportedRange() {
        XCTAssertEqual(AppSettings(torrentMaxPeers: 0).torrentMaxPeers, 1)
        XCTAssertEqual(AppSettings(torrentMaxPeers: 9_000).torrentMaxPeers, 500)
        XCTAssertEqual(AppSettings(torrentMaxPeers: 250).torrentMaxPeers, 250)
    }

    /// A settings.json written before these fields existed must still load with
    /// everything else intact — the entire reason `init(from:)` is hand-written.
    func test_settingsFileWithoutTheNewKeysLoadsWithDefaults() throws {
        let json = Data(#"{"torrentListenPort":7000,"torrentsEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(settings.torrentListenPort, 7000)
        XCTAssertTrue(settings.torrentsEnabled)
        XCTAssertEqual(settings.torrentMaxPeers, 200)
        XCTAssertTrue(settings.torrentAddPublicTrackers)
        XCTAssertFalse(settings.torrentRequireEncryption)
        XCTAssertTrue(settings.torrentAutoPortMapping)
    }

    func test_roundTripsThroughCodable() throws {
        let original = AppSettings(
            torrentMaxPeers: 321,
            torrentAddPublicTrackers: false,
            torrentRequireEncryption: true,
            torrentAutoPortMapping: false
        )
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.torrentMaxPeers, 321)
        XCTAssertFalse(decoded.torrentAddPublicTrackers)
        XCTAssertTrue(decoded.torrentRequireEncryption)
        XCTAssertFalse(decoded.torrentAutoPortMapping)
    }

    /// A clamp applied in `init` but not in `init(from:)` lets a hand-edited
    /// settings.json smuggle an out-of-range value straight into aria2.
    func test_decodeClampsOutOfRangeMaxPeers() throws {
        let json = Data(#"{"torrentMaxPeers":9000}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: json).torrentMaxPeers, 500)
    }
}
