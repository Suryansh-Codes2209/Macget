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

    func test_settingsDoNotCarryAddresses() {
        // Addresses come from live links, never from persisted settings.
        var settings = AppSettings()
        settings.bonding = BondingSettings(enabled: true)
        XCTAssertEqual(settings.torrentOptions.bondingAddresses, [])
    }
}
