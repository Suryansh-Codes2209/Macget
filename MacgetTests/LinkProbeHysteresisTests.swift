import XCTest
@testable import Macget

final class LinkProbeHysteresisTests: XCTestCase {
    func test_upLinkSurvivesOneFailedProbe() {
        let first = LinkProbeHysteresis.next(wasSatisfied: true, probeSucceeded: false, failureStreak: 0)
        XCTAssertTrue(first.satisfied, "one missed probe (saturated tether) must not drop the link")
        XCTAssertEqual(first.failureStreak, 1)
    }

    func test_upLinkDropsAfterTwoConsecutiveFailures() {
        let second = LinkProbeHysteresis.next(wasSatisfied: true, probeSucceeded: false, failureStreak: 1)
        XCTAssertFalse(second.satisfied)
        XCTAssertEqual(second.failureStreak, 2)
    }

    func test_successResetsTheStreak() {
        let ok = LinkProbeHysteresis.next(wasSatisfied: true, probeSucceeded: true, failureStreak: 1)
        XCTAssertTrue(ok.satisfied)
        XCTAssertEqual(ok.failureStreak, 0)
        // So a later single failure is again tolerated.
        let after = LinkProbeHysteresis.next(wasSatisfied: true, probeSucceeded: false, failureStreak: ok.failureStreak)
        XCTAssertTrue(after.satisfied)
    }

    func test_downLinkComesUpOnFirstSuccessAndStaysDownOnFailure() {
        XCTAssertTrue(LinkProbeHysteresis.next(wasSatisfied: false, probeSucceeded: true, failureStreak: 3).satisfied)
        XCTAssertFalse(LinkProbeHysteresis.next(wasSatisfied: false, probeSucceeded: false, failureStreak: 0).satisfied)
    }
}
