import XCTest
@testable import Macget

final class RangeProbeTests: XCTestCase {

    // MARK: - Content-Disposition parsing

    func test_parsesQuotedFilename() {
        XCTAssertEqual(
            RangeProbe.parseContentDispositionFilename(#"attachment; filename="real.pdf""#),
            "real.pdf"
        )
    }

    func test_parsesUnquotedFilename() {
        XCTAssertEqual(
            RangeProbe.parseContentDispositionFilename("attachment; filename=real.pdf"),
            "real.pdf"
        )
    }

    func test_stopsAtTrailingParameters() {
        XCTAssertEqual(
            RangeProbe.parseContentDispositionFilename("attachment; filename=real.pdf; size=100"),
            "real.pdf"
        )
    }

    func test_nilHeaderYieldsNil() {
        XCTAssertNil(RangeProbe.parseContentDispositionFilename(nil))
    }

    func test_inlineWithoutFilenameYieldsNil() {
        XCTAssertNil(RangeProbe.parseContentDispositionFilename("inline"))
    }

    func test_emptyFilenameYieldsNil() {
        XCTAssertNil(RangeProbe.parseContentDispositionFilename(#"attachment; filename="""#))
    }

    // MARK: - RFC 5987 extended filename

    func test_parsesExtendedUTF8Filename() {
        XCTAssertEqual(
            RangeProbe.parseContentDispositionFilename("attachment; filename*=UTF-8''%E2%82%AC%20rates.txt"),
            "€ rates.txt"
        )
    }

    func test_extendedFormTakesPrecedenceOverPlain() {
        XCTAssertEqual(
            RangeProbe.parseContentDispositionFilename(#"attachment; filename="ascii.txt"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf"#),
            "résumé.pdf"
        )
    }

    func test_extendedFormWithoutCharsetPrefix() {
        // No `charset'lang'` prefix — treat the remainder as percent-encoded.
        XCTAssertEqual(
            RangeProbe.parseContentDispositionFilename("attachment; filename*=caf%C3%A9.txt"),
            "café.txt"
        )
    }
}
