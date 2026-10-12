import XCTest
@testable import Macget

final class RangeResponseValidatorTests: XCTestCase {
    private func v(_ status: Int, _ cr: String? = nil, retryAfter: String? = nil, unbounded: Bool = false) -> ChunkError? {
        RangeResponseValidator.validate(status: status, contentRange: cr, retryAfter: retryAfter,
                                        expectedStart: 100, expectedEnd: 199, unbounded: unbounded)
    }

    func test_matching206IsAccepted() { XCTAssertNil(v(206, "bytes 100-199/1000")) }
    func test_206WithoutContentRangeIsAccepted() { XCTAssertNil(v(206)) }

    func test_200IsRangeRefused() {
        guard case .rangeRefused(200)? = v(200) else { return XCTFail() }
    }

    func test_wrongContentRange() {
        guard case .wrongContentRange? = v(206, "bytes 0-99/1000") else { return XCTFail() }
    }

    func test_busyCarriesRetryAfter() {
        guard case .serverBusy(503, let ra)? = v(503, retryAfter: "7") else { return XCTFail() }
        XCTAssertEqual(ra, 7)
    }

    func test_authRequired() {
        guard case .authRequired(401)? = v(401) else { return XCTFail() }
    }

    func test_unboundedAcceptsAny2xx() {
        XCTAssertNil(v(200, unbounded: true))
        guard case .unexpectedStatus(404)? = v(404, unbounded: true) else { return XCTFail() }
    }
}
