import XCTest
@testable import Macget

/// Covers the fix for a YouTube 403.
///
/// Cookies used to be passed as `--add-header "Cookie: …"`, which yt-dlp applies
/// to *every* request it makes — including the media fetch from
/// `googlevideo.com`. YouTube rejects an authenticated CDN request that carries
/// no proof-of-origin token, so the metadata probe succeeded and the download
/// died with `HTTP Error 403: Forbidden`.
///
/// A Netscape cookie jar is domain-scoped, so the session reaches `youtube.com`
/// and nothing else. These tests pin the two halves of that: the `Cookie` header
/// must never reach `--add-header`, and the jar must name only the page's domain.
final class YtDlpCookieJarTests: XCTestCase {

    private let page = URL(string: "https://www.youtube.com/watch?v=AbkEmIgJMcU")!

    // MARK: - Header splitting

    func test_cookieIsNotPassedAsAHeader() {
        let args = YtDlpRunner.headerArgs([
            "Cookie": "SID=abc; SAPISID=def",
            "Referer": "https://www.youtube.com/",
        ])
        XCTAssertFalse(args.joined(separator: " ").contains("Cookie"),
                       "the Cookie header leaks to googlevideo.com and 403s; it belongs in the jar")
        XCTAssertTrue(args.contains("Referer: https://www.youtube.com/"))
    }

    /// Browsers are inconsistent about header casing, and a case-sensitive check
    /// would let `cookie:` through the very path this fix closes.
    func test_cookieHeaderIsMatchedCaseInsensitively() {
        for key in ["Cookie", "cookie", "COOKIE"] {
            let args = YtDlpRunner.headerArgs([key: "SID=abc"])
            XCTAssertTrue(args.isEmpty, "\(key) was not recognized as a cookie header")
        }
    }

    func test_nonCookieHeadersStillBecomeAddHeaderArgs() {
        let args = YtDlpRunner.headerArgs(["User-Agent": "Mozilla/5.0"])
        XCTAssertEqual(args, ["--add-header", "User-Agent: Mozilla/5.0"])
    }

    // MARK: - Jar contents

    func test_jarScopesCookiesToThePageDomainOnly() throws {
        let jar = try XCTUnwrap(
            YtDlpRunner.netscapeCookieJar(cookieHeader: "SID=abc; SAPISID=def", pageURL: page))

        XCTAssertTrue(jar.hasPrefix("# Netscape HTTP Cookie File"))
        // The whole point: the CDN host must never appear.
        XCTAssertFalse(jar.contains("googlevideo"))
        for line in jar.split(separator: "\n") where !line.hasPrefix("#") {
            XCTAssertTrue(line.hasPrefix(".youtube.com\t"), "unexpected domain in: \(line)")
        }
    }

    func test_jarUsesTabSeparatedNetscapeFields() throws {
        let jar = try XCTUnwrap(
            YtDlpRunner.netscapeCookieJar(cookieHeader: "SID=abc", pageURL: page))
        let row = try XCTUnwrap(jar.split(separator: "\n").first { !$0.hasPrefix("#") })
        // domain, include_subdomains, path, secure, expiry, name, value
        XCTAssertEqual(row.split(separator: "\t", omittingEmptySubsequences: false).count, 7)
        XCTAssertEqual(String(row), ".youtube.com\tTRUE\t/\tTRUE\t0\tSID\tabc")
    }

    /// Session tokens are base64 and routinely contain `=`. Splitting on every
    /// `=` would truncate the value and silently break authentication.
    func test_valuesContainingEqualsSurviveIntact() throws {
        let jar = try XCTUnwrap(
            YtDlpRunner.netscapeCookieJar(cookieHeader: "TOKEN=YWJjZA==", pageURL: page))
        XCTAssertTrue(jar.contains("\tTOKEN\tYWJjZA=="), jar)
    }

    func test_wwwIsStrippedSoTheJarMatchesBareAndSubdomainHosts() throws {
        let jar = try XCTUnwrap(
            YtDlpRunner.netscapeCookieJar(cookieHeader: "SID=abc",
                                          pageURL: URL(string: "https://www.example.com/v")!))
        XCTAssertTrue(jar.contains(".example.com\t"), jar)
    }

    func test_malformedPairsAreSkippedRatherThanCorruptingTheJar() throws {
        let jar = try XCTUnwrap(
            YtDlpRunner.netscapeCookieJar(cookieHeader: "junk; SID=abc; =novalue; ",
                                          pageURL: page))
        let rows = jar.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].hasSuffix("\tSID\tabc"))
    }

    func test_noUsableCookiesYieldsNoJar() {
        XCTAssertNil(YtDlpRunner.netscapeCookieJar(cookieHeader: "", pageURL: page))
        XCTAssertNil(YtDlpRunner.netscapeCookieJar(cookieHeader: "   ; ;  ", pageURL: page))
    }
}
