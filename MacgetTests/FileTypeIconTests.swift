import XCTest
@testable import Macget

final class FileTypeIconTests: XCTestCase {

    func test_videoExtensions() {
        XCTAssertEqual(FileTypeIcon.category(for: "movie.mp4"), .video)
        XCTAssertEqual(FileTypeIcon.category(for: "clip.mkv"), .video)
        XCTAssertEqual(FileTypeIcon.symbolName(for: "movie.mp4"), "film")
    }

    func test_audioImagePdf() {
        XCTAssertEqual(FileTypeIcon.category(for: "song.mp3"), .audio)
        XCTAssertEqual(FileTypeIcon.category(for: "pic.png"), .image)
        XCTAssertEqual(FileTypeIcon.category(for: "paper.pdf"), .pdf)
    }

    func test_archivesAndDisks() {
        XCTAssertEqual(FileTypeIcon.category(for: "bundle.zip"), .archive)
        XCTAssertEqual(FileTypeIcon.category(for: "stuff.tar.gz"), .archive)
        XCTAssertEqual(FileTypeIcon.category(for: "Installer.dmg"), .disk)
        XCTAssertEqual(FileTypeIcon.symbolName(for: "bundle.zip"), "doc.zipper")
    }

    func test_appsAndCode() {
        XCTAssertEqual(FileTypeIcon.category(for: "Tool.pkg"), .app)
        XCTAssertEqual(FileTypeIcon.category(for: "main.swift"), .code)
        XCTAssertEqual(FileTypeIcon.category(for: "data.json"), .code)
    }

    func test_genericAndNoExtension() {
        XCTAssertEqual(FileTypeIcon.category(for: "README"), .generic)
        XCTAssertEqual(FileTypeIcon.category(for: "weirdfile.qqq"), .generic)
        XCTAssertEqual(FileTypeIcon.symbolName(for: "README"), "doc")
    }

    func test_caseInsensitiveExtension() {
        XCTAssertEqual(FileTypeIcon.category(for: "MOVIE.MP4"), .video)
        XCTAssertEqual(FileTypeIcon.category(for: "ARCHIVE.ZIP"), .archive)
    }
}
