import XCTest
@testable import Macget

/// Stub protocol that serves a fixed body. When `includeContentLength` is false
/// it mimics a server using chunked transfer / no `Content-Length` — the case
/// that used to fail the whole download with "Server did not report file size."
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var includeContentLength = false
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var headers: [String: String] = [:]
        if Self.includeContentLength {
            headers["Content-Length"] = String(Self.body.count)
        }
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        // HEAD probe has no use for the body; only the GET stream consumes it.
        if request.httpMethod != "HEAD" {
            client?.urlProtocol(self, didLoad: Self.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class UnknownSizeDownloadTests: XCTestCase {

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func test_noContentLength_completesViaStreamingPath() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 & 0xFF) })  // ~195 KB
        StubURLProtocol.body = payload
        StubURLProtocol.includeContentLength = false
        StubURLProtocol.statusCode = 200

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macget-unknownsize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let download = Download(
            url: URL(string: "https://example.com/movie.zip")!,
            destinationFolder: dir,
            filename: "movie.zip"
        )

        let done = expectation(description: "reaches a terminal state")
        let finalState = StateBox()

        let coordinator = DownloadCoordinator(
            download: download,
            session: makeStubSession(),
            onStateChange: { d in
                if d.status.isTerminal {
                    await finalState.set(d)
                    done.fulfill()
                }
            },
            onSnapshot: { _ in }
        )

        await coordinator.start()
        await fulfillment(of: [done], timeout: 10)

        let result = await finalState.value
        XCTAssertEqual(result?.status, .completed, "expected completion, got error: \(result?.error ?? "nil")")
        XCTAssertEqual(result?.totalBytes, Int64(payload.count))

        let onDisk = try Data(contentsOf: dir.appendingPathComponent("movie.zip"))
        XCTAssertEqual(onDisk, payload)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: download.partialFileURL.path),
            "partial file should be moved, not left behind"
        )
    }
}

/// Sendable holder so the @Sendable callback can stash the terminal Download.
private actor StateBox {
    private(set) var value: Download?
    func set(_ d: Download) { value = d }
}
