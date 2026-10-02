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

    func test_emptyBondingObjectDecodesAsDefault() throws {
        let json = #"{"bonding":{}}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.bonding, BondingSettings())
    }

    func test_partialBondingObjectKeepsPresentFields() throws {
        let json = #"{"bonding":{"enabled":true}}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(s.bonding.enabled)
        XCTAssertTrue(s.bonding.disabledLinkIDs.isEmpty)
    }

    func test_setLinkDisabledThenEnabled() {
        var b = BondingSettings(enabled: true)
        b.setLink("en7", enabled: false)
        XCTAssertEqual(b.disabledLinkIDs, ["en7"])
        XCTAssertFalse(b.isLinkEnabled("en7"))
        b.setLink("en7", enabled: true)
        XCTAssertTrue(b.disabledLinkIDs.isEmpty)
        XCTAssertTrue(b.isLinkEnabled("en7"))
    }

    func test_setLinkIsIdempotentAndLeavesOthersAlone() {
        var b = BondingSettings(enabled: true, disabledLinkIDs: ["en5"])
        b.setLink("en7", enabled: false)
        b.setLink("en7", enabled: false)
        b.setLink("en0", enabled: true)
        XCTAssertEqual(b.disabledLinkIDs, ["en5", "en7"])
        XCTAssertTrue(b.enabled, "toggling one link must not touch the master switch")
    }
}
