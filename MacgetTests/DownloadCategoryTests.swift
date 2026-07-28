import XCTest
@testable import Macget

final class DownloadCategoryTests: XCTestCase {

    // MARK: - Bucketing

    func test_videoExtensionsGroupUnderMovies() {
        for name in ["a.mp4", "b.mkv", "c.webm", "d.mov", "e.avi"] {
            XCTAssertEqual(DownloadCategory.of(filename: name), .movies, name)
        }
    }

    func test_audioExtensionsGroupUnderMusic() {
        for name in ["a.mp3", "b.flac", "c.m4a", "d.opus", "e.wav"] {
            XCTAssertEqual(DownloadCategory.of(filename: name), .music, name)
        }
    }

    func test_imageExtensionsGroupUnderPictures() {
        for name in ["a.jpg", "b.png", "c.gif", "d.heic"] {
            XCTAssertEqual(DownloadCategory.of(filename: name), .pictures, name)
        }
    }

    func test_pdfAndTextGroupUnderDocuments() {
        XCTAssertEqual(DownloadCategory.of(filename: "paper.pdf"), .documents)
        XCTAssertEqual(DownloadCategory.of(filename: "notes.txt"), .documents)
    }

    func test_archivesDisksAndAppsGroupSeparately() {
        XCTAssertEqual(DownloadCategory.of(filename: "a.zip"), .archives)
        XCTAssertEqual(DownloadCategory.of(filename: "b.tar.gz"), .archives)
        XCTAssertEqual(DownloadCategory.of(filename: "c.dmg"), .apps)
        XCTAssertEqual(DownloadCategory.of(filename: "d.pkg"), .apps)
    }

    func test_sourceFilesGroupUnderCode() {
        for name in ["main.swift", "app.ts", "server.go", "config.yaml"] {
            XCTAssertEqual(DownloadCategory.of(filename: name), .code, name)
        }
    }

    func test_unknownAndExtensionlessFilesGroupUnderOther() {
        XCTAssertEqual(DownloadCategory.of(filename: "README"), .other)
        XCTAssertEqual(DownloadCategory.of(filename: "blob.qqzz"), .other)
        XCTAssertEqual(DownloadCategory.of(filename: ""), .other)
    }

    func test_extensionMatchingIsCaseInsensitive() {
        XCTAssertEqual(DownloadCategory.of(filename: "MOVIE.MP4"), .movies)
        XCTAssertEqual(DownloadCategory.of(filename: "Song.FLAC"), .music)
    }

    // MARK: - Ordering

    func test_otherSortsLast() {
        XCTAssertEqual(DownloadCategory.displayOrder.last, .other)
    }

    func test_displayOrderCoversEveryCategoryExactlyOnce() {
        XCTAssertEqual(Set(DownloadCategory.displayOrder).count, DownloadCategory.allCases.count)
    }

    func test_everyCategoryHasASymbol() {
        for category in DownloadCategory.allCases {
            XCTAssertFalse(category.symbol.isEmpty, "\(category) has no symbol")
        }
    }

    // MARK: - The invariant that matters

    /// Grouping headings and auto-sort destination folders must agree: a file
    /// that Macget files under `Music/` on disk has to appear under the "Music"
    /// heading in the list. If someone renames a bucket on one side only, this
    /// is what catches it.
    func test_groupNamesMatchTheAutoSortFolderNames() {
        let samples = [
            "clip.mp4", "song.mp3", "photo.jpg", "paper.pdf", "notes.txt",
            "bundle.zip", "installer.dmg", "tool.pkg", "main.swift", "README",
        ]
        for name in samples {
            let folder = CategoryFolder.subfolder(for: name)
            let group = DownloadCategory.of(filename: name)
            if let folder {
                XCTAssertEqual(folder, group.rawValue,
                               "\(name) sorts into \(folder)/ but groups under \(group.rawValue)")
            } else {
                // No folder means uncategorized, which the list shows as "Other".
                XCTAssertEqual(group, .other, "\(name) has no sort folder but grouped as \(group)")
            }
        }
    }

    // MARK: - Collapsed-folder persistence

    func test_collapsedSetRoundTrips() {
        let collapsed: Set<DownloadCategory> = [.movies, .archives, .other]
        let decoded = DownloadCategory.decodeCollapsed(
            DownloadCategory.encodeCollapsed(collapsed))
        XCTAssertEqual(decoded, collapsed)
    }

    /// The empty string is what `@AppStorage` starts at, and it has to mean
    /// "nothing collapsed" — every folder open — rather than decoding to junk.
    func test_emptyStringDecodesToNoCollapsedFolders() {
        XCTAssertEqual(DownloadCategory.decodeCollapsed(""), [])
        XCTAssertEqual(DownloadCategory.encodeCollapsed([]), "")
    }

    /// A value written by a version that had a category this build doesn't must
    /// drop the stranger and keep the rest, not fail the whole decode.
    func test_unknownRawValuesAreDropped() {
        let decoded = DownloadCategory.decodeCollapsed("Movies,Hologram,Code")
        XCTAssertEqual(decoded, [.movies, .code])
    }

    /// A `Set` iterates in a different order each launch. Encoding straight from
    /// one would rewrite the preference on every toggle, so the encoder sorts
    /// into `displayOrder` and the same set always produces the same string.
    func test_encodingIsStableRegardlessOfSetOrder() {
        let a: Set<DownloadCategory> = [.other, .movies, .code]
        let b: Set<DownloadCategory> = [.code, .other, .movies]
        XCTAssertEqual(DownloadCategory.encodeCollapsed(a),
                       DownloadCategory.encodeCollapsed(b))
        XCTAssertEqual(DownloadCategory.encodeCollapsed(a), "Movies,Code,Other")
    }
}
