import XCTest
@testable import Macget

final class LinkAddressesTests: XCTestCase {
    func test_normalizeDropsLinkLocalAndScope() {
        XCTAssertNil(LinkAddresses.normalize("fe80::1%en0"))
        XCTAssertNil(LinkAddresses.normalize("169.254.3.4"))
        XCTAssertEqual(LinkAddresses.normalize("2001:db8::5%en0"), "2001:db8::5")
        XCTAssertEqual(LinkAddresses.normalize("192.168.0.5"), "192.168.0.5")
    }

    func test_byInterfaceReturnsLoopbackOnAnyMac() {
        // Sanity check that getifaddrs plumbing works at all.
        XCTAssertEqual(LinkAddresses.byInterface()["lo0"]?.contains("127.0.0.1"), true)
    }
}
