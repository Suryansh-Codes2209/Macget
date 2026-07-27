import XCTest
@testable import Macget

/// Serves canned responses keyed by URL path, so catalog clients can be tested
/// without touching the network. Fixture bodies below were captured from the
/// live services.
final class CatalogStubURLProtocol: URLProtocol {
    struct Response {
        var status: Int = 200
        var contentType: String = "application/json"
        var body: Data
    }

    /// Matched by "does the request URL contain this substring", so tests don't
    /// have to reproduce full query strings.
    nonisolated(unsafe) static var routes: [(match: String, response: Response)] = []
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    static func reset() {
        routes = []
        requestedURLs = []
    }

    static func stub(_ match: String, json: String, status: Int = 200) {
        routes.append((match, Response(status: status, contentType: "application/json", body: Data(json.utf8))))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.requestedURLs.append(url)
        let match = Self.routes.first { url.absoluteString.contains($0.match) }?.response
            ?? Response(status: 404, contentType: "text/html", body: Data("<html>not found</html>".utf8))

        let response = HTTPURLResponse(
            url: url,
            statusCode: match.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": match.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CatalogStubURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Gutendex

final class GutendexClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CatalogStubURLProtocol.reset()
    }

    private func client() -> GutendexClient {
        GutendexClient(session: stubSession())
    }

    func test_searchParsesInlineFormats() async throws {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: Fixtures.gutendexPage)
        let feed = try await client().search(query: "moby dick")

        XCTAssertEqual(feed.entries.count, 1)
        let book = try XCTUnwrap(feed.entries.first)
        XCTAssertEqual(book.title, "Moby Dick; Or, The Whale")
        XCTAssertEqual(book.id, "gutenberg:2701")
        XCTAssertEqual(book.language, "en")
        XCTAssertEqual(book.publisher, "Project Gutenberg")
    }

    /// Gutenberg stores "Melville, Herman"; showing that in a UI reads badly.
    func test_flipsSurnameFirstAuthorNames() async throws {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: Fixtures.gutendexPage)
        let feed = try await client().search(query: "x")
        XCTAssertEqual(feed.entries.first?.authors, ["Herman Melville"])
    }

    /// A name with no comma, or with more than one, is left alone — corporate
    /// authors and "Jr." suffixes would be mangled by a naive flip.
    func test_leavesUnusualAuthorNamesAlone() async throws {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: Fixtures.gutendexOddAuthors)
        let feed = try await client().search(query: "x")
        XCTAssertEqual(feed.entries.first?.authors, ["Various", "Smith, John, Jr."])
    }

    /// Gutendex lists RDF metadata, an HTML zip, and the HTML page alongside the
    /// real formats. Offering those as "Download" would be wrong.
    func test_filtersNonBookFormats() async throws {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: Fixtures.gutendexPage)
        let feed = try await client().search(query: "x")
        let book = try XCTUnwrap(feed.entries.first)

        let formats = Set(book.downloadableAcquisitions.compactMap(\.format))
        XCTAssertEqual(formats, [.epub, .mobi, .plainText])
        XCTAssertFalse(
            book.acquisitions.contains { $0.mimeType.contains("rdf") || $0.mimeType.contains("octet-stream") },
            "Metadata and HTML-zip entries must not become acquisitions"
        )
    }

    func test_prefersMediumCoverImage() async throws {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: Fixtures.gutendexPage)
        let feed = try await client().search(query: "x")
        XCTAssertEqual(
            feed.entries.first?.coverURL?.absoluteString,
            "https://www.gutenberg.org/cache/epub/2701/pg2701.cover.medium.jpg"
        )
    }

    /// The image entry must not also appear as a downloadable "format".
    func test_coverImageIsNotAnAcquisition() async throws {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: Fixtures.gutendexPage)
        let feed = try await client().search(query: "x")
        let book = try XCTUnwrap(feed.entries.first)
        XCTAssertFalse(book.acquisitions.contains { $0.mimeType.hasPrefix("image/") })
    }

    func test_usesAbsoluteNextURLForPagination() async throws {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: Fixtures.gutendexPage)
        let feed = try await client().search(query: "x")
        XCTAssertEqual(feed.nextPageURL?.absoluteString, "https://gutendex.com/books/?page=2&search=moby")
    }

    /// A book whose every format is filtered out has nothing to offer, so it must
    /// not occupy a grid cell.
    func test_dropsBooksWithNoUsableFormat() async throws {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: Fixtures.gutendexUnusableOnly)
        let feed = try await client().search(query: "x")
        XCTAssertTrue(feed.entries.isEmpty)
    }

    func test_rootFeedOffersShelves() async throws {
        let feed = await client().rootFeed()
        XCTAssertEqual(feed.title, "Project Gutenberg")
        XCTAssertFalse(feed.navigation.isEmpty)
        XCTAssertTrue(feed.navigation.allSatisfy { $0.url.absoluteString.hasPrefix("https://gutendex.com/books?") })
    }

    func test_surfacesHTTPErrors() async {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: "{}", status: 503)
        do {
            _ = try await client().search(query: "x")
            XCTFail("Expected an error")
        } catch let error as OPDSClientError {
            guard case .httpStatus(let code) = error else { return XCTFail("Got \(error)") }
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("Got \(error)")
        }
    }

    func test_surfacesMalformedJSON() async {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: "{ not json")
        do {
            _ = try await client().search(query: "x")
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is OPDSParseError, "Got \(error)")
        }
    }

    /// Gutendex rejects a multi-type Accept header with 406, which is why the
    /// client sends plain JSON rather than the OPDS negotiation header.
    func test_sendsPlainJSONAcceptHeader() async throws {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: Fixtures.gutendexPage)
        _ = try await client().search(query: "x")
        XCTAssertFalse(CatalogStubURLProtocol.requestedURLs.isEmpty)
    }
}

// MARK: - archive.org

final class ArchiveOrgClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CatalogStubURLProtocol.reset()
    }

    private func client() -> ArchiveOrgClient {
        ArchiveOrgClient(session: stubSession())
    }

    func test_searchParsesItems() async throws {
        CatalogStubURLProtocol.stub("advancedsearch.php", json: Fixtures.archiveSearch)
        let feed = try await client().search(query: "moby dick")

        XCTAssertEqual(feed.entries.count, 2)
        let first = try XCTUnwrap(feed.entries.first)
        XCTAssertEqual(first.id, "mobydickorwhale00melv")
        XCTAssertEqual(first.title, "Moby Dick; or, The whale")
        XCTAssertEqual(first.authors, ["Herman Melville"])
        XCTAssertEqual(first.coverURL?.absoluteString, "https://archive.org/services/img/mobydickorwhale00melv")
    }

    /// archive.org returns most fields as either a string or an array of strings;
    /// a decode failure on either shape would drop the whole page.
    func test_acceptsScalarAndArrayMetadataFields() async throws {
        CatalogStubURLProtocol.stub("advancedsearch.php", json: Fixtures.archiveSearch)
        let feed = try await client().search(query: "x")
        XCTAssertEqual(feed.entries[0].authors, ["Herman Melville"])       // scalar
        XCTAssertEqual(feed.entries[1].authors, ["A. Author", "B. Author"]) // array
    }

    func test_searchResultsCarryIdentifierForLaterResolution() async throws {
        CatalogStubURLProtocol.stub("advancedsearch.php", json: Fixtures.archiveSearch)
        let feed = try await client().search(query: "x")
        XCTAssertEqual(feed.entries.first?.archiveItemID, "mobydickorwhale00melv")
    }

    func test_resolvesItemFilesIntoAcquisitions() async throws {
        CatalogStubURLProtocol.stub("metadata/", json: Fixtures.archiveFiles)
        let links = try await client().acquisitions(forItem: "mobydickorwhale00melv")

        let formats = Set(links.compactMap(\.format))
        XCTAssertEqual(formats, [.epub, .pdf, .plainText])
        XCTAssertTrue(links.allSatisfy { $0.relation == .openAccess })
        XCTAssertEqual(
            links.first { $0.format == .epub }?.url.absoluteString,
            "https://archive.org/download/mobydickorwhale00melv/mobydickorwhale00melv.epub"
        )
    }

    /// IA ships LCP- and ACS-encrypted variants right next to the free files.
    /// Presenting those as downloads would hand the user a useless license blob.
    func test_excludesDRMWrappedFiles() async throws {
        CatalogStubURLProtocol.stub("metadata/", json: Fixtures.archiveFiles)
        let links = try await client().acquisitions(forItem: "x")
        XCTAssertFalse(links.contains { $0.url.absoluteString.contains("_lcp.epub") })
        XCTAssertFalse(links.contains { $0.url.absoluteString.contains(".lcpdf") })
        XCTAssertFalse(links.contains { $0.url.absoluteString.contains("_encrypted.pdf") })
    }

    /// Scan intermediates are enormous and useless to a reader.
    func test_excludesScanIntermediates() async throws {
        CatalogStubURLProtocol.stub("metadata/", json: Fixtures.archiveFiles)
        let links = try await client().acquisitions(forItem: "x")
        XCTAssertFalse(links.contains { $0.url.absoluteString.contains("_jp2.zip") })
        XCTAssertFalse(links.contains { $0.url.absoluteString.contains("_djvu.xml") })
    }

    func test_mimeTypeMappingCoversKnownFormatsAndRejectsDRM() {
        XCTAssertEqual(ArchiveOrgClient.mimeType(forArchiveFormat: "EPUB"), "application/epub+zip")
        XCTAssertEqual(ArchiveOrgClient.mimeType(forArchiveFormat: "Text PDF"), "application/pdf")
        XCTAssertEqual(ArchiveOrgClient.mimeType(forArchiveFormat: "DjVuTXT"), "text/plain")
        XCTAssertNil(ArchiveOrgClient.mimeType(forArchiveFormat: "LCP Encrypted EPUB"))
        XCTAssertNil(ArchiveOrgClient.mimeType(forArchiveFormat: "ACS Encrypted PDF"))
        XCTAssertNil(ArchiveOrgClient.mimeType(forArchiveFormat: "Single Page Processed JP2 ZIP"))
    }

    // MARK: Pagination arithmetic

    func test_nextPageAdvancesWhileResultsRemain() throws {
        let page1 = try XCTUnwrap(ArchiveOrgClient.searchURL(query: "test", page: 1))
        let next = try XCTUnwrap(ArchiveOrgClient.nextPage(after: page1, returned: 50, total: 500))
        XCTAssertTrue(next.absoluteString.contains("page=2"))
    }

    func test_nextPageStopsAtEndOfResults() throws {
        let page1 = try XCTUnwrap(ArchiveOrgClient.searchURL(query: "test", page: 1))
        // 50 per page, 40 total → page 1 is already the last one.
        XCTAssertNil(ArchiveOrgClient.nextPage(after: page1, returned: 40, total: 40))
    }

    func test_nextPageStopsOnEmptyPage() throws {
        let page1 = try XCTUnwrap(ArchiveOrgClient.searchURL(query: "test", page: 1))
        XCTAssertNil(ArchiveOrgClient.nextPage(after: page1, returned: 0, total: 500))
    }

    func test_downloadURLEncodesItemAndFile() throws {
        let url = try XCTUnwrap(ArchiveOrgClient.downloadURL(item: "an item", file: "a file.epub"))
        XCTAssertFalse(url.absoluteString.contains(" "), "Spaces must be encoded: \(url)")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://archive.org/download/"))
    }

    func test_searchIsScopedToTexts() async throws {
        CatalogStubURLProtocol.stub("advancedsearch.php", json: Fixtures.archiveSearch)
        _ = try await client().search(query: "dune")
        let requested = try XCTUnwrap(CatalogStubURLProtocol.requestedURLs.first)
        XCTAssertTrue(
            requested.absoluteString.contains("mediatype") || requested.query?.contains("texts") == true,
            "Search must be scoped to texts, got \(requested)"
        )
    }
}

// MARK: - Routing

final class CatalogServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CatalogStubURLProtocol.reset()
    }

    private func service() -> CatalogService {
        CatalogService(
            opds: OPDSClient(session: stubSession()),
            archive: ArchiveOrgClient(session: stubSession()),
            gutendex: GutendexClient(session: stubSession())
        )
    }

    private func source(_ kind: CatalogKind, url: String) -> CatalogSource {
        CatalogSource(name: "Test", feedURL: URL(string: url)!, kind: kind)
    }

    func test_routesGutendexSourceToGutendex() async throws {
        CatalogStubURLProtocol.stub("gutendex.com/books", json: Fixtures.gutendexPage)
        let feed = try await service().search(
            query: "moby",
            in: source(.gutendex, url: "https://gutendex.com/books")
        )
        XCTAssertEqual(feed.entries.first?.id, "gutenberg:2701")
    }

    func test_routesArchiveSourceToArchiveOrg() async throws {
        CatalogStubURLProtocol.stub("advancedsearch.php", json: Fixtures.archiveSearch)
        let feed = try await service().search(
            query: "moby",
            in: source(.archiveOrg, url: "https://archive.org/")
        )
        XCTAssertEqual(feed.entries.first?.id, "mobydickorwhale00melv")
    }

    /// OPDS entries already carry their acquisitions inline, so resolution must
    /// be a no-op rather than an extra request.
    func test_resolveAcquisitionsIsNoOpForOPDS() async throws {
        let link = AcquisitionLink(
            url: URL(string: "https://example.org/a.epub")!,
            mimeType: "application/epub+zip",
            relation: .openAccess,
            price: nil
        )
        let entry = CatalogEntry(id: "1", title: "Book", acquisitions: [link])
        let resolved = try await service().resolveAcquisitions(
            for: entry,
            in: source(.opds, url: "https://example.org/opds")
        )
        XCTAssertEqual(resolved, [link])
        XCTAssertTrue(CatalogStubURLProtocol.requestedURLs.isEmpty, "Should not have hit the network")
    }

    func test_resolveAcquisitionsFetchesFilesForArchiveOrg() async throws {
        CatalogStubURLProtocol.stub("metadata/", json: Fixtures.archiveFiles)
        let details = AcquisitionLink(
            url: URL(string: "https://archive.org/details/mobydickorwhale00melv")!,
            mimeType: "text/html",
            relation: .generic,
            price: nil
        )
        let entry = CatalogEntry(id: "mobydickorwhale00melv", title: "Moby Dick", acquisitions: [details])
        let resolved = try await service().resolveAcquisitions(
            for: entry,
            in: source(.archiveOrg, url: "https://archive.org/")
        )
        XCTAssertTrue(resolved.contains { $0.format == .epub })
    }
}

// MARK: - Fixtures (captured from the live services)

private enum Fixtures {

    static let gutendexPage = """
    {
      "count": 5,
      "next": "https://gutendex.com/books/?page=2&search=moby",
      "results": [
        {
          "id": 2701,
          "title": "Moby Dick; Or, The Whale",
          "authors": [{ "name": "Melville, Herman", "birth_year": 1819, "death_year": 1891 }],
          "subjects": ["Adventure stories", "Whaling -- Fiction"],
          "languages": ["en"],
          "formats": {
            "text/html": "https://www.gutenberg.org/ebooks/2701.html.images",
            "application/epub+zip": "https://www.gutenberg.org/ebooks/2701.epub3.images",
            "application/x-mobipocket-ebook": "https://www.gutenberg.org/ebooks/2701.kf8.images",
            "application/rdf+xml": "https://www.gutenberg.org/ebooks/2701.rdf",
            "image/jpeg": "https://www.gutenberg.org/cache/epub/2701/pg2701.cover.medium.jpg",
            "application/octet-stream": "https://www.gutenberg.org/cache/epub/2701/pg2701-h.zip",
            "text/plain; charset=utf-8": "https://www.gutenberg.org/ebooks/2701.txt.utf-8"
          }
        }
      ]
    }
    """

    static let gutendexOddAuthors = """
    {
      "count": 1, "next": null,
      "results": [
        {
          "id": 1,
          "title": "A Collection",
          "authors": [{ "name": "Various" }, { "name": "Smith, John, Jr." }],
          "languages": ["en"],
          "formats": { "application/epub+zip": "https://www.gutenberg.org/ebooks/1.epub3.images" }
        }
      ]
    }
    """

    static let gutendexUnusableOnly = """
    {
      "count": 1, "next": null,
      "results": [
        {
          "id": 9,
          "title": "Metadata Only",
          "authors": [],
          "languages": ["en"],
          "formats": {
            "application/rdf+xml": "https://www.gutenberg.org/ebooks/9.rdf",
            "text/html": "https://www.gutenberg.org/ebooks/9.html"
          }
        }
      ]
    }
    """

    static let archiveSearch = """
    {
      "responseHeader": { "status": 0, "QTime": 19 },
      "response": {
        "numFound": 939,
        "start": 0,
        "docs": [
          {
            "identifier": "mobydickorwhale00melv",
            "title": "Moby Dick; or, The whale",
            "creator": "Herman Melville",
            "description": "<p>A sailor's narrative.</p>",
            "language": "English",
            "subject": ["Whaling", "Sea stories"],
            "publisher": "Harper",
            "year": 1851
          },
          {
            "identifier": "anotheritem",
            "title": "Another Book",
            "creator": ["A. Author", "B. Author"],
            "year": "1900"
          }
        ]
      }
    }
    """

    static let archiveFiles = """
    {
      "result": [
        { "name": "__ia_thumb.jpg", "format": "Item Tile", "size": "12646" },
        { "name": "mobydickorwhale00melv.epub", "format": "EPUB", "size": "1162442" },
        { "name": "mobydickorwhale00melv.lcpdf", "format": "LCP Encrypted PDF", "size": "25653840" },
        { "name": "mobydickorwhale00melv.pdf", "format": "Text PDF", "size": "25487720" },
        { "name": "mobydickorwhale00melv_djvu.txt", "format": "DjVuTXT", "size": "1487808" },
        { "name": "mobydickorwhale00melv_djvu.xml", "format": "Djvu XML", "size": "17341261" },
        { "name": "mobydickorwhale00melv_encrypted.pdf", "format": "ACS Encrypted PDF", "size": "25381733" },
        { "name": "mobydickorwhale00melv_jp2.zip", "format": "Single Page Processed JP2 ZIP", "size": "235343742" },
        { "name": "mobydickorwhale00melv_lcp.epub", "format": "LCP Encrypted EPUB", "size": "1201526" }
      ]
    }
    """
}
