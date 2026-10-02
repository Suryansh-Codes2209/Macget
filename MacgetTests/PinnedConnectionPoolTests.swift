import XCTest
@testable import Macget

final class PinnedConnectionPoolTests: XCTestCase {
    func test_idleConnectionExpiresAfterThirtySeconds() {
        let checkedIn = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(PinnedConnectionPool.isStale(checkedInAt: checkedIn, now: checkedIn))
        XCTAssertFalse(PinnedConnectionPool.isStale(checkedInAt: checkedIn, now: checkedIn.addingTimeInterval(30)))
        XCTAssertTrue(PinnedConnectionPool.isStale(checkedInAt: checkedIn, now: checkedIn.addingTimeInterval(30.5)))
    }

    func test_emptyPoolCheckoutAndPurgeAreHarmless() async {
        let pool = PinnedConnectionPool()
        let key = PinnedConnectionPool.Key(linkID: "en7", host: "example.com", port: 443, tls: true)
        let none = await pool.checkout(key)
        XCTAssertNil(none)
        await pool.purge(linkID: "en7")
        let stillNone = await pool.checkout(key)
        XCTAssertNil(stillNone)
    }
}
