import XCTest
@testable import Macget

final class RequestHeaderPolicyTests: XCTestCase {

    // MARK: - sanitizeInbound

    func test_sanitize_stripsHopByHopAndEngineControlled() {
        let input = [
            "Cookie": "session=abc",
            "Referer": "https://example.com",
            "Range": "bytes=0-100",          // engine-controlled, must drop
            "Host": "evil.test",             // must drop
            "Transfer-Encoding": "chunked",  // hop-by-hop, must drop
            "If-Range": "\"etag\"",          // must drop
        ]
        let out = RequestHeaderPolicy.sanitizeInbound(input)!
        XCTAssertEqual(out["Cookie"], "session=abc")
        XCTAssertEqual(out["Referer"], "https://example.com")
        XCTAssertNil(out["Range"])
        XCTAssertNil(out["Host"])
        XCTAssertNil(out["Transfer-Encoding"])
        XCTAssertNil(out["If-Range"])
    }

    func test_sanitize_isCaseInsensitive() {
        let out = RequestHeaderPolicy.sanitizeInbound(["RANGE": "bytes=0-1", "user-agent": "x"])!
        XCTAssertNil(out["RANGE"])
        XCTAssertEqual(out["user-agent"], "x")
    }

    func test_sanitize_nilWhenNothingRemains() {
        XCTAssertNil(RequestHeaderPolicy.sanitizeInbound(["Range": "bytes=0-1"]))
        XCTAssertNil(RequestHeaderPolicy.sanitizeInbound(nil))
    }

    // MARK: - strippingSensitive

    func test_strippingSensitive_dropsSecrets() {
        let out = RequestHeaderPolicy.strippingSensitive([
            "Cookie": "secret",
            "Authorization": "Bearer t",
            "Referer": "https://example.com",
        ])!
        XCTAssertNil(out["Cookie"])
        XCTAssertNil(out["Authorization"])
        XCTAssertEqual(out["Referer"], "https://example.com")
    }

    // MARK: - Download persistence redaction

    func test_download_doesNotPersistCookies() throws {
        let d = Download(
            url: URL(string: "https://example.com/f")!,
            destinationFolder: URL(fileURLWithPath: "/tmp"),
            filename: "f",
            requestHeaders: ["Cookie": "session=abc", "Referer": "https://example.com"]
        )
        let encoded = try JSONEncoder().encode(d)
        let json = String(data: encoded, encoding: .utf8)!
        XCTAssertFalse(json.contains("session=abc"), "Cookie value must not be persisted")

        // Round-trips without the secret but keeps the non-secret header.
        let decoded = try JSONDecoder().decode(Download.self, from: encoded)
        XCTAssertNil(decoded.requestHeaders?["Cookie"])
        XCTAssertEqual(decoded.requestHeaders?["Referer"], "https://example.com")
    }

    func test_download_decodesLegacyJSONWithoutNewFields() throws {
        // A queue.json written before userSpecifiedFilename/requestHeaders existed.
        let legacy = """
        {"id":"\(UUID().uuidString)","url":"https://example.com/f","destinationFolder":"file:///tmp/",
         "filename":"f","status":"queued","threadCount":8,"supportsRange":false,"chunks":[],
         "createdAt":"2024-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let d = try decoder.decode(Download.self, from: legacy)
        XCTAssertFalse(d.userSpecifiedFilename)
        XCTAssertNil(d.requestHeaders)
    }
}
