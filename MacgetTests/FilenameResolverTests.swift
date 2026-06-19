import XCTest
@testable import Macget

final class FilenameResolverTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("FilenameResolverTests-\(UUID())")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func test_returnsOriginalWhenFree() {
        let url = FilenameResolver.uniqueURL(in: tmpDir, preferredName: "file.zip")
        XCTAssertEqual(url.lastPathComponent, "file.zip")
    }

    func test_appendsCounterWhenTaken() throws {
        try Data().write(to: tmpDir.appendingPathComponent("file.zip"))
        let url = FilenameResolver.uniqueURL(in: tmpDir, preferredName: "file.zip")
        XCTAssertEqual(url.lastPathComponent, "file (2).zip")
    }

    func test_keepsAppendingUntilUnique() throws {
        try Data().write(to: tmpDir.appendingPathComponent("file.zip"))
        try Data().write(to: tmpDir.appendingPathComponent("file (2).zip"))
        try Data().write(to: tmpDir.appendingPathComponent("file (3).zip"))
        let url = FilenameResolver.uniqueURL(in: tmpDir, preferredName: "file.zip")
        XCTAssertEqual(url.lastPathComponent, "file (4).zip")
    }

    func test_handlesNoExtension() throws {
        try Data().write(to: tmpDir.appendingPathComponent("README"))
        let url = FilenameResolver.uniqueURL(in: tmpDir, preferredName: "README")
        XCTAssertEqual(url.lastPathComponent, "README (2)")
    }

    func test_sanitizeStripsIllegalChars() {
        XCTAssertEqual(FilenameResolver.sanitize("foo/bar:baz?.zip"), "foo_bar_baz_.zip")
        XCTAssertEqual(FilenameResolver.sanitize(""), "download")
    }

    // MARK: - ensuringExtension

    func test_ensuringExtension_addsFromMimeWhenMissing() {
        XCTAssertEqual(FilenameResolver.ensuringExtension("uc_id=1ABC", mimeType: "application/pdf"), "uc_id=1ABC.pdf")
    }

    func test_ensuringExtension_ignoresMimeParameters() {
        XCTAssertEqual(FilenameResolver.ensuringExtension("notes", mimeType: "text/plain; charset=utf-8"), "notes.txt")
    }

    func test_ensuringExtension_leavesExistingExtension() {
        XCTAssertEqual(FilenameResolver.ensuringExtension("file.zip", mimeType: "application/pdf"), "file.zip")
    }

    func test_ensuringExtension_unchangedWhenNoMime() {
        XCTAssertEqual(FilenameResolver.ensuringExtension("blob", mimeType: nil), "blob")
    }

    func test_ensuringExtension_unchangedForUnknownMime() {
        XCTAssertEqual(FilenameResolver.ensuringExtension("blob", mimeType: "application/x-totally-made-up"), "blob")
    }
}
