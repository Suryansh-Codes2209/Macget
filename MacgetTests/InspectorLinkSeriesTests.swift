import XCTest
@testable import Macget

final class InspectorLinkSeriesTests: XCTestCase {
    private func stat(_ id: String, _ speed: Double) -> LinkStat {
        LinkStat(linkID: id, displayName: id, kind: .wifi, speedBytesPerSec: speed, bytesThisSession: 0,
                 activeConnections: 0, status: .active, isEstimate: false)
    }

    func test_appendsOneSamplePerLink() {
        var series: [String: SpeedSeries] = [:]
        series = InspectorModel.appendLinkSamples([stat("en0", 10), stat("en7", 30)], to: series)
        series = InspectorModel.appendLinkSamples([stat("en0", 20), stat("en7", 40)], to: series)
        XCTAssertEqual(series["en0"]?.samples, [10, 20])
        XCTAssertEqual(series["en7"]?.samples, [30, 40])
    }

    func test_linkMissingFromTickGetsZeroSoSeriesStayAligned() {
        var series = InspectorModel.appendLinkSamples([stat("en0", 10), stat("en7", 30)], to: [:])
        series = InspectorModel.appendLinkSamples([stat("en0", 20)], to: series)
        XCTAssertEqual(series["en7"]?.samples, [30, 0])
    }

    func test_lateJoiningLinkIsPaddedWithZerosAndAligned() {
        var series = InspectorModel.appendLinkSamples([stat("en0", 10)], to: [:])
        series = InspectorModel.appendLinkSamples([stat("en0", 20)], to: series)
        series = InspectorModel.appendLinkSamples([stat("en0", 30), stat("en7", 5)], to: series)
        XCTAssertEqual(series["en7"]?.samples, [0, 0, 5])
        XCTAssertEqual(series["en7"]?.samples.count, series["en0"]?.samples.count)
    }
}
