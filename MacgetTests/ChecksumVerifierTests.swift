import XCTest
import CryptoKit
@testable import Macget

final class ChecksumVerifierTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ChecksumTests-\(UUID())")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func write(_ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent("\(UUID()).bin")
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - hexDigest (known vectors)

    func test_sha256OfEmptyString() throws {
        let url = try write("")
        XCTAssertEqual(
            try ChecksumVerifier.hexDigest(of: url, algorithm: .sha256),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func test_sha256OfAbc() throws {
        let url = try write("abc")
        XCTAssertEqual(
            try ChecksumVerifier.hexDigest(of: url, algorithm: .sha256),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func test_md5OfAbc() throws {
        let url = try write("abc")
        XCTAssertEqual(
            try ChecksumVerifier.hexDigest(of: url, algorithm: .md5),
            "900150983cd24fb0d6963f7d28e17f72"
        )
    }

    // MARK: - verify

    func test_verifyPassesOnMatch_caseInsensitive() throws {
        let url = try write("abc")
        XCTAssertNoThrow(try ChecksumVerifier.verify(
            fileAt: url,
            expectedHex: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD",
            algorithm: .sha256
        ))
    }

    func test_verifyThrowsOnMismatch() throws {
        let url = try write("abc")
        XCTAssertThrowsError(try ChecksumVerifier.verify(
            fileAt: url,
            expectedHex: String(repeating: "0", count: 64),
            algorithm: .sha256
        )) { error in
            guard case ChecksumError.mismatch = error else {
                return XCTFail("expected mismatch, got \(error)")
            }
        }
    }

    func test_verifyNoOpWhenNoExpected() throws {
        let url = try write("abc")
        XCTAssertNoThrow(try ChecksumVerifier.verify(fileAt: url, expectedHex: nil, algorithm: nil))
        XCTAssertNoThrow(try ChecksumVerifier.verify(fileAt: url, expectedHex: "   ", algorithm: .sha256))
    }

    // MARK: - ChecksumSpec.parse

    func test_parsesSha256Fragment() {
        let hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let spec = ChecksumSpec.parse(fragment: "sha256=\(hex)")
        XCTAssertEqual(spec, ChecksumSpec(algorithm: .sha256, hex: hex))
    }

    func test_parsesMd5AndNormalizesDashAndCase() {
        let spec = ChecksumSpec.parse(fragment: "SHA-256=BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
        XCTAssertEqual(spec?.algorithm, .sha256)
        XCTAssertEqual(spec?.hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func test_rejectsWrongLengthDigest() {
        XCTAssertNil(ChecksumSpec.parse(fragment: "sha256=deadbeef"))
        XCTAssertNil(ChecksumSpec.parse(fragment: "md5=notvalidhexxx"))
        XCTAssertNil(ChecksumSpec.parse(fragment: nil))
        XCTAssertNil(ChecksumSpec.parse(fragment: "page-section"))
    }
}
