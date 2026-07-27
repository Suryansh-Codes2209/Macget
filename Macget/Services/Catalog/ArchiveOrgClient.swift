import Foundation
import OSLog

/// Reads the Internet Archive's book collections through its JSON APIs and maps
/// them into the same `CatalogFeed` the OPDS path produces, so the browser UI
/// doesn't care which backend it's talking to.
///
/// This exists because IA **retired its OPDS BookServer**: `bookserver.archive.org`
/// no longer resolves at all. The replacement path is two documented endpoints:
///
/// - `advancedsearch.php?output=json` — search/browse, returns item identifiers.
/// - `metadata/<identifier>/files` — per-item file list, which is where the
///   actual downloadable EPUB/PDF/text URLs come from.
///
/// File listings are fetched lazily per item (a search page would otherwise cost
/// 50 extra requests), so a search result's `acquisitions` starts as a single
/// details link and is filled in when the user selects the book.
actor ArchiveOrgClient {
    private let session: URLSession
    private let log = Logger(subsystem: "com.macget", category: "ArchiveOrg")

    init(session: URLSession = URLSessionFactory.metadata) {
        self.session = session
    }

    /// Shelves offered at the catalog root. IA has no navigation feed of its own,
    /// so MacGet curates a few high-value public-domain collections.
    private static let shelves: [(title: String, subtitle: String, query: String)] = [
        ("Popular books", "Most-downloaded texts", "mediatype:texts AND NOT collection:inlibrary"),
        ("Project Gutenberg", "Gutenberg's catalog mirrored on IA", "collection:gutenberg"),
        ("American Libraries", "Scanned books from US libraries", "collection:americana"),
        ("Children's literature", "Public-domain children's books", "collection:childrenslibrary"),
        ("Science & mathematics", "Texts on science and maths", "mediatype:texts AND subject:science"),
    ]

    // MARK: - Browsing

    func rootFeed() -> CatalogFeed {
        var feed = CatalogFeed()
        feed.title = "Internet Archive"
        feed.navigation = Self.shelves.compactMap { shelf in
            guard let url = Self.searchURL(query: shelf.query, page: 1) else { return nil }
            return CatalogNavigationLink(
                id: shelf.query,
                title: shelf.title,
                url: url,
                subtitle: shelf.subtitle
            )
        }
        return feed
    }

    /// Load a shelf or a page of results. `url` is always an `advancedsearch.php`
    /// URL that this client built itself.
    func loadFeed(at url: URL) async throws -> CatalogFeed {
        let (data, _) = try await get(url)
        let decoded = try decodeSearch(data)
        var feed = CatalogFeed()
        feed.entries = decoded.response.docs.compactMap { $0.catalogEntry() }
        feed.nextPageURL = Self.nextPage(after: url, returned: decoded.response.docs.count, total: decoded.response.numFound)
        return feed
    }

    func search(query: String) async throws -> CatalogFeed {
        // Restrict to texts so a search doesn't return films and software.
        let scoped = "\(query) AND mediatype:texts"
        guard let url = Self.searchURL(query: scoped, page: 1) else {
            throw OPDSClientError.searchUnsupported(catalog: "Internet Archive")
        }
        return try await loadFeed(at: url)
    }

    // MARK: - Per-item files

    /// Resolve an item's actual downloadable formats. Called when the user selects
    /// a book, because doing it for every search hit would mean ~50 extra requests
    /// per page.
    func acquisitions(forItem identifier: String) async throws -> [AcquisitionLink] {
        guard let url = URL(string: "https://archive.org/metadata/\(identifier)/files") else { return [] }
        let (data, _) = try await get(url)
        let decoded = try JSONDecoder().decode(FilesResponse.self, from: data)

        return decoded.result.compactMap { file -> AcquisitionLink? in
            guard let format = file.format, let name = file.name else { return nil }
            guard let mimeType = Self.mimeType(forArchiveFormat: format) else { return nil }
            guard let href = Self.downloadURL(item: identifier, file: name) else { return nil }
            return AcquisitionLink(url: href, mimeType: mimeType, relation: .openAccess, price: nil)
        }
    }

    /// Map IA's human-readable `format` strings to MIME types.
    ///
    /// Returns nil for everything MacGet shouldn't offer — scan intermediates
    /// (JP2 archives, OCR blobs, DjVu XML) and, importantly, the DRM variants.
    /// IA ships `LCP Encrypted EPUB`, `LCP Encrypted PDF`, and `ACS Encrypted PDF`
    /// right alongside the free ones; those are license-wrapped and must never be
    /// presented as downloads.
    static func mimeType(forArchiveFormat format: String) -> String? {
        switch format {
        case "EPUB":                       return "application/epub+zip"
        case "Text PDF", "PDF":            return "application/pdf"
        case "Grayscale PDF":              return "application/pdf"
        case "DjVuTXT", "Text":            return "text/plain"
        case "Comic Book RAR", "Comic Book ZIP": return "application/vnd.comicbook+zip"
        default:                           return nil
        }
    }

    static func downloadURL(item: String, file: String) -> URL? {
        var components = URLComponents(string: "https://archive.org/download/")
        components?.path = "/download/\(item)/\(file)"
        return components?.url
    }

    // MARK: - URL construction

    static let pageSize = 50

    static func searchURL(query: String, page: Int) -> URL? {
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "fl[]", value: "description"),
            URLQueryItem(name: "fl[]", value: "year"),
            URLQueryItem(name: "fl[]", value: "language"),
            URLQueryItem(name: "fl[]", value: "subject"),
            URLQueryItem(name: "fl[]", value: "publisher"),
            URLQueryItem(name: "rows", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "output", value: "json"),
        ]
        return components?.url
    }

    /// Advance the `page` parameter, stopping once the result set is exhausted.
    static func nextPage(after url: URL, returned: Int, total: Int) -> URL? {
        guard returned > 0 else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        let currentPage = items.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
        guard currentPage * pageSize < total else { return nil }
        components.queryItems = items.map { item in
            item.name == "page" ? URLQueryItem(name: "page", value: String(currentPage + 1)) : item
        }
        return components.url
    }

    static func coverURL(item: String) -> URL? {
        URL(string: "https://archive.org/services/img/\(item)")
    }

    // MARK: - Networking

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OPDSClientError.httpStatus(http.statusCode)
        }
        return (data, response)
    }

    private func decodeSearch(_ data: Data) throws -> SearchResponse {
        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw OPDSParseError.malformedJSON(error.localizedDescription)
        }
    }
}

// MARK: - Wire models

private struct SearchResponse: Decodable {
    var response: Body

    struct Body: Decodable {
        var numFound: Int
        var docs: [Doc]
    }
}

private struct Doc: Decodable {
    var identifier: String?
    var title: ArchiveStringOrArray?
    var creator: ArchiveStringOrArray?
    var description: ArchiveStringOrArray?
    var publisher: ArchiveStringOrArray?
    var language: ArchiveStringOrArray?
    var subject: ArchiveStringOrArray?
    var year: ArchiveIntOrString?

    func catalogEntry() -> CatalogEntry? {
        guard let identifier, let title = title?.values.first, !title.isEmpty else { return nil }
        // The details page stands in for the acquisition list until the user
        // selects the book and `acquisitions(forItem:)` fills in real files. It
        // also carries the identifier, which is what `archiveItemID` reads.
        let detailsLink = URL(string: "https://archive.org/details/\(identifier)").map {
            AcquisitionLink(url: $0, mimeType: "text/html", relation: .generic, price: nil)
        }
        return CatalogEntry(
            id: identifier,
            title: title,
            authors: creator?.values ?? [],
            summary: description?.values.first.map(CatalogText.strippingHTML),
            publisher: publisher?.values.first,
            language: language?.values.first,
            subjects: Array((subject?.values ?? []).prefix(8)),
            coverURL: ArchiveOrgClient.coverURL(item: identifier),
            thumbnailURL: ArchiveOrgClient.coverURL(item: identifier),
            updated: nil,
            acquisitions: [detailsLink].compactMap { $0 }
        )
    }
}

private struct FilesResponse: Decodable {
    var result: [FileEntry]

    struct FileEntry: Decodable {
        var name: String?
        var format: String?
        var size: String?
    }
}

/// archive.org returns most metadata fields as "string or array of string".
private struct ArchiveStringOrArray: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            values = [single]
        } else if let many = try? container.decode([String].self) {
            values = many
        } else {
            values = []
        }
    }
}

private struct ArchiveIntOrString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let i = try? container.decode(Int.self) {
            value = String(i)
        } else {
            value = nil
        }
    }
}
