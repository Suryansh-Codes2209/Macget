import XCTest
@testable import Macget

final class RetryBackoffTests: XCTestCase {

    // MARK: - RetryAfter parsing

    func test_parsesDeltaSeconds() {
        XCTAssertEqual(RetryAfter.parse("120"), 120)
        XCTAssertEqual(RetryAfter.parse("  0 "), 0)
    }

    func test_rejectsNegativeAndJunk() {
        XCTAssertNil(RetryAfter.parse("-5"))
        XCTAssertNil(RetryAfter.parse("soon"))
        XCTAssertNil(RetryAfter.parse(nil))
        XCTAssertNil(RetryAfter.parse(""))
    }

    func test_parsesHTTPDateRelativeToNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 30 seconds after `now`, formatted as an RFC 1123 GMT date.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let header = f.string(from: now.addingTimeInterval(30))

        let parsed = RetryAfter.parse(header, now: now)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!, 30, accuracy: 1.0)
    }

    func test_pastHTTPDateClampsToZero() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let parsed = RetryAfter.parse("Wed, 21 Oct 1999 07:28:00 GMT", now: now)
        XCTAssertEqual(parsed, 0)
    }

    // MARK: - Backoff calculation

    func test_retryAfterHonoredAndClamped() {
        // Explicit Retry-After wins over exponential growth …
        XCTAssertEqual(DownloadCoordinator.retryDelaySeconds(attempt: 1, retryAfter: 10, random01: 0.5), 10)
        // … but is clamped to the Retry-After ceiling.
        XCTAssertEqual(
            DownloadCoordinator.retryDelaySeconds(attempt: 1, retryAfter: 9999, random01: 0.5),
            DownloadCoordinator.retryAfterMaxDelay
        )
    }

    func test_jitterStaysWithinBounds() {
        // For each attempt, the delay must land in [0.5, 1.0]·capped-exponential.
        for attempt in 1...8 {
            let expBase = min(
                DownloadCoordinator.retryBaseDelay * pow(2.0, Double(attempt - 1)),
                DownloadCoordinator.retryMaxDelay
            )
            for sample in [0.0, 0.25, 0.5, 0.999] {
                let d = DownloadCoordinator.retryDelaySeconds(attempt: attempt, retryAfter: nil, random01: sample)
                XCTAssertGreaterThanOrEqual(d, expBase * 0.5 - 0.0001)
                XCTAssertLessThanOrEqual(d, expBase + 0.0001)
            }
        }
    }

    func test_backoffIsCapped() {
        // A very high attempt still can't exceed the cap (with full jitter).
        let d = DownloadCoordinator.retryDelaySeconds(attempt: 30, retryAfter: nil, random01: 1.0)
        XCTAssertLessThanOrEqual(d, DownloadCoordinator.retryMaxDelay)
    }

    func test_zeroRetryAfterFallsBackToExponential() {
        // retryAfter == 0 is not a useful backoff signal → use the jittered curve.
        let d = DownloadCoordinator.retryDelaySeconds(attempt: 1, retryAfter: 0, random01: 1.0)
        XCTAssertEqual(d, DownloadCoordinator.retryBaseDelay, accuracy: 0.0001)
    }
}
