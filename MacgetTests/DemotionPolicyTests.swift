import XCTest
@testable import Macget

final class DemotionPolicyTests: XCTestCase {

    func test_doesNotDemoteBelowThreshold() {
        XCTAssertFalse(DemotionPolicy.shouldDemote(
            failureCount: DemotionPolicy.threshold - 1,
            throughputBytesPerSecond: 10 * 1024 * 1024
        ))
    }

    func test_demotesAtThresholdWhileBytesStillFlowing() {
        // The hostile-host signature: some workers are being refused while the
        // survivors keep streaming at full speed.
        XCTAssertTrue(DemotionPolicy.shouldDemote(
            failureCount: DemotionPolicy.threshold,
            throughputBytesPerSecond: 10 * 1024 * 1024
        ))
    }

    func test_doesNotDemoteWhenNothingIsMoving() {
        // The network-fault signature: every worker failed at once and aggregate
        // throughput collapsed. Blaming the host here would write a cap that
        // outlives the outage and is never revisited.
        XCTAssertFalse(DemotionPolicy.shouldDemote(
            failureCount: DemotionPolicy.threshold * 3,
            throughputBytesPerSecond: 0
        ))
    }

    func test_dyingTrickleDoesNotCountAsHealthy() {
        // A connection limping along below the cutoff is not evidence that the
        // host is happily serving other workers.
        XCTAssertFalse(DemotionPolicy.shouldDemote(
            failureCount: DemotionPolicy.threshold,
            throughputBytesPerSecond: DemotionPolicy.healthyThroughputBytesPerSecond - 1
        ))
    }

    func test_demotesExactlyAtHealthyThroughputBoundary() {
        XCTAssertTrue(DemotionPolicy.shouldDemote(
            failureCount: DemotionPolicy.threshold,
            throughputBytesPerSecond: DemotionPolicy.healthyThroughputBytesPerSecond
        ))
    }

    func test_customThresholds() {
        XCTAssertTrue(DemotionPolicy.shouldDemote(
            failureCount: 2,
            throughputBytesPerSecond: 100,
            threshold: 2,
            healthyThroughput: 50
        ))
        XCTAssertFalse(DemotionPolicy.shouldDemote(
            failureCount: 2,
            throughputBytesPerSecond: 100,
            threshold: 3,
            healthyThroughput: 50
        ))
    }
}
