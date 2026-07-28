import XCTest
@testable import Macget

final class CatalogStoreTests: XCTestCase {

    private let existing = CatalogSource.builtIns

    // MARK: - Adding custom catalogs

    func test_makeCustomSource_acceptsHTTPSFeed() throws {
        let source = try CatalogStore.makeCustomSource(
            name: "My Calibre",
            urlString: "https://books.example.org/opds",
            existing: existing
        )
        XCTAssertEqual(source.name, "My Calibre")
        XCTAssertEqual(source.feedURL.absoluteString, "https://books.example.org/opds")
        XCTAssertFalse(source.isBuiltIn)
        XCTAssertTrue(source.isEnabled)
    }

    func test_makeCustomSource_trimsWhitespace() throws {
        let source = try CatalogStore.makeCustomSource(
            name: "  Spaced  ",
            urlString: "  https://books.example.org/opds  ",
            existing: existing
        )
        XCTAssertEqual(source.name, "Spaced")
        XCTAssertEqual(source.feedURL.absoluteString, "https://books.example.org/opds")
    }

    /// A blank name is common (users paste a URL and hit Add) — fall back to the
    /// host rather than showing an unnamed row.
    func test_makeCustomSource_fallsBackToHostWhenNameBlank() throws {
        let source = try CatalogStore.makeCustomSource(
            name: "   ",
            urlString: "https://books.example.org/opds",
            existing: existing
        )
        XCTAssertEqual(source.name, "books.example.org")
    }

    func test_makeCustomSource_rejectsNonHTTPScheme() {
        // file:// would make the catalog list a local-file reader.
        XCTAssertThrowsError(try CatalogStore.makeCustomSource(
            name: "Local",
            urlString: "file:///Users/someone/feed.xml",
            existing: existing
        ))
    }

    func test_makeCustomSource_rejectsGarbage() {
        XCTAssertThrowsError(try CatalogStore.makeCustomSource(
            name: "Nope",
            urlString: "not a url at all",
            existing: existing
        ))
    }

    func test_makeCustomSource_rejectsDuplicateFeedURL() throws {
        let gutenberg = try XCTUnwrap(CatalogSource.builtIns.first)
        XCTAssertThrowsError(try CatalogStore.makeCustomSource(
            name: "Copy",
            urlString: gutenberg.feedURL.absoluteString,
            existing: existing
        )) { error in
            guard case CatalogStore.AddError.duplicate(let name) = error else {
                return XCTFail("Expected .duplicate, got \(error)")
            }
            XCTAssertEqual(name, gutenberg.name)
        }
    }

    // MARK: - Built-ins

    func test_builtIns_haveStableDistinctIdentifiers() {
        let ids = Set(CatalogSource.builtIns.map(\.id))
        XCTAssertEqual(ids.count, CatalogSource.builtIns.count, "Built-in catalog IDs must be unique")
        XCTAssertTrue(CatalogSource.builtIns.allSatisfy(\.isBuiltIn))
        XCTAssertTrue(CatalogSource.builtIns.allSatisfy { $0.feedURL.scheme == "https" })
    }

    func test_builtIns_opdsCatalogsHaveSearchFallbacks() {
        // Gutenberg's mobile feed doesn't advertise OpenSearch, so without these
        // the search field would be dead for the flagship catalog. archive.org is
        // exempt — it isn't OPDS and builds its own search URLs.
        for source in CatalogSource.builtIns where source.kind == .opds {
            XCTAssertNotNil(source.fallbackSearchTemplate, "\(source.name) needs a search fallback")
            XCTAssertTrue(
                source.fallbackSearchTemplate?.contains("{searchTerms}") ?? false,
                "\(source.name)'s template must contain {searchTerms}"
            )
        }
    }

    /// Standard Ebooks gates every OPDS feed behind a Patrons Circle donation —
    /// verified live, all of /feeds/opds, /all, and /new-releases return 401. It
    /// ships off so new users aren't greeted by an auth error.
    func test_standardEbooksShipsDisabledWithAnExplanation() throws {
        let se = try XCTUnwrap(CatalogSource.builtIns.first { $0.name == "Standard Ebooks" })
        XCTAssertFalse(se.isEnabled)
        XCTAssertNotNil(se.note)
    }

    /// IA retired its OPDS BookServer (bookserver.archive.org no longer resolves),
    /// so this catalog must route through the archive.org JSON client instead.
    func test_internetArchiveUsesArchiveOrgKind() throws {
        let ia = try XCTUnwrap(CatalogSource.builtIns.first { $0.name == "Internet Archive" })
        XCTAssertEqual(ia.kind, .archiveOrg)
        XCTAssertTrue(ia.isEnabled)
        XCTAssertNotEqual(ia.feedURL.host, "bookserver.archive.org")
    }

    func test_enabledByDefaultCatalogsAreReachableKinds() {
        let enabled = CatalogSource.builtIns.filter(\.isEnabled)
        XCTAssertFalse(enabled.isEmpty, "At least one catalog must work out of the box")
    }

    func test_customSourceHasNoSearchFallback() throws {
        let source = try CatalogStore.makeCustomSource(
            name: "Unknown",
            urlString: "https://unknown.example.org/opds",
            existing: existing
        )
        XCTAssertNil(source.fallbackSearchTemplate)
    }

    // MARK: - Decoding older files

    /// A catalogs.json written before a field existed must still decode — dropping
    /// it would silently wipe the user's added catalogs on upgrade.
    func test_catalogSource_decodesWithMissingOptionalFields() throws {
        let json = """
        { "id": "\(UUID().uuidString)", "name": "Old", "feedURL": "https://old.example.org/opds" }
        """
        let source = try JSONDecoder().decode(CatalogSource.self, from: Data(json.utf8))
        XCTAssertEqual(source.name, "Old")
        XCTAssertFalse(source.isBuiltIn)
        XCTAssertTrue(source.isEnabled, "Catalogs should default to enabled")
    }
}

final class BookFilenameTests: XCTestCase {

    func test_buildsTitleAndAuthorWithExtension() {
        let name = BookFilename.make(
            title: "Moby Dick; Or, The Whale",
            authors: ["Herman Melville"],
            format: .epub
        )
        XCTAssertEqual(name, "Moby Dick; Or, The Whale - Herman Melville.epub")
    }

    func test_omitsAuthorWhenAbsent() {
        let name = BookFilename.make(title: "Anonymous Work", authors: [], format: .pdf)
        XCTAssertEqual(name, "Anonymous Work.pdf")
    }

    func test_usesOnlyFirstAuthor() {
        let name = BookFilename.make(title: "Collab", authors: ["A Writer", "B Writer"], format: .epub)
        XCTAssertEqual(name, "Collab - A Writer.epub")
    }

    /// Titles routinely contain "/" and ":" — unsanitized these break the write.
    func test_sanitizesPathSeparators() {
        let name = BookFilename.make(title: "Either/Or: A Fragment", authors: [], format: .epub)
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".epub"))
    }

    func test_unknownFormatStillProducesAName() {
        let name = BookFilename.make(title: "Mystery", authors: [], format: nil)
        XCTAssertEqual(name, "Mystery.bin")
    }

    /// A pathological title must not push the filename past the 255-byte limit.
    func test_capsLongTitlesInsideByteLimit() {
        let name = BookFilename.make(
            title: String(repeating: "long title ", count: 60),
            authors: ["An Author"],
            format: .epub
        )
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertTrue(name.hasSuffix(".epub"))
    }

    /// An empty title would otherwise yield a bare ".epub" — a hidden file.
    /// Falls back to the app-wide "download" convention from `FilenameResolver`.
    func test_emptyTitleFallsBackToDownload() {
        let name = BookFilename.make(title: "   ", authors: [], format: .epub)
        XCTAssertEqual(name, "download.epub")
    }
}
