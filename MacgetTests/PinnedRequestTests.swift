import XCTest
@testable import Macget

final class PinnedRequestTests: XCTestCase {
    func test_requestLineHostAndHeaders() throws {
        let data = try XCTUnwrap(PinnedRequest.bytes(
            url: URL(string: "https://cdn.example.com/files/a%20b.iso?sig=x&e=1")!,
            headers: [("Range", "bytes=0-99"), ("User-Agent", "Macget/1.0")]
        ))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /files/a%20b.iso?sig=x&e=1 HTTP/1.1\r\nHost: cdn.example.com\r\n"))
        XCTAssertTrue(text.contains("\r\nRange: bytes=0-99\r\n"))
        XCTAssertTrue(text.contains("\r\nConnection: keep-alive\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func test_nonDefaultPortInHost() throws {
        let data = try XCTUnwrap(PinnedRequest.bytes(url: URL(string: "http://example.com:8080/")!, headers: []))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Host: example.com:8080\r\n"))
    }

    func test_headerInjectionIsStripped() throws {
        let data = try XCTUnwrap(PinnedRequest.bytes(url: URL(string: "https://example.com/x")!,
                                                     headers: [("Cookie", "a=1\r\nEvil: yes")]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("\r\nEvil: yes"))
    }

    func test_emptyPathBecomesSlash() throws {
        let data = try XCTUnwrap(PinnedRequest.bytes(url: URL(string: "https://example.com")!, headers: []))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("GET / HTTP/1.1\r\n"))
    }
}
