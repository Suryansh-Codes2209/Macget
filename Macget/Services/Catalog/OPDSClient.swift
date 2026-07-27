import Foundation
import OSLog

enum OPDSClientError: Error, LocalizedError {
    case httpStatus(Int)
    case searchUnsupported(catalog: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "The catalog returned HTTP \(code)."
        case .searchUnsupported(let catalog):
            return "\(catalog) doesn't support searching. Browse its shelves instead."
        case .emptyResponse:
            return "The catalog returned an empty response."
        }
    }
}

/// Fetches and parses OPDS feeds. All parsing is delegated to `OPDSParser`, so
/// this type only owns networking, redirect-safe base URLs, and the per-catalog
/// search-template cache.
actor OPDSClient {
    private let session: URLSession
    private let log = Logger(subsystem: "com.macget", category: "OPDS")

    /// Resolved `{searchTerms}` templates, keyed by catalog. Discovering one costs
    /// an extra request for the OpenSearch description document, so it's cached
    /// for the process lifetime rather than refetched per keystroke.
    private var searchTemplates: [UUID: String] = [:]

    /// Uses `URLSessionFactory.metadata`, not `.shared` — a catalog fetch backs a
    /// spinner and must fail fast, where `.shared` would wait indefinitely for
    /// connectivity.
    init(session: URLSession = URLSessionFactory.metadata) {
        self.session = session
    }

    // MARK: - Browsing

    /// Load and parse a feed. `url` is typically a catalog root, a navigation
    /// link, or a `rel="next"` page.
    func loadFeed(at url: URL) async throws -> CatalogFeed {
        let (data, response) = try await get(url)
        guard !data.isEmpty else { throw OPDSClientError.emptyResponse }
        // Resolve relative hrefs against the *final* URL so a catalog that
        // redirects (http→https, or /catalog → /catalog/) still yields links that
        // resolve correctly.
        let base = response.url ?? url
        return try OPDSParser.parse(data: data, mimeType: response.mimeType, baseURL: base)
    }

    // MARK: - Searching

    /// Search a catalog. Resolves the catalog's search template on first use —
    /// from the feed's OpenSearch document, an inline template, or MacGet's
    /// per-host fallback for the built-ins.
    func search(query: String, in source: CatalogSource) async throws -> CatalogFeed {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await loadFeed(at: source.feedURL) }

        guard let template = try await searchTemplate(for: source) else {
            throw OPDSClientError.searchUnsupported(catalog: source.name)
        }
        guard let url = OPDSParser.expand(searchTemplate: template, query: trimmed) else {
            throw OPDSClientError.searchUnsupported(catalog: source.name)
        }
        return try await loadFeed(at: url)
    }

    /// True when we already know this catalog can be searched — lets the UI hide
    /// the search field for catalogs that can only be browsed.
    func hasCachedSearchTemplate(for source: CatalogSource) -> Bool {
        searchTemplates[source.id] != nil
    }

    private func searchTemplate(for source: CatalogSource) async throws -> String? {
        if let cached = searchTemplates[source.id] { return cached }

        // Try the catalog's own advertisement first, so user-added feeds work
        // without MacGet knowing anything about them.
        if let discovered = try? await discoverSearchTemplate(from: source.feedURL) {
            searchTemplates[source.id] = discovered
            return discovered
        }
        // Built-ins whose feeds don't advertise OpenSearch (Gutenberg's mobile
        // feed is the notable one) get a known-good template.
        if let fallback = source.fallbackSearchTemplate {
            searchTemplates[source.id] = fallback
            return fallback
        }
        log.info("No search template for catalog \(source.name, privacy: .public)")
        return nil
    }

    private func discoverSearchTemplate(from feedURL: URL) async throws -> String? {
        let feed = try await loadFeed(at: feedURL)
        if let inline = feed.searchTemplate { return inline }
        guard let descriptionURL = feed.searchDescriptionURL else { return nil }
        let (data, _) = try await get(descriptionURL)
        return OPDSParser.parseOpenSearchTemplate(data: data)
    }

    // MARK: - Networking

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        // Ask for OPDS explicitly. Several catalogs content-negotiate and will
        // serve an HTML page to a client that doesn't say what it wants.
        request.setValue(
            "application/atom+xml;profile=opds-catalog, application/opds+json, application/atom+xml;q=0.9, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        URLSessionFactory.applyTransportPreferences(to: &request)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OPDSClientError.httpStatus(http.statusCode)
        }
        return (data, response)
    }
}
