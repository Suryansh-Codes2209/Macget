import XCTest
@testable import Macget

final class DownloadWindowTests: XCTestCase {

    func test_sameStartEnd_isAlwaysOpen() {
        XCTAssertTrue(DownloadWindow.isOpen(now: 0, start: 540, end: 540))
        XCTAssertTrue(DownloadWindow.isOpen(now: 1439, start: 540, end: 540))
    }

    func test_simpleWindow() {
        // 09:00 (540) .. 17:00 (1020)
        XCTAssertFalse(DownloadWindow.isOpen(now: 480, start: 540, end: 1020)) // 08:00
        XCTAssertTrue(DownloadWindow.isOpen(now: 540, start: 540, end: 1020))  // 09:00 inclusive start
        XCTAssertTrue(DownloadWindow.isOpen(now: 800, start: 540, end: 1020))
        XCTAssertFalse(DownloadWindow.isOpen(now: 1020, start: 540, end: 1020)) // 17:00 exclusive end
        XCTAssertFalse(DownloadWindow.isOpen(now: 1100, start: 540, end: 1020))
    }

    func test_wrapAroundMidnight() {
        // 22:00 (1320) .. 06:00 (360)
        XCTAssertTrue(DownloadWindow.isOpen(now: 1320, start: 1320, end: 360))  // 22:00 start
        XCTAssertTrue(DownloadWindow.isOpen(now: 1430, start: 1320, end: 360))  // 23:50
        XCTAssertTrue(DownloadWindow.isOpen(now: 0, start: 1320, end: 360))     // midnight
        XCTAssertTrue(DownloadWindow.isOpen(now: 359, start: 1320, end: 360))   // 05:59
        XCTAssertFalse(DownloadWindow.isOpen(now: 360, start: 1320, end: 360))  // 06:00 exclusive end
        XCTAssertFalse(DownloadWindow.isOpen(now: 720, start: 1320, end: 360))  // noon
    }

    func test_minutesNow() {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 25; c.hour = 14; c.minute = 30
        let date = Calendar.current.date(from: c)!
        XCTAssertEqual(DownloadWindow.minutesNow(date), 14 * 60 + 30)
    }
}
