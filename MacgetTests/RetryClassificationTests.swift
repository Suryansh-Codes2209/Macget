import XCTest
@testable import Macget

final class RetryClassificationTests: XCTestCase {

    private func nsURLError(_ code: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code)
    }

    // Regression: server killed an in-flight response (Cloudflare Worker
    // duration limit, abrupt connection reset). Was incorrectly terminal.
    func test_cannotParseResponseIsRetryable() {
        XCTAssertTrue(DownloadCoordinator.isRetryable(nsURLError(NSURLErrorCannotParseResponse)))
    }

    func test_badServerResponseIsRetryable() {
        XCTAssertTrue(DownloadCoordinator.isRetryable(nsURLError(NSURLErrorBadServerResponse)))
    }

    func test_transientNetworkErrorsAreRetryable() {
        XCTAssertTrue(DownloadCoordinator.isRetryable(nsURLError(NSURLErrorTimedOut)))
        XCTAssertTrue(DownloadCoordinator.isRetryable(nsURLError(NSURLErrorNetworkConnectionLost)))
        XCTAssertTrue(DownloadCoordinator.isRetryable(nsURLError(NSURLErrorCannotConnectToHost)))
    }

    func test_permanentURLErrorsAreNotRetryable() {
        XCTAssertFalse(DownloadCoordinator.isRetryable(nsURLError(NSURLErrorUnsupportedURL)))
        XCTAssertFalse(DownloadCoordinator.isRetryable(nsURLError(NSURLErrorBadURL)))
    }

    func test_nonURLErrorsAreRetryable() {
        // Custom errors (e.g. ChunkError.unexpectedStatus) fall through to true
        // and are routed by the ChunkError-specific switch in the coordinator.
        struct Marker: Error {}
        XCTAssertTrue(DownloadCoordinator.isRetryable(Marker()))
    }

    func test_terminalHTTPStatusCodes() {
        XCTAssertTrue(DownloadCoordinator.isTerminalHTTPStatus(401))
        XCTAssertTrue(DownloadCoordinator.isTerminalHTTPStatus(403))
        XCTAssertTrue(DownloadCoordinator.isTerminalHTTPStatus(404))
        XCTAssertTrue(DownloadCoordinator.isTerminalHTTPStatus(410))
        XCTAssertTrue(DownloadCoordinator.isTerminalHTTPStatus(451))
    }

    func test_transientHTTPStatusCodesAreNotTerminal() {
        XCTAssertFalse(DownloadCoordinator.isTerminalHTTPStatus(408))
        XCTAssertFalse(DownloadCoordinator.isTerminalHTTPStatus(429))
        XCTAssertFalse(DownloadCoordinator.isTerminalHTTPStatus(500))
        XCTAssertFalse(DownloadCoordinator.isTerminalHTTPStatus(502))
        XCTAssertFalse(DownloadCoordinator.isTerminalHTTPStatus(503))
        XCTAssertFalse(DownloadCoordinator.isTerminalHTTPStatus(504))
    }

    func test_successCodesAreNotTerminal() {
        XCTAssertFalse(DownloadCoordinator.isTerminalHTTPStatus(200))
        XCTAssertFalse(DownloadCoordinator.isTerminalHTTPStatus(206))
    }

    // MARK: - isPermanentChunkError

    func test_chunkErrorTerminalCasesArePermanent() {
        XCTAssertTrue(DownloadCoordinator.isPermanentChunkError(ChunkError.rangeRefused(200)))
        XCTAssertTrue(DownloadCoordinator.isPermanentChunkError(ChunkError.wrongContentRange(expected: "x", got: "y")))
        XCTAssertTrue(DownloadCoordinator.isPermanentChunkError(ChunkError.chunkNotFound))
        XCTAssertTrue(DownloadCoordinator.isPermanentChunkError(ChunkError.writerUnavailable))
    }

    func test_terminalHTTPStatusViaChunkErrorIsPermanent() {
        XCTAssertTrue(DownloadCoordinator.isPermanentChunkError(ChunkError.unexpectedStatus(403)))
        XCTAssertTrue(DownloadCoordinator.isPermanentChunkError(ChunkError.unexpectedStatus(404)))
    }

    func test_transientHTTPStatusViaChunkErrorIsNotPermanent() {
        XCTAssertFalse(DownloadCoordinator.isPermanentChunkError(ChunkError.unexpectedStatus(429)))
        XCTAssertFalse(DownloadCoordinator.isPermanentChunkError(ChunkError.unexpectedStatus(500)))
        XCTAssertFalse(DownloadCoordinator.isPermanentChunkError(ChunkError.unexpectedStatus(503)))
    }

    func test_connectionLossErrorsAreNotPermanent() {
        // The whole point of the demotion architecture: -1005 from anti-leech hosts
        // must be treated as transient so the orchestrator can downscale and retry.
        XCTAssertFalse(DownloadCoordinator.isPermanentChunkError(nsURLError(NSURLErrorNetworkConnectionLost)))
        XCTAssertFalse(DownloadCoordinator.isPermanentChunkError(nsURLError(NSURLErrorCannotParseResponse)))
        XCTAssertFalse(DownloadCoordinator.isPermanentChunkError(nsURLError(NSURLErrorTimedOut)))
    }

    func test_badURLIsPermanent() {
        XCTAssertTrue(DownloadCoordinator.isPermanentChunkError(nsURLError(NSURLErrorBadURL)))
        XCTAssertTrue(DownloadCoordinator.isPermanentChunkError(nsURLError(NSURLErrorUnsupportedURL)))
    }
}
