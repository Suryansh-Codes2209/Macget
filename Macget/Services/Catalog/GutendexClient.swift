import Foundation
import OSLog

/// Reads Project Gutenberg through Gutendex, mapping into the shared
/// `CatalogFeed` model.
///
/// Gutenberg's own OPDS feed can't back a book browser: its search results are
/// *navigation* entries — one `/ebooks/<id>.opds` sub-feed per book — so getting
/// a download link means an extra request per result, and those per-book feeds
/// were returning 504s when this was written. There is no OPDS2 search endpoint
/// (`search.opds2` is a 404).
///
/// Gutendex is a JSON API over the same catalog that returns every format's
/// direct URL inline, which is exactly what the grid needs. The OPDS path remains
/// for user-added feeds (Calibre servers and the like).
actor GutendexClient {
    private let session: URLSession
    private let log = Logger(subsystem: "com.macget", category: "Gutendex")

    init(session: URLSession = URLSessionFactory.metadata) {
        self.session = session
    }

    private static let base = "https://gutendex.com/books"

    /// Curated shelves, since Gutendex has no navigation document.
    private static let shelves: [(title: String, subtitle: String, query: [URLQueryItem])] = [
        ("Most popular", "Gutenberg's most-downloaded books",
         [URLQueryItem(name: "sort", value: "popular")]),
        ("Recently added", "Newest additions to the catalog",
         [URLQueryItem(name: "sort", value: "descending")]),
        ("Fiction", "Novels and short stories",
         [URLQueryItem(name: "topic", value: "fiction")]),
        ("History", "Historical works and memoirs",
         [URLQueryItem(name: "topic", value: "history")]),
        ("Science", "Science and natural philosophy",
         [URLQueryItem(name: "topic", value: "science")]),
        ("Children's books", "Books for younger readers",
         [URLQueryItem(name: "topic", value: "children")]),
    ]

    // MARK: - Browsing

    func rootFeed() -> CatalogFeed {
        var feed = CatalogFeed()
        feed.title = "Project Gutenberg"
        feed.navigation = Self.shelves.compactMap { shelf in
            guard let url = Self.url(with: shelf.query) else { return nil }
            return CatalogNavigationLink(
                id: shelf.title,
                title: shelf.title,
                url: url,
                subtitle: shelf.subtitle
            )
        }
        return feed
    }

    func loadFeed(at url: URL) async throws -> CatalogFeed {
        let (data, _) = try await get(url)
        let page: GutendexPage
        do {
            page = try JSONDecoder().decode(GutendexPage.self, from: data)
        } catch {
            throw OPDSParseError.malformedJSON(error.localizedDescription)
        }
        var feed = CatalogFeed()
        feed.entries = page.results.compactMap { $0.catalogEntry() }
        // Gutendex hands back an absolute `next` URL, so pagination is free.
        feed.nextPageURL = page.next.flatMap(URL.init(string:))
        return feed
    }

    func search(query: String) async throws -> CatalogFeed {
        guard let url = Self.url(with: [URLQueryItem(name: "search", value: query)]) else {
            throw OPDSClientError.searchUnsupported(catalog: "Project Gutenberg")
        }
        return try await loadFeed(at: url)
    }

    static func url(with items: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = items
        return components?.url
    }

    // MARK: - Networking

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        // Gutendex 406s on a multi-type Accept header — it wants plain JSON.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OPDSClientError.httpStatus(http.statusCode)
        }
        return (data, response)
    }
}

// MARK: - Wire model

private struct GutendexPage: Decodable {
    var count: Int
    var next: String?
    var results: [Book]
}

private struct Book: Decodable {
    var id: Int
    var title: String
    var authors: [Person]?
    var subjects: [String]?
    var languages: [String]?
    /// MIME type → direct download URL.
    var formats: [String: String]?

    struct Person: Decodable {
        var name: String?
    }

    func catalogEntry() -> CatalogEntry? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var acquisitions: [AcquisitionLink] = []
        var cover: URL?
        for (mimeType, href) in formats ?? [:] {
            guard let url = URL(string: href) else { continue }
            if mimeType.hasPrefix("image/") {
                // Prefer the medium cover Gutenberg generates; any image will do.
                if cover == nil || href.contains("medium") { cover = url }
                continue
            }
            // Only keep formats the app can actually present. Gutendex also lists
            // `application/rdf+xml` metadata and an `application/octet-stream`
            // HTML zip, neither of which belongs in a "Download" list.
            guard let format = BookFormat(mimeType: mimeType), format.isSupported else { continue }
            acquisitions.append(
                AcquisitionLink(url: url, mimeType: mimeType, relation: .openAccess, price: nil)
            )
        }
        guard !acquisitions.isEmpty else { return nil }

        // Gutenberg stores names as "Melville, Herman" — flip to reading order.
        let names = (authors ?? []).compactMap(\.name).map(Self.displayName)

        return CatalogEntry(
            id: "gutenberg:\(id)",
            title: trimmed,
            authors: names,
            summary: nil,
            publisher: "Project Gutenberg",
            language: languages?.first,
            subjects: Array((subjects ?? []).prefix(8)),
            coverURL: cover,
            thumbnailURL: cover,
            updated: nil,
            acquisitions: acquisitions
        )
    }

    /// "Melville, Herman" → "Herman Melville". Left alone when there's no comma
    /// or more than one (corporate authors, "Jr." suffixes, and the like).
    static func displayName(_ raw: String) -> String {
        let parts = raw.components(separatedBy: ", ")
        guard parts.count == 2 else { return raw }
        return "\(parts[1]) \(parts[0])"
    }
}
