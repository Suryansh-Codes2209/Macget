import XCTest
@testable import Macget

final class RateLimiterTests: XCTestCase {

    func test_noWaitWhenTokensCoverRequest() {
        // 1 MB/s bucket, full, asking for 100 KB → no wait.
        let d = RateLimiter.delaySeconds(tokens: 1_048_576, rate: 1_048_576, requested: 102_400, elapsed: 0)
        XCTAssertEqual(d, 0)
    }

    func test_waitWhenDeficit() {
        // Empty bucket, 1 MB/s, asking for 1 MB, no time elapsed → ~1s wait.
        let d = RateLimiter.delaySeconds(tokens: 0, rate: 1_048_576, requested: 1_048_576, elapsed: 0)
        XCTAssertEqual(d, 1.0, accuracy: 0.001)
    }

    func test_elapsedTimeRefillsTokens() {
        // Empty bucket but 0.5s elapsed at 1 MB/s → 512 KB available; asking 512 KB → no wait.
        let d = RateLimiter.delaySeconds(tokens: 0, rate: 1_048_576, requested: 524_288, elapsed: 0.5)
        XCTAssertEqual(d, 0, accuracy: 0.0001)
    }

    func test_refillIsCappedAtOneSecondBurst() {
        // 10s elapsed can't bank more than 1s of tokens; asking 2 MB at 1 MB/s → ~1s wait.
        let d = RateLimiter.delaySeconds(tokens: 0, rate: 1_048_576, requested: 2 * 1_048_576, elapsed: 10)
        XCTAssertEqual(d, 1.0, accuracy: 0.001)
    }

    func test_unlimitedRateNeverWaits() {
        XCTAssertEqual(RateLimiter.delaySeconds(tokens: 0, rate: 0, requested: 9_999_999, elapsed: 0), 0)
    }

    func test_consumeIsNoOpWhenUnlimited() async {
        let limiter = RateLimiter(bytesPerSecond: nil)
        // Should return immediately without throttling.
        await limiter.consume(10_000_000)
    }
}
