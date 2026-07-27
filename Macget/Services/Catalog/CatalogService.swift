import Foundation

/// Front door for the book browser. Routes each request to the backend a catalog
/// actually speaks, so `BookBrowserModel` never branches on catalog kind.
///
/// Most catalogs are OPDS. The Internet Archive is not, because it retired its
/// OPDS BookServer — see `ArchiveOrgClient`.
actor CatalogService {
    private let opds: OPDSClient
    private let archive: ArchiveOrgClient
    private let gutendex: GutendexClient

    init(
        opds: OPDSClient = OPDSClient(),
        archive: ArchiveOrgClient = ArchiveOrgClient(),
        gutendex: GutendexClient = GutendexClient()
    ) {
        self.opds = opds
        self.archive = archive
        self.gutendex = gutendex
    }

    /// The catalog's top-level feed.
    func rootFeed(for source: CatalogSource) async throws -> CatalogFeed {
        switch source.kind {
        case .opds:       return try await opds.loadFeed(at: source.feedURL)
        case .archiveOrg: return await archive.rootFeed()
        case .gutendex:   return await gutendex.rootFeed()
        }
    }

    /// Follow a navigation link or a `next` page. The URL always came from the
    /// same backend, so it's safe to dispatch on the source's kind.
    func loadFeed(at url: URL, for source: CatalogSource) async throws -> CatalogFeed {
        switch source.kind {
        case .opds:       return try await opds.loadFeed(at: url)
        case .archiveOrg: return try await archive.loadFeed(at: url)
        case .gutendex:   return try await gutendex.loadFeed(at: url)
        }
    }

    func search(query: String, in source: CatalogSource) async throws -> CatalogFeed {
        switch source.kind {
        case .opds:       return try await opds.search(query: query, in: source)
        case .archiveOrg: return try await archive.search(query: query)
        case .gutendex:   return try await gutendex.search(query: query)
        }
    }

    /// Fill in an entry's real download links.
    ///
    /// OPDS feeds carry acquisitions inline, so this is a no-op there. archive.org
    /// search results only carry an identifier — the file list is a second request,
    /// deferred until the user actually selects a book so a 50-result page doesn't
    /// fan out into 50 requests.
    func resolveAcquisitions(for entry: CatalogEntry, in source: CatalogSource) async throws -> [AcquisitionLink] {
        guard source.kind == .archiveOrg else { return entry.acquisitions }
        guard let itemID = entry.archiveItemID ?? (entry.acquisitions.isEmpty ? entry.id : nil) else {
            return entry.acquisitions
        }
        let resolved = try await archive.acquisitions(forItem: itemID)
        // Keep the details link so "view on archive.org" and `archiveItemID` still
        // work even when an item exposes no downloadable format.
        return resolved.isEmpty ? entry.acquisitions : resolved
    }
}
