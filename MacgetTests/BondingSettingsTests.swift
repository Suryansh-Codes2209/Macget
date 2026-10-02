import XCTest
@testable import Macget

final class BondingSettingsTests: XCTestCase {
    func test_defaultsAreOff() {
        let s = AppSettings()
        XCTAssertFalse(s.bonding.enabled)
        XCTAssertTrue(s.bonding.disabledLinkIDs.isEmpty)
    }

    func test_settingsWithoutBondingKeyDecodeAsDefault() throws {
        // A settings.json written before this feature existed.
        let json = #"{"defaultThreadCount": 6}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.bonding, BondingSettings())
        XCTAssertEqual(s.defaultThreadCount, 6)
    }

    func test_roundTrips() throws {
        var s = AppSettings()
        s.bonding = BondingSettings(enabled: true, disabledLinkIDs: ["en7"])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded.bonding, s.bonding)
    }

    func test_isLinkEnabled() {
        let b = BondingSettings(enabled: true, disabledLinkIDs: ["en7"])
        XCTAssertTrue(b.isLinkEnabled("en0"))
        XCTAssertFalse(b.isLinkEnabled("en7"))
    }
}
