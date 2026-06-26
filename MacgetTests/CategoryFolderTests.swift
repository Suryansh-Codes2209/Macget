import XCTest
@testable import Macget

final class CategoryFolderTests: XCTestCase {

    func test_mapsKnownTypes() {
        XCTAssertEqual(CategoryFolder.subfolder(for: "movie.mp4"), "Movies")
        XCTAssertEqual(CategoryFolder.subfolder(for: "song.mp3"), "Music")
        XCTAssertEqual(CategoryFolder.subfolder(for: "photo.jpg"), "Pictures")
        XCTAssertEqual(CategoryFolder.subfolder(for: "archive.zip"), "Archives")
        XCTAssertEqual(CategoryFolder.subfolder(for: "manual.pdf"), "Documents")
        XCTAssertEqual(CategoryFolder.subfolder(for: "installer.dmg"), "Apps")
        XCTAssertEqual(CategoryFolder.subfolder(for: "app.pkg"), "Apps")
        XCTAssertEqual(CategoryFolder.subfolder(for: "script.py"), "Code")
    }

    func test_unknownTypesStayInRoot() {
        XCTAssertNil(CategoryFolder.subfolder(for: "noextension"))
        XCTAssertNil(CategoryFolder.subfolder(for: "data.weirdext"))
    }
}
