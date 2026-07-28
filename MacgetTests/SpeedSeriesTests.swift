import XCTest
@testable import Macget

final class SpeedSeriesTests: XCTestCase {

    func test_emptySeriesReportsZeros() {
        let series = SpeedSeries(capacity: 10)
        XCTAssertTrue(series.isEmpty)
        XCTAssertEqual(series.current, 0)
        XCTAssertEqual(series.peak, 0)
        XCTAssertEqual(series.average, 0)
        XCTAssertNil(series.lastAppendedAt)
    }

    func test_windowDropsOldestBeyondCapacity() {
        var series = SpeedSeries(capacity: 3)
        for value in [1.0, 2.0, 3.0, 4.0] { series.append(value) }
        XCTAssertEqual(series.samples, [2, 3, 4])
        XCTAssertEqual(series.current, 4)
    }

    func test_peakAndAverageCoverTheWindowOnly() {
        var series = SpeedSeries(capacity: 3)
        // The 100 falls out of the window, so it must stop counting as the peak.
        for value in [100.0, 1.0, 2.0, 3.0] { series.append(value) }
        XCTAssertEqual(series.peak, 3)
        XCTAssertEqual(series.average, 2, accuracy: 0.0001)
    }

    func test_averageIncludesStalledSamples() {
        var series = SpeedSeries(capacity: 4)
        for value in [10.0, 0.0, 10.0, 0.0] { series.append(value) }
        XCTAssertEqual(series.average, 5, accuracy: 0.0001)
    }

    func test_negativeSamplesAreClampedToZero() {
        var series = SpeedSeries(capacity: 4)
        series.append(-5)
        XCTAssertEqual(series.current, 0)
    }

    func test_chartScaleKeepsHeadroomAboveThePeak() {
        var series = SpeedSeries(capacity: 4)
        series.append(1_000_000)
        XCTAssertGreaterThan(series.chartScale(), 1_000_000)
    }

    func test_chartScaleHasAFloorSoNoiseIsNotAmplified() {
        var series = SpeedSeries(capacity: 4)
        series.append(1)
        XCTAssertEqual(series.chartScale(minimum: 64 * 1024), 64 * 1024)
    }

    func test_smoothingAveragesNeighboursAndPreservesLength() {
        var series = SpeedSeries(capacity: 5)
        for value in [0.0, 30.0, 0.0] { series.append(value) }
        let smoothed = series.smoothed
        XCTAssertEqual(smoothed.count, 3)
        XCTAssertEqual(smoothed[1], 10, accuracy: 0.0001)
        // Edges average only the samples that exist on their side.
        XCTAssertEqual(smoothed[0], 15, accuracy: 0.0001)
    }

    func test_shortSeriesIsNotSmoothed() {
        var series = SpeedSeries(capacity: 5)
        series.append(7)
        series.append(9)
        XCTAssertEqual(series.smoothed, [7, 9])
    }

    func test_resetClearsSamplesAndTimestamp() {
        var series = SpeedSeries(capacity: 5)
        series.append(42)
        series.reset()
        XCTAssertTrue(series.isEmpty)
        XCTAssertNil(series.lastAppendedAt)
    }

    func test_appendRecordsTimestampForChartInterpolation() {
        var series = SpeedSeries(capacity: 5)
        let stamp = Date(timeIntervalSinceReferenceDate: 1_000)
        series.append(1, at: stamp)
        XCTAssertEqual(series.lastAppendedAt, stamp)
    }
}
