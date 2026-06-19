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
}
