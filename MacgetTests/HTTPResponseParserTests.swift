import XCTest
@testable import Macget

final class HTTPResponseParserTests: XCTestCase {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private func body(of events: [HTTPParseEvent]) -> Data {
        events.reduce(into: Data()) { acc, e in if case .body(let d) = e { acc.append(d) } }
    }

    private func head(of events: [HTTPParseEvent]) -> HTTPResponseHead? {
        for e in events { if case .head(let h) = e { return h } }
        return nil
    }

    private let partial = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-9/100\r\nContent-Length: 10\r\nETag: \"v1\"\r\n\r\n0123456789"

    func test_fixedLengthInOneFeed() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes(partial))
        XCTAssertEqual(head(of: events)?.status, 206)
        XCTAssertEqual(head(of: events)?.value("Content-Range"), "bytes 0-9/100")
        XCTAssertEqual(head(of: events)?.value("etag"), "\"v1\"")
        XCTAssertEqual(body(of: events), bytes("0123456789"))
        XCTAssertEqual(events.last, .end)
        XCTAssertTrue(p.isComplete)
    }

    func test_byteAtATime_matchesSingleFeed() throws {
        let chunked = "HTTP/1.1 206 Partial Content\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=1\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: y\r\n\r\n"
        for raw in [partial, chunked] {
            var whole = HTTPResponseParser()
            let expected = body(of: try whole.feed(bytes(raw)))
            var p = HTTPResponseParser()
            var events: [HTTPParseEvent] = []
            for b in bytes(raw) { events += try p.feed(Data([b])) }
            XCTAssertEqual(body(of: events), expected)
            XCTAssertEqual(events.last, .end)
            XCTAssertEqual(events.filter { if case .head = $0 { return true } else { return false } }.count, 1)
        }
    }

    func test_chunkedBody() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"))
        XCTAssertEqual(body(of: events), bytes("Wikipedia"))
        XCTAssertTrue(p.isComplete)
    }

    func test_interim100ContinueIsSkipped() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes("HTTP/1.1 100 Continue\r\n\r\n" + partial))
        XCTAssertEqual(head(of: events)?.status, 206)
        XCTAssertEqual(body(of: events), bytes("0123456789"))
    }

    func test_noContentHasNoBody() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes("HTTP/1.1 204 No Content\r\n\r\n"))
        XCTAssertEqual(events.last, .end)
    }

    func test_redirectHeadIsExposed() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes("HTTP/1.1 302 Found\r\nLocation: /real.iso\r\nContent-Length: 0\r\n\r\n"))
        XCTAssertEqual(head(of: events)?.status, 302)
        XCTAssertEqual(head(of: events)?.value("location"), "/real.iso")
        XCTAssertTrue(p.isComplete)
    }

    func test_closeDelimitedBodyEndsOnFinish() throws {
        var p = HTTPResponseParser()
        var events = try p.feed(bytes("HTTP/1.0 200 OK\r\n\r\nabc"))
        XCTAssertFalse(p.isComplete)
        events += try p.finish()
        XCTAssertEqual(body(of: events), bytes("abc"))
        XCTAssertEqual(events.last, .end)
    }

    func test_earlyCloseMidBodyThrows() throws {
        var p = HTTPResponseParser()
        _ = try p.feed(bytes("HTTP/1.1 206 Partial Content\r\nContent-Length: 10\r\n\r\n01234"))
        XCTAssertThrowsError(try p.finish()) { XCTAssertEqual($0 as? HTTPParseError, .truncatedBody) }
    }

    func test_closeBeforeHeadThrows() {
        var p = HTTPResponseParser()
        XCTAssertThrowsError(try p.finish()) { XCTAssertEqual($0 as? HTTPParseError, .truncatedBody) }
    }

    func test_malformedStatusLineThrows() {
        var p = HTTPResponseParser()
        XCTAssertThrowsError(try p.feed(bytes("SSH-2.0-OpenSSH\r\n\r\n"))) {
            XCTAssertEqual($0 as? HTTPParseError, .malformedStatusLine)
        }
    }

    func test_oversizedHeaderThrows() {
        var p = HTTPResponseParser()
        let huge = "HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: HTTPResponseParser.maxHeaderBytes + 1)
        XCTAssertThrowsError(try p.feed(bytes(huge))) { XCTAssertEqual($0 as? HTTPParseError, .headerTooLarge) }
    }

    func test_duplicateHeadersAreJoined() throws {
        var p = HTTPResponseParser()
        let events = try p.feed(bytes("HTTP/1.1 200 OK\r\nVia: a\r\nVia: b\r\nContent-Length: 0\r\n\r\n"))
        XCTAssertEqual(head(of: events)?.value("via"), "a, b")
    }
}
