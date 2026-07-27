import Foundation

// MARK: - Catalog sources

/// One OPDS catalog root the user can browse. Built-ins ship with the app and
/// can be disabled but not deleted; user-added ones can be removed.
///
/// `id` is stable for built-ins (hardcoded UUIDs) so a user's enable/disable
/// choice survives relaunch even though the built-in list itself isn't persisted.
struct CatalogSource: Identifiable, Codable, Sendable, Equatable, Hashable {
    let id: UUID
    var name: String
    var feedURL: URL
    var isBuiltIn: Bool
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, feedURL: URL, isBuiltIn: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.feedURL = feedURL
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
    }

    // Explicit Codable with `decodeIfPresent` defaults, matching the discipline in
    // `Download` — an older catalogs.json missing a field must still decode rather
    // than dropping every catalog the user added.
    private enum CodingKeys: String, CodingKey {
        case id, name, feedURL, isBuiltIn, isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        feedURL = try c.decode(URL.self, forKey: .feedURL)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

extension CatalogSource {
    /// Catalogs that ship with the app. All are free/public-domain or
    /// openly-licensed sources that publish a documented OPDS feed.
    static let builtIns: [CatalogSource] = [
        CatalogSource(
            id: UUID(uuidString: "1A5E0C10-0000-4000-A000-000000000001")!,
            name: "Project Gutenberg",
            feedURL: URL(string: "https://m.gutenberg.org/ebooks.opds/")!,
            isBuiltIn: true
        ),
        CatalogSource(
            id: UUID(uuidString: "1A5E0C10-0000-4000-A000-000000000002")!,
            name: "Standard Ebooks",
            feedURL: URL(string: "https://standardebooks.org/feeds/opds")!,
            isBuiltIn: true
        ),
        CatalogSource(
            id: UUID(uuidString: "1A5E0C10-0000-4000-A000-000000000003")!,
            name: "Internet Archive",
            feedURL: URL(string: "https://bookserver.archive.org/catalog/")!,
            isBuiltIn: true
        ),
    ]

    /// Per-catalog search endpoint used when the feed doesn't advertise an
    /// OpenSearch description (Gutenberg's mobile feed is the notable case).
    /// `{searchTerms}` is substituted with the percent-encoded query.
    var fallbackSearchTemplate: String? {
        guard let host = feedURL.host?.lowercased() else { return nil }
        if host.hasSuffix("gutenberg.org") {
            return "https://www.gutenberg.org/ebooks/search.opds/?query={searchTerms}"
        }
        if host.hasSuffix("standardebooks.org") {
            return "https://standardebooks.org/feeds/opds/all?query={searchTerms}"
        }
        if host.hasSuffix("archive.org") {
            return "https://bookserver.archive.org/catalog/search?q={searchTerms}"
        }
        return nil
    }
}

// MARK: - Parsed feed

/// A parsed OPDS feed. A feed can be a *navigation* feed (links to sub-catalogs),
/// an *acquisition* feed (actual publications), or in practice a mix of both.
struct CatalogFeed: Sendable, Equatable {
    var title: String?
    var navigation: [CatalogNavigationLink] = []
    var entries: [CatalogEntry] = []
    /// `rel="next"` — appended to the current results when the user scrolls.
    var nextPageURL: URL?
    /// An OpenSearch description document advertised by the feed. Must be fetched
    /// and parsed to learn the actual query template.
    var searchDescriptionURL: URL?
    /// A ready-to-use `{searchTerms}` template, when the feed inlined one instead
    /// of pointing at an OpenSearch document.
    var searchTemplate: String?

    var isEmpty: Bool { navigation.isEmpty && entries.isEmpty }
}

/// A link to a sub-catalog — a shelf, a genre, "Most popular", etc.
struct CatalogNavigationLink: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    var title: String
    var url: URL
    var subtitle: String?
}

/// One publication in an acquisition feed.
struct CatalogEntry: Identifiable, Sendable, Equatable {
    let id: String
    var title: String
    var authors: [String] = []
    var summary: String?
    var publisher: String?
    var language: String?
    var subjects: [String] = []
    var coverURL: URL?
    var thumbnailURL: URL?
    var updated: Date?
    var acquisitions: [AcquisitionLink] = []

    var authorLine: String {
        authors.isEmpty ? "Unknown author" : authors.joined(separator: ", ")
    }

    /// Links MacGet can actually download — open-access or otherwise unpriced,
    /// in a format we recognize.
    var downloadableAcquisitions: [AcquisitionLink] {
        acquisitions.filter { $0.isDownloadable }
    }

    /// True when every acquisition link requires payment. Such entries are shown
    /// but link out to the seller rather than downloading.
    var isPurchaseOnly: Bool {
        !acquisitions.isEmpty && downloadableAcquisitions.isEmpty
    }

    /// The archive.org item identifier, when this entry came from Internet
    /// Archive's BookServer. Used to offer the per-item `.torrent`.
    var archiveItemID: String? {
        for link in acquisitions {
            if let id = ArchiveOrgItem.identifier(from: link.url) { return id }
        }
        return nil
    }
}

// MARK: - Acquisition links

/// A single downloadable (or purchasable) representation of a publication.
struct AcquisitionLink: Identifiable, Sendable, Equatable, Hashable {
    var id: String { "\(relation.rawValue)|\(mimeType)|\(url.absoluteString)" }
    var url: URL
    var mimeType: String
    var relation: Relation
    var price: Price?

    enum Relation: String, Sendable, Hashable {
        case openAccess
        case buy
        case borrow
        case subscribe
        case sample
        /// Bare `http://opds-spec.org/acquisition` — free to fetch unless priced.
        case generic

        init(rel: String) {
            switch rel {
            case "http://opds-spec.org/acquisition/open-access": self = .openAccess
            case "http://opds-spec.org/acquisition/buy":         self = .buy
            case "http://opds-spec.org/acquisition/borrow":      self = .borrow
            case "http://opds-spec.org/acquisition/subscribe":   self = .subscribe
            case "http://opds-spec.org/acquisition/sample":      self = .sample
            default:                                             self = .generic
            }
        }

        /// Rels whose href is a direct fetch rather than a checkout flow.
        var isDirectDownload: Bool {
            self == .openAccess || self == .generic || self == .sample
        }
    }

    struct Price: Sendable, Equatable, Hashable {
        var amount: Decimal
        var currencyCode: String

        var display: String {
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = currencyCode
            return f.string(from: amount as NSDecimalNumber) ?? "\(amount) \(currencyCode)"
        }
    }

    var format: BookFormat? { BookFormat(mimeType: mimeType) }

    /// MacGet can fetch this link directly: it's a direct-download rel, carries no
    /// price, is plain http(s), and is a format we recognize.
    var isDownloadable: Bool {
        guard relation.isDirectDownload, price == nil, let format, format.isSupported else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return true
    }
}

// MARK: - Formats

/// Publication formats MacGet recognizes. `isSupported == false` means we can
/// display the format but shouldn't offer a download button for it — either it's
/// DRM-wrapped or it's a fulfilment document rather than the book itself.
enum BookFormat: Sendable, Equatable, Hashable {
    case epub
    case pdf
    case mobi
    case azw3
    case cbz
    case plainText
    case htmlZip
    case audiobook
    /// Adobe ADEPT / LCP fulfilment — a license token, not a book. Never offered.
    case drmProtected
    case other(String)

    init?(mimeType raw: String) {
        // Strip parameters: "application/epub+zip; charset=utf-8" -> "application/epub+zip"
        let type = raw
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !type.isEmpty else { return nil }
        switch type {
        case "application/epub+zip", "application/epub":
            self = .epub
        case "application/pdf":
            self = .pdf
        case "application/x-mobipocket-ebook", "application/x-mobi8-ebook":
            self = .mobi
        case "application/vnd.amazon.ebook", "application/vnd.amazon.mobi8-ebook":
            self = .azw3
        case "application/vnd.comicbook+zip", "application/x-cbz":
            self = .cbz
        case "text/plain":
            self = .plainText
        case "application/zip", "application/x-zip-compressed":
            self = .htmlZip
        case "application/audiobook+json", "audio/mpeg", "application/vnd.audiobook+zip":
            self = .audiobook
        case "application/vnd.adobe.adept+xml",
             "application/vnd.readium.lcp.license.v1.0+json",
             "application/vnd.readium.license.status.v1.0+json":
            self = .drmProtected
        default:
            self = .other(type)
        }
    }

    var isSupported: Bool {
        switch self {
        case .drmProtected, .other: return false
        default:                    return true
        }
    }

    /// Extension used when MacGet names the downloaded file itself.
    var fileExtension: String {
        switch self {
        case .epub:         return "epub"
        case .pdf:          return "pdf"
        case .mobi:         return "mobi"
        case .azw3:         return "azw3"
        case .cbz:          return "cbz"
        case .plainText:    return "txt"
        case .htmlZip:      return "zip"
        case .audiobook:    return "m4b"
        case .drmProtected: return "acsm"
        case .other:        return "bin"
        }
    }

    var displayName: String {
        switch self {
        case .epub:            return "EPUB"
        case .pdf:             return "PDF"
        case .mobi:            return "MOBI"
        case .azw3:            return "AZW3"
        case .cbz:             return "CBZ"
        case .plainText:       return "Plain text"
        case .htmlZip:         return "HTML (zip)"
        case .audiobook:       return "Audiobook"
        case .drmProtected:    return "DRM-protected"
        case .other(let type): return type
        }
    }

    /// Preference order when auto-picking a format for the one-click download.
    var preferenceRank: Int {
        switch self {
        case .epub:      return 0
        case .azw3:      return 1
        case .mobi:      return 2
        case .pdf:       return 3
        case .cbz:       return 4
        case .htmlZip:   return 5
        case .plainText: return 6
        case .audiobook: return 7
        default:         return 99
        }
    }
}

// MARK: - archive.org

/// Helpers for recognizing Internet Archive items, which expose a per-item
/// `.torrent` covering every file in the item.
enum ArchiveOrgItem {
    /// Extract the item identifier from an archive.org download/details URL.
    /// Returns nil for any non-archive.org host.
    static func identifier(from url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "archive.org" || host.hasSuffix(".archive.org") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        switch parts[0] {
        case "download", "details", "stream", "compress":
            let id = parts[1]
            return id.isEmpty ? nil : id
        default:
            return nil
        }
    }

    /// The per-item torrent, which the Internet Archive generates for every item.
    static func torrentURL(itemID: String) -> URL? {
        guard let encoded = itemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://archive.org/download/\(encoded)/\(encoded)_archive.torrent")
    }
}
