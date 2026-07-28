import XCTest
@testable import Macget

final class OPDSParserTests: XCTestCase {

    private let base = URL(string: "https://example.org/catalog/")!

    // MARK: - Atom: navigation feeds

    /// A navigation feed's entries point at other catalogs, not at books. They
    /// must land in `navigation`, never in `entries`.
    func test_atom_navigationFeedProducesNavigationLinks() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.navigationFeed.utf8), baseURL: base)

        XCTAssertEqual(feed.title, "Project Gutenberg")
        XCTAssertTrue(feed.entries.isEmpty, "A navigation feed has no publications")
        XCTAssertEqual(feed.navigation.count, 2)
        XCTAssertEqual(feed.navigation[0].title, "Popular")
        XCTAssertEqual(feed.navigation[0].url.absoluteString, "https://example.org/catalog/popular")
        XCTAssertEqual(feed.navigation[1].title, "Latest")
    }

    /// Relative hrefs must resolve against the feed URL, not be dropped.
    func test_atom_resolvesRelativeHrefs() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.navigationFeed.utf8), baseURL: base)
        for link in feed.navigation {
            XCTAssertEqual(link.url.host, "example.org")
            XCTAssertTrue(link.url.absoluteString.hasPrefix("https://"), "Got \(link.url)")
        }
    }

    // MARK: - Atom: acquisition feeds

    func test_atom_acquisitionFeedParsesEntryMetadata() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.acquisitionFeed.utf8), baseURL: base)

        XCTAssertEqual(feed.entries.count, 3)
        let moby = try XCTUnwrap(feed.entries.first { $0.title.contains("Moby") })
        XCTAssertEqual(moby.title, "Moby Dick; Or, The Whale")
        XCTAssertEqual(moby.authors, ["Herman Melville"])
        XCTAssertEqual(moby.language, "en")
        XCTAssertEqual(moby.subjects, ["Whaling -- Fiction", "Sea stories"])
        XCTAssertEqual(moby.publisher, "Project Gutenberg")
        XCTAssertNotNil(moby.updated)
    }

    /// Summaries arrive as HTML often enough that leaving tags in would show them
    /// literally in the detail pane.
    func test_atom_stripsHTMLFromSummary() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.acquisitionFeed.utf8), baseURL: base)
        let moby = try XCTUnwrap(feed.entries.first { $0.title.contains("Moby") })
        let summary = try XCTUnwrap(moby.summary)
        XCTAssertFalse(summary.contains("<"), "Tags should be stripped: \(summary)")
        XCTAssertTrue(summary.contains("sailor Ishmael"))
        XCTAssertFalse(summary.contains("  "), "Whitespace should be collapsed")
    }

    func test_atom_parsesAcquisitionFormats() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.acquisitionFeed.utf8), baseURL: base)
        let moby = try XCTUnwrap(feed.entries.first { $0.title.contains("Moby") })

        let formats = Set(moby.downloadableAcquisitions.compactMap(\.format))
        XCTAssertEqual(formats, [.epub, .plainText])
        XCTAssertFalse(moby.isPurchaseOnly)
    }

    func test_atom_parsesCoverAndThumbnail() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.acquisitionFeed.utf8), baseURL: base)
        let moby = try XCTUnwrap(feed.entries.first { $0.title.contains("Moby") })
        XCTAssertEqual(moby.coverURL?.absoluteString, "https://example.org/covers/2701.cover.medium.jpg")
        XCTAssertEqual(moby.thumbnailURL?.absoluteString, "https://example.org/covers/2701.cover.small.jpg")
    }

    /// An entry with no cover at all must still parse — it just renders a
    /// placeholder. Dropping it would silently hide books.
    func test_atom_entryWithoutCoverStillParses() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.acquisitionFeed.utf8), baseURL: base)
        let plain = try XCTUnwrap(feed.entries.first { $0.title == "A Book Without A Cover" })
        XCTAssertNil(plain.coverURL)
        XCTAssertNil(plain.thumbnailURL)
        XCTAssertEqual(plain.downloadableAcquisitions.count, 1)
    }

    /// Authors are optional in the wild; the UI needs a stable fallback.
    func test_atom_entryWithoutAuthorGetsFallbackLine() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.acquisitionFeed.utf8), baseURL: base)
        let plain = try XCTUnwrap(feed.entries.first { $0.title == "A Book Without A Cover" })
        XCTAssertTrue(plain.authors.isEmpty)
        XCTAssertEqual(plain.authorLine, "Unknown author")
    }

    // MARK: - DRM and pricing

    /// An Adobe ADEPT link is a license token, not a book. It must be visible in
    /// `acquisitions` (so the UI can explain why) but never downloadable.
    func test_atom_drmLinkIsNotDownloadable() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.drmAndPricedFeed.utf8), baseURL: base)
        let drm = try XCTUnwrap(feed.entries.first { $0.title == "DRM Protected Book" })

        XCTAssertEqual(drm.acquisitions.count, 1)
        XCTAssertEqual(drm.acquisitions[0].format, .drmProtected)
        XCTAssertTrue(drm.downloadableAcquisitions.isEmpty)
        XCTAssertTrue(drm.isPurchaseOnly)
    }

    /// A priced link must not be fetched — the UI links out to the seller.
    func test_atom_pricedEntryIsNotDownloadable() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.drmAndPricedFeed.utf8), baseURL: base)
        let paid = try XCTUnwrap(feed.entries.first { $0.title == "A Book For Sale" })

        let price = try XCTUnwrap(paid.acquisitions.first?.price)
        XCTAssertEqual(price.amount, Decimal(string: "9.99"))
        XCTAssertEqual(price.currencyCode, "USD")
        XCTAssertTrue(paid.downloadableAcquisitions.isEmpty)
        XCTAssertTrue(paid.isPurchaseOnly)
    }

    /// A borrow rel is a checkout flow, not a file — following it would download
    /// an HTML page.
    func test_atom_borrowLinkIsNotDownloadable() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.drmAndPricedFeed.utf8), baseURL: base)
        let borrow = try XCTUnwrap(feed.entries.first { $0.title == "A Borrowable Book" })
        XCTAssertEqual(borrow.acquisitions.first?.relation, .borrow)
        XCTAssertTrue(borrow.downloadableAcquisitions.isEmpty)
    }

    /// A free entry sitting in the same feed as priced ones must stay downloadable.
    func test_atom_freeEntryInMixedFeedStaysDownloadable() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.drmAndPricedFeed.utf8), baseURL: base)
        let free = try XCTUnwrap(feed.entries.first { $0.title == "A Free Book" })
        XCTAssertEqual(free.downloadableAcquisitions.count, 1)
        XCTAssertFalse(free.isPurchaseOnly)
    }

    // MARK: - Pagination and search

    func test_atom_capturesNextPageLink() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.acquisitionFeed.utf8), baseURL: base)
        XCTAssertEqual(feed.nextPageURL?.absoluteString, "https://example.org/catalog/page2")
    }

    func test_atom_capturesOpenSearchDescriptionLink() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.acquisitionFeed.utf8), baseURL: base)
        XCTAssertEqual(feed.searchDescriptionURL?.absoluteString, "https://example.org/opensearch.xml")
    }

    func test_openSearch_prefersAtomTemplate() throws {
        let template = OPDSParser.parseOpenSearchTemplate(data: Data(Fixtures.openSearchDocument.utf8))
        XCTAssertEqual(template, "https://example.org/search?q={searchTerms}&format=atom")
    }

    func test_openSearch_expandsAndEncodesQuery() throws {
        let url = OPDSParser.expand(
            searchTemplate: "https://example.org/search?q={searchTerms}",
            query: "moby dick & whales"
        )
        XCTAssertEqual(url?.absoluteString, "https://example.org/search?q=moby%20dick%20%26%20whales")
    }

    /// Unfilled placeholders must be cleared, not sent literally — a URL
    /// containing `{startIndex}` 404s on most servers.
    func test_openSearch_clearsUnknownPlaceholders() throws {
        let url = OPDSParser.expand(
            searchTemplate: "https://example.org/s?q={searchTerms}&i={startIndex?}",
            query: "dune"
        )
        XCTAssertEqual(url?.absoluteString, "https://example.org/s?q=dune&i=")
    }

    // MARK: - OPDS 2.0 JSON

    func test_json_parsesPublicationsAndNavigation() throws {
        let feed = try OPDSParser.parseJSON(data: Data(Fixtures.opds2Feed.utf8), baseURL: base)

        XCTAssertEqual(feed.title, "Gutendex")
        XCTAssertEqual(feed.navigation.count, 1)
        XCTAssertEqual(feed.navigation[0].title, "Browse by language")
        XCTAssertEqual(feed.entries.count, 2)

        let first = feed.entries[0]
        XCTAssertEqual(first.title, "Frankenstein")
        XCTAssertEqual(first.authors, ["Mary Wollstonecraft Shelley"])
        XCTAssertEqual(first.language, "en")
        XCTAssertEqual(first.subjects, ["Gothic fiction", "Science fiction"])
        XCTAssertEqual(first.coverURL?.absoluteString, "https://example.org/covers/84-large.jpg")
        XCTAssertEqual(first.downloadableAcquisitions.count, 1)
        XCTAssertEqual(first.downloadableAcquisitions.first?.format, .epub)
    }

    /// `author` is "string or object or array" in OPDS 2. All three shapes appear
    /// in real feeds, and a decode failure on any of them drops the whole page.
    func test_json_acceptsAuthorAsStringObjectAndArray() throws {
        let feed = try OPDSParser.parseJSON(data: Data(Fixtures.opds2Feed.utf8), baseURL: base)
        XCTAssertEqual(feed.entries[0].authors, ["Mary Wollstonecraft Shelley"])   // object form
        XCTAssertEqual(feed.entries[1].authors, ["Jane Austen", "Anonymous"])      // array form
    }

    func test_json_capturesNextPageAndTemplatedSearch() throws {
        let feed = try OPDSParser.parseJSON(data: Data(Fixtures.opds2Feed.utf8), baseURL: base)
        XCTAssertEqual(feed.nextPageURL?.absoluteString, "https://example.org/catalog/?page=2")
        XCTAssertEqual(feed.searchTemplate, "https://example.org/search{?searchTerms}")
    }

    // MARK: - Format sniffing and failure modes

    func test_parse_sniffsJSONWithoutContentType() throws {
        let feed = try OPDSParser.parse(data: Data(Fixtures.opds2Feed.utf8), mimeType: nil, baseURL: base)
        XCTAssertEqual(feed.entries.count, 2)
    }

    func test_parse_sniffsXMLWithoutContentType() throws {
        let feed = try OPDSParser.parse(data: Data(Fixtures.acquisitionFeed.utf8), mimeType: nil, baseURL: base)
        XCTAssertEqual(feed.entries.count, 3)
    }

    func test_parse_contentTypeWinsOverSniffing() throws {
        let feed = try OPDSParser.parse(
            data: Data(Fixtures.opds2Feed.utf8),
            mimeType: "application/opds+json; charset=utf-8",
            baseURL: base
        )
        XCTAssertEqual(feed.entries.count, 2)
    }

    func test_parse_rejectsNonFeedContent() {
        XCTAssertThrowsError(try OPDSParser.parse(data: Data("not a feed".utf8), mimeType: nil, baseURL: base))
    }

    /// An HTML error page served with a 200 is the common failure when a catalog
    /// URL is wrong. It must throw rather than yield an empty feed, so the UI can
    /// say "this isn't an OPDS catalog".
    func test_parse_rejectsHTMLPage() {
        let html = "<!DOCTYPE html><html><body><h1>Not Found</h1></body></html>"
        XCTAssertThrowsError(try OPDSParser.parse(data: Data(html.utf8), mimeType: "text/html", baseURL: base)) { error in
            XCTAssertTrue(error is OPDSParseError, "Got \(error)")
        }
    }

    func test_parse_rejectsTruncatedXML() {
        let truncated = "<?xml version=\"1.0\"?><feed><entry><title>Half a"
        XCTAssertThrowsError(try OPDSParser.parseAtom(data: Data(truncated.utf8), baseURL: base))
    }

    // MARK: - Formats

    func test_bookFormat_ignoresContentTypeParameters() {
        XCTAssertEqual(BookFormat(mimeType: "application/epub+zip; charset=utf-8"), .epub)
        XCTAssertEqual(BookFormat(mimeType: "APPLICATION/PDF"), .pdf)
    }

    func test_bookFormat_unknownTypeIsNotSupported() throws {
        let format = try XCTUnwrap(BookFormat(mimeType: "application/x-weird"))
        XCTAssertFalse(format.isSupported)
        XCTAssertNil(BookFormat(mimeType: ""))
    }

    func test_bookFormat_preferenceRanksEPUBFirst() {
        let sorted = [BookFormat.pdf, .plainText, .epub, .mobi].sorted { $0.preferenceRank < $1.preferenceRank }
        XCTAssertEqual(sorted.first, .epub)
    }

    // MARK: - archive.org

    func test_archiveOrg_extractsIdentifierFromDownloadURL() {
        let url = URL(string: "https://archive.org/download/mobydickorwhale00melv/mobydickorwhale00melv.pdf")!
        XCTAssertEqual(ArchiveOrgItem.identifier(from: url), "mobydickorwhale00melv")
    }

    func test_archiveOrg_extractsIdentifierFromDetailsURL() {
        let url = URL(string: "https://archive.org/details/mobydickorwhale00melv")!
        XCTAssertEqual(ArchiveOrgItem.identifier(from: url), "mobydickorwhale00melv")
    }

    func test_archiveOrg_ignoresNonArchiveHosts() {
        let url = URL(string: "https://example.org/download/something/file.pdf")!
        XCTAssertNil(ArchiveOrgItem.identifier(from: url))
    }

    func test_archiveOrg_buildsPerItemTorrentURL() {
        let url = ArchiveOrgItem.torrentURL(itemID: "mobydickorwhale00melv")
        XCTAssertEqual(
            url?.absoluteString,
            "https://archive.org/download/mobydickorwhale00melv/mobydickorwhale00melv_archive.torrent"
        )
    }

    func test_archiveOrg_entryExposesItemIdentifier() throws {
        let feed = try OPDSParser.parseAtom(data: Data(Fixtures.archiveFeed.utf8), baseURL: base)
        let entry = try XCTUnwrap(feed.entries.first)
        XCTAssertEqual(entry.archiveItemID, "mobydickorwhale00melv")
    }
}

// MARK: - Fixtures

private enum Fixtures {

    static let navigationFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Project Gutenberg</title>
      <id>https://example.org/catalog/</id>
      <entry>
        <title>Popular</title>
        <id>https://example.org/catalog/popular</id>
        <content type="text">Our most downloaded books.</content>
        <link type="application/atom+xml;profile=opds-catalog;kind=acquisition"
              rel="subsection" href="popular"/>
      </entry>
      <entry>
        <title>Latest</title>
        <id>https://example.org/catalog/latest</id>
        <link type="application/atom+xml;profile=opds-catalog;kind=acquisition"
              rel="subsection" href="/catalog/latest"/>
      </entry>
    </feed>
    """

    static let acquisitionFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"
          xmlns:dc="http://purl.org/dc/terms/"
          xmlns:opds="http://opds-spec.org/2010/catalog">
      <title>Most Popular</title>
      <id>https://example.org/catalog/popular</id>
      <link rel="next" type="application/atom+xml" href="page2"/>
      <link rel="search" type="application/opensearchdescription+xml" href="/opensearch.xml"/>
      <entry>
        <title>Moby Dick; Or, The Whale</title>
        <id>urn:gutenberg:2701</id>
        <updated>2024-03-11T18:22:00Z</updated>
        <author><name>Herman Melville</name></author>
        <dc:language>en</dc:language>
        <dc:publisher>Project Gutenberg</dc:publisher>
        <summary type="html">&lt;p&gt;The   sailor Ishmael tells   the story.&lt;/p&gt;</summary>
        <category term="Whaling -- Fiction"/>
        <category term="sea" label="Sea stories"/>
        <link rel="http://opds-spec.org/image" type="image/jpeg" href="/covers/2701.cover.medium.jpg"/>
        <link rel="http://opds-spec.org/image/thumbnail" type="image/jpeg" href="/covers/2701.cover.small.jpg"/>
        <link rel="http://opds-spec.org/acquisition/open-access"
              type="application/epub+zip" href="/ebooks/2701.epub"/>
        <link rel="http://opds-spec.org/acquisition/open-access"
              type="text/plain" href="/ebooks/2701.txt"/>
      </entry>
      <entry>
        <title>Pride and Prejudice</title>
        <id>urn:gutenberg:1342</id>
        <author><name>Jane Austen</name></author>
        <link rel="http://opds-spec.org/acquisition/open-access"
              type="application/epub+zip" href="/ebooks/1342.epub"/>
      </entry>
      <entry>
        <title>A Book Without A Cover</title>
        <id>urn:example:nocover</id>
        <link rel="http://opds-spec.org/acquisition"
              type="application/epub+zip" href="/ebooks/nocover.epub"/>
      </entry>
    </feed>
    """

    static let drmAndPricedFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
      <title>Mixed Shelf</title>
      <id>https://example.org/catalog/mixed</id>
      <entry>
        <title>DRM Protected Book</title>
        <id>urn:example:drm</id>
        <link rel="http://opds-spec.org/acquisition"
              type="application/vnd.adobe.adept+xml" href="/fulfill/1.acsm">
          <opds:indirectAcquisition type="application/epub+zip"/>
        </link>
      </entry>
      <entry>
        <title>A Book For Sale</title>
        <id>urn:example:paid</id>
        <link rel="http://opds-spec.org/acquisition/buy"
              type="application/epub+zip" href="/buy/2">
          <opds:price currencycode="USD">9.99</opds:price>
        </link>
      </entry>
      <entry>
        <title>A Borrowable Book</title>
        <id>urn:example:borrow</id>
        <link rel="http://opds-spec.org/acquisition/borrow"
              type="application/epub+zip" href="/borrow/3"/>
      </entry>
      <entry>
        <title>A Free Book</title>
        <id>urn:example:free</id>
        <link rel="http://opds-spec.org/acquisition/open-access"
              type="application/epub+zip" href="/ebooks/free.epub"/>
      </entry>
    </feed>
    """

    static let archiveFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Internet Archive</title>
      <id>https://bookserver.archive.org/catalog/</id>
      <entry>
        <title>Moby Dick</title>
        <id>urn:archive:mobydickorwhale00melv</id>
        <author><name>Herman Melville</name></author>
        <link rel="http://opds-spec.org/acquisition/open-access" type="application/pdf"
              href="https://archive.org/download/mobydickorwhale00melv/mobydickorwhale00melv.pdf"/>
      </entry>
    </feed>
    """

    static let openSearchDocument = """
    <?xml version="1.0" encoding="UTF-8"?>
    <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
      <ShortName>Example</ShortName>
      <Url type="text/html" template="https://example.org/search?q={searchTerms}"/>
      <Url type="application/atom+xml;profile=opds-catalog"
           template="https://example.org/search?q={searchTerms}&amp;format=atom"/>
    </OpenSearchDescription>
    """

    static let opds2Feed = """
    {
      "metadata": { "title": "Gutendex" },
      "links": [
        { "rel": "self", "href": "https://example.org/catalog/", "type": "application/opds+json" },
        { "rel": "next", "href": "?page=2", "type": "application/opds+json" },
        { "rel": "search", "href": "https://example.org/search{?searchTerms}", "templated": true }
      ],
      "navigation": [
        { "title": "Browse by language", "href": "/catalog/languages", "type": "application/opds+json" }
      ],
      "publications": [
        {
          "metadata": {
            "identifier": "urn:gutenberg:84",
            "title": "Frankenstein",
            "author": { "name": "Mary Wollstonecraft Shelley" },
            "language": "en",
            "subject": ["Gothic fiction", "Science fiction"],
            "description": "<p>Victor Frankenstein builds a creature.</p>",
            "modified": "2024-01-02T03:04:05Z"
          },
          "images": [
            { "href": "/covers/84-large.jpg", "type": "image/jpeg" },
            { "href": "/covers/84-small.jpg", "type": "image/jpeg" }
          ],
          "links": [
            {
              "rel": "http://opds-spec.org/acquisition/open-access",
              "href": "/ebooks/84.epub",
              "type": "application/epub+zip"
            }
          ]
        },
        {
          "metadata": {
            "title": "Sense and Sensibility",
            "author": ["Jane Austen", "Anonymous"],
            "language": ["en", "fr"]
          },
          "links": [
            {
              "rel": "http://opds-spec.org/acquisition/open-access",
              "href": "/ebooks/161.epub",
              "type": "application/epub+zip"
            }
          ]
        }
      ]
    }
    """
}
