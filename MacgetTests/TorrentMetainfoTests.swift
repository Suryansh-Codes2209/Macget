import XCTest
@testable import Macget

final class TorrentMetainfoTests: XCTestCase {

    /// Builds a minimal but structurally valid metainfo. Bencode dictionary keys
    /// must be sorted, and they are here: announce < info, name < pieces < private.
    private func metainfo(pieces: [UInt8], privateFlag: Int?) -> Data {
        var info = Data("d".utf8)
        info.append(Data("4:name9:test.file".utf8))
        info.append(Data("6:pieces\(pieces.count):".utf8))
        info.append(contentsOf: pieces)
        if let privateFlag {
            info.append(Data("7:privatei\(privateFlag)e".utf8))
        }
        info.append(Data("e".utf8))

        var root = Data("d8:announce19:udp://tracker:1337/4:info".utf8)
        root.append(info)
        root.append(Data("e".utf8))
        return root
    }

    func test_detectsPrivateFlag() {
        XCTAssertTrue(TorrentMetainfo.isPrivate(metainfo(pieces: [1, 2, 3], privateFlag: 1)))
    }

    func test_privateZeroAndMissingKeyBothMeanPublic() {
        XCTAssertFalse(TorrentMetainfo.isPrivate(metainfo(pieces: [1, 2, 3], privateFlag: 0)))
        XCTAssertFalse(TorrentMetainfo.isPrivate(metainfo(pieces: [1, 2, 3], privateFlag: nil)))
    }

    /// The regression this parser exists for. `pieces` is raw SHA-1 output, so it
    /// can contain any byte sequence — including the bencode for a private flag.
    /// A substring scan would call this torrent private and strip the trackers it
    /// needs. Structural parsing skips the payload using its length prefix.
    func test_publicTorrentWhosePiecesContainThePrivateMarkerStaysPublic() {
        let trap = Array("7:privatei1e".utf8)
        let pieces = [UInt8](repeating: 0xAB, count: 8) + trap + [UInt8](repeating: 0xCD, count: 8)
        XCTAssertFalse(TorrentMetainfo.isPrivate(metainfo(pieces: pieces, privateFlag: nil)))

        // Positive control: `isPrivate` also returns false when parsing fails
        // outright, so the assertion above would pass vacuously if this fixture
        // were malformed. Proving the same fixture builder correctly reports
        // true when the private flag genuinely is set pins it as non-vacuous.
        XCTAssertTrue(TorrentMetainfo.isPrivate(metainfo(pieces: pieces, privateFlag: 1)))
    }

    /// Malformed input must read as public, never crash. Public is the safe
    /// direction: a wrongly-private torrent loses trackers with no visible cause.
    func test_malformedInputIsTreatedAsPublicWithoutCrashing() {
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data()))
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data("not bencode at all".utf8)))
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data("d4:infod7:private".utf8)))       // truncated
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data("d4:infod6:pieces99:ab".utf8)))   // length runs past end
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data("i42e".utf8)))                    // not a dictionary
    }

    /// A hostile file must not blow the stack with nesting alone.
    func test_deeplyNestedInputIsRejectedRatherThanRecursingForever() {
        let depth = 5_000
        let nested = String(repeating: "l", count: depth) + String(repeating: "e", count: depth)
        XCTAssertFalse(TorrentMetainfo.isPrivate(Data(nested.utf8)))
    }
}
