import XCTest
@testable import Macget

final class SpeedMeterTests: XCTestCase {

    func test_returnsZeroWithNoSamples() async {
        let meter = SpeedMeter()
        let speed = await meter.currentSpeed()
        XCTAssertEqual(speed, 0)
    }

    func test_returnsZeroWithSingleSample() async {
        let meter = SpeedMeter()
        await meter.record(totalBytes: 1000, at: Date())
        let speed = await meter.currentSpeed()
        XCTAssertEqual(speed, 0)
    }

    func test_speedOverWindow() async {
        let meter = SpeedMeter(windowSeconds: 3.0)
        let now = Date()
        await meter.record(totalBytes: 0,         at: now.addingTimeInterval(-3))
        await meter.record(totalBytes: 30_000_000, at: now)

        let speed = await meter.currentSpeed(now: now)
        // 30MB over 3s = 10 MB/s
        XCTAssertEqual(speed, 10_000_000, accuracy: 100_000)
    }

    func test_etaIsNilWhenSpeedTooLow() async {
        let meter = SpeedMeter(windowSeconds: 3.0)
        let now = Date()
        await meter.record(totalBytes: 0,    at: now.addingTimeInterval(-3))
        await meter.record(totalBytes: 100,  at: now)
        // ~33 B/s, well under 1 KB/s → no ETA
        let eta = await meter.eta(totalBytes: 1_000_000, now: now)
        XCTAssertNil(eta)
    }

    func test_etaCalculatesTimeRemaining() async {
        let meter = SpeedMeter(windowSeconds: 3.0)
        let now = Date()
        await meter.record(totalBytes: 0,         at: now.addingTimeInterval(-3))
        await meter.record(totalBytes: 30_000_000, at: now)
        // Speed = 10 MB/s. Remaining = 100 MB - 30 MB = 70 MB → 7 seconds.
        let eta = await meter.eta(totalBytes: 100_000_000, now: now)
        XCTAssertEqual(eta ?? 0, 7.0, accuracy: 0.5)
    }
}
