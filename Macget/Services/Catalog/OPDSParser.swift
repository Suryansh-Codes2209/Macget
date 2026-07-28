import Foundation

enum OPDSParseError: Error, LocalizedError {
    case unrecognizedFormat
    case malformedXML(String)
    case malformedJSON(String)

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return "This doesn't look like an OPDS catalog."
        case .malformedXML(let detail):
            return "Could not read the catalog feed: \(detail)"
        case .malformedJSON(let detail):
            return "Could not read the catalog feed: \(detail)"
        }
    }
}

/// Parses OPDS catalog feeds. Pure and synchronous — all network work lives in
/// `OPDSClient`, so every branch here is unit-testable against fixture data.
///
/// Two wire formats are supported:
/// - **OPDS 1.2** — Atom XML. Still what Gutenberg, Standard Ebooks, and the
///   Internet Archive serve today.
/// - **OPDS 2.0** — JSON. Gutenberg has announced it is retiring its XML feeds in
///   2027, so this path exists from the start rather than as a later migration.
enum OPDSParser {

    /// Parse a feed, sniffing the format from the Content-Type when available and
    /// falling back to inspecting the bytes.
    static func parse(data: Data, mimeType: String? = nil, baseURL: URL) throws -> CatalogFeed {
        switch format(mimeType: mimeType, data: data) {
        case .json: return try parseJSON(data: data, baseURL: baseURL)
        case .xml:  return try parseAtom(data: data, baseURL: baseURL)
        case .none: throw OPDSParseError.unrecognizedFormat
        }
    }

    private enum WireFormat { case xml, json }

    private static func format(mimeType: String?, data: Data) -> WireFormat? {
        if let mimeType = mimeType?.lowercased() {
            if mimeType.contains("json") { return .json }
            if mimeType.contains("xml") || mimeType.contains("atom") { return .xml }
        }
        // Sniff: skip leading whitespace/BOM and look at the first meaningful byte.
        for byte in data.prefix(512) {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF: continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):      return .json
            case UInt8(ascii: "<"):                         return .xml
            default:                                        return nil
            }
        }
        return nil
    }

    // MARK: - OPDS 1.2 (Atom XML)

    static func parseAtom(data: Data, baseURL: URL) throws -> CatalogFeed {
        let delegate = AtomFeedDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false   // we match on qualified names ourselves
        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "malformed XML"
            throw OPDSParseError.malformedXML(message)
        }
        guard delegate.sawFeedElement else { throw OPDSParseError.unrecognizedFormat }
        return delegate.feed
    }

    // MARK: - OPDS 2.0 (JSON)

    static func parseJSON(data: Data, baseURL: URL) throws -> CatalogFeed {
        let doc: OPDS2Feed
        do {
            doc = try JSONDecoder().decode(OPDS2Feed.self, from: data)
        } catch {
            throw OPDSParseError.malformedJSON(error.localizedDescription)
        }
        return doc.catalogFeed(baseURL: baseURL)
    }

    // MARK: - OpenSearch

    /// Extract the OPDS-catalog `{searchTerms}` template from an OpenSearch
    /// description document. Prefers an Atom/OPDS-typed `<Url>` over any other.
    static func parseOpenSearchTemplate(data: Data) -> String? {
        let delegate = OpenSearchDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return delegate.bestTemplate
    }

    /// Substitute a query into an OpenSearch template, percent-encoding the term
    /// and clearing any other `{...}` placeholders the template declares.
    static func expand(searchTemplate template: String, query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .opdsQueryAllowed) ?? query
        var expanded = template
        for token in ["{searchTerms}", "{searchterms}", "{opds:searchTerms}"] {
            expanded = expanded.replacingOccurrences(of: token, with: encoded)
        }
        // Optional placeholders are written `{name?}`; required ones we don't know
        // how to fill get emptied too rather than shipped literally.
        expanded = expanded.replacingOccurrences(
            of: "\\{[^}]*\\}",
            with: "",
            options: .regularExpression
        )
        return URL(string: expanded)
    }
}

private extension CharacterSet {
    /// Query-safe set: `urlQueryAllowed` minus the sub-delimiters that would
    /// otherwise split the parameter we're building.
    static let opdsQueryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#/")
        return set
    }()
}

// MARK: - Atom parsing

/// Streaming `XMLParser` delegate for OPDS 1.2 feeds.
///
/// Namespace processing is off, so element names arrive qualified as the document
/// wrote them (`dc:language`, `dcterms:language`, `opds:price`). Matching strips
/// the prefix, which is what every real-world feed variation needs.
private final class AtomFeedDelegate: NSObject, XMLParserDelegate {
    private(set) var feed = CatalogFeed()
    private(set) var sawFeedElement = false

    private let baseURL: URL

    /// Entries are assembled here before being classified as navigation or
    /// publication at `</entry>`.
    private var currentEntry: PartialEntry?
    private var text = ""
    /// Depth inside an element whose text we don't want (e.g. XHTML content).
    private var elementStack: [String] = []
    /// Set while inside `<author>` so a nested `<name>` lands in the right place.
    private var inAuthor = false
    /// The `<link>` currently open, kept so a nested `<opds:price>` can attach.
    private var pendingLink: PartialLink?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    private struct PartialEntry {
        var id: String?
        var title: String?
        var summary: String?
        var publisher: String?
        var language: String?
        var updated: Date?
        var authors: [String] = []
        var subjects: [String] = []
        var acquisitions: [AcquisitionLink] = []
        var coverURL: URL?
        var thumbnailURL: URL?
        /// Atom-typed links — the marker of a navigation entry.
        var navigationURL: URL?
    }

    private struct PartialLink {
        var url: URL
        var rel: String
        var type: String
        var price: AcquisitionLink.Price?
        var priceCurrency: String?
        /// `<opds:indirectAcquisition type="...">`, used when the outer link is a
        /// fulfilment document wrapping the real format.
        var indirectType: String?
    }

    // MARK: Element lifecycle

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = CatalogText.localName(elementName)
        elementStack.append(name)
        text = ""

        switch name {
        case "feed":
            sawFeedElement = true
        case "entry":
            currentEntry = PartialEntry()
        case "author":
            inAuthor = true
        case "link":
            handleLinkStart(attributeDict)
        case "category":
            if currentEntry != nil {
                let term = attributeDict["label"] ?? attributeDict["term"]
                if let term, !term.isEmpty { currentEntry?.subjects.append(term) }
            }
        case "price":
            pendingLink?.priceCurrency = attributeDict["currencycode"] ?? attributeDict["currencyCode"]
        case "indirectacquisition":
            if pendingLink?.indirectType == nil { pendingLink?.indirectType = attributeDict["type"] }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = CatalogText.localName(elementName)
        defer {
            if !elementStack.isEmpty { elementStack.removeLast() }
            text = ""
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "link":
            finishLink()

        case "price":
            // A priced link is one MacGet must not fetch — record it so
            // `isDownloadable` returns false and the UI links out to the seller.
            if pendingLink != nil, let amount = Decimal(string: value) {
                let currency = pendingLink?.priceCurrency ?? "USD"
                pendingLink?.price = .init(amount: amount, currencyCode: currency)
            }

        case "entry":
            finishEntry()

        case "name":
            if inAuthor, currentEntry != nil, !value.isEmpty {
                currentEntry?.authors.append(value)
            }

        case "author":
            inAuthor = false

        case "title":
            if currentEntry != nil {
                if currentEntry?.title == nil { currentEntry?.title = value }
            } else if feed.title == nil, isDirectChildOfFeed {
                feed.title = value
            }

        case "id":
            if currentEntry != nil, currentEntry?.id == nil { currentEntry?.id = value }

        case "summary", "content":
            if currentEntry != nil, currentEntry?.summary?.isEmpty ?? true, !value.isEmpty {
                currentEntry?.summary = CatalogText.strippingHTML(value)
            }

        case "language":
            if currentEntry != nil, currentEntry?.language == nil, !value.isEmpty {
                currentEntry?.language = value
            }

        case "publisher":
            if currentEntry != nil, currentEntry?.publisher == nil, !value.isEmpty {
                currentEntry?.publisher = value
            }

        case "updated", "issued", "date":
            if currentEntry != nil, currentEntry?.updated == nil {
                currentEntry?.updated = CatalogText.parseDate(value)
            }

        default:
            break
        }
    }

    /// True when the element that just closed sits directly under `<feed>` — used
    /// to keep a feed-level `<title>` from being overwritten by a nested one.
    private var isDirectChildOfFeed: Bool {
        elementStack.count == 2 && elementStack.first == "feed"
    }

    // MARK: Links

    private func handleLinkStart(_ attributes: [String: String]) {
        guard let href = attributes["href"],
              let url = CatalogText.resolve(href, against: baseURL) else { return }
        let rel = attributes["rel"] ?? ""
        let type = attributes["type"] ?? ""

        if currentEntry != nil {
            pendingLink = PartialLink(url: url, rel: rel, type: type)
            return
        }

        // Feed-level links.
        switch rel {
        case "next":
            feed.nextPageURL = url
        case "search":
            if type.lowercased().contains("opensearchdescription") {
                feed.searchDescriptionURL = url
            } else if let template = attributes["template"] {
                feed.searchTemplate = template
            }
        default:
            if let template = attributes["template"], rel == "search" {
                feed.searchTemplate = template
            }
        }
    }

    private func finishLink() {
        guard let link = pendingLink else { return }
        pendingLink = nil
        guard currentEntry != nil else { return }

        switch link.rel {
        case "http://opds-spec.org/image", "http://opds-spec.org/cover":
            currentEntry?.coverURL = link.url
            return
        case "http://opds-spec.org/image/thumbnail", "http://opds-spec.org/thumbnail":
            currentEntry?.thumbnailURL = link.url
            return
        default:
            break
        }

        if link.rel.hasPrefix("http://opds-spec.org/acquisition") {
            // A link may declare an `<opds:indirectAcquisition>` — the format you
            // get *after* fulfilling it. When the outer type is a DRM license we
            // keep the outer type deliberately: `isDownloadable` must reject it,
            // because fetching an .acsm gets you a license token, not a book.
            currentEntry?.acquisitions.append(
                AcquisitionLink(
                    url: link.url,
                    mimeType: link.type,
                    relation: .init(rel: link.rel),
                    price: link.price
                )
            )
            return
        }

        // An Atom-typed link with no acquisition rel means this entry is a
        // pointer to another catalog, not a book.
        let lowered = link.type.lowercased()
        if lowered.contains("application/atom+xml") || lowered.contains("opds-catalog") {
            if currentEntry?.navigationURL == nil, link.rel != "self", link.rel != "alternate" {
                currentEntry?.navigationURL = link.url
            } else if currentEntry?.navigationURL == nil, link.rel.isEmpty {
                currentEntry?.navigationURL = link.url
            }
        }
    }

    // MARK: Entries

    private func finishEntry() {
        guard let entry = currentEntry else { return }
        currentEntry = nil

        let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return }

        if !entry.acquisitions.isEmpty {
            feed.entries.append(
                CatalogEntry(
                    id: entry.id ?? title,
                    title: title,
                    authors: entry.authors,
                    summary: entry.summary,
                    publisher: entry.publisher,
                    language: entry.language,
                    subjects: entry.subjects,
                    coverURL: entry.coverURL ?? entry.thumbnailURL,
                    thumbnailURL: entry.thumbnailURL ?? entry.coverURL,
                    updated: entry.updated,
                    acquisitions: entry.acquisitions
                )
            )
        } else if let navURL = entry.navigationURL {
            feed.navigation.append(
                CatalogNavigationLink(
                    id: entry.id ?? navURL.absoluteString,
                    title: title,
                    url: navURL,
                    subtitle: entry.summary
                )
            )
        }
        // Entries with neither acquisition nor navigation links are dropped —
        // nothing actionable to show.
    }

}

// MARK: - Shared text helpers

/// Small parsing utilities shared by the OPDS and archive.org catalog paths.
/// Both back the same `CatalogEntry`, so both need the same summary cleanup and
/// URL resolution.
enum CatalogText {

    /// Strip a namespace prefix and lowercase, so `dc:language`, `dcterms:language`
    /// and `language` all match the same case.
    static func localName(_ qualified: String) -> String {
        let bare = qualified.split(separator: ":").last.map(String.init) ?? qualified
        return bare.lowercased()
    }

    static func resolve(_ href: String, against base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil { return absolute }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        for formatter in isoFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return dateOnlyFormatter.date(from: value)
    }

    /// Summaries frequently arrive as HTML. Strip tags and collapse whitespace so
    /// the detail pane renders readable plain text.
    static func strippingHTML(_ value: String) -> String {
        let withoutTags = value.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return decoded
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - OpenSearch description parsing

private final class OpenSearchDelegate: NSObject, XMLParserDelegate {
    private var templates: [(type: String, template: String)] = []

    var bestTemplate: String? {
        // Prefer a template that yields an OPDS catalog over, say, an HTML page.
        if let atom = templates.first(where: { $0.type.lowercased().contains("atom") }) {
            return atom.template
        }
        if let json = templates.first(where: { $0.type.lowercased().contains("opds") }) {
            return json.template
        }
        return templates.first?.template
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard CatalogText.localName(elementName) == "url",
              let template = attributeDict["template"], !template.isEmpty else { return }
        templates.append((attributeDict["type"] ?? "", template))
    }
}

// MARK: - OPDS 2.0 JSON model

/// Wire model for OPDS 2.0. Kept private to the parser — callers only ever see
/// `CatalogFeed`.
private struct OPDS2Feed: Decodable {
    var metadata: Metadata?
    var links: [Link]?
    var navigation: [Link]?
    var publications: [Publication]?
    var groups: [Group]?

    struct Metadata: Decodable {
        var title: String?
    }

    struct Group: Decodable {
        var metadata: Metadata?
        var navigation: [Link]?
        var publications: [Publication]?
    }

    struct Link: Decodable {
        var href: String
        var type: String?
        var title: String?
        var rel: StringOrArray?
        var templated: Bool?
        var properties: Properties?

        struct Properties: Decodable {
            var price: Price?
            struct Price: Decodable {
                var currency: String?
                var value: Double?
            }
        }
    }

    struct Publication: Decodable {
        var metadata: PublicationMetadata?
        var links: [Link]?
        var images: [Link]?
    }

    struct PublicationMetadata: Decodable {
        var identifier: String?
        var title: String?
        var author: ContributorList?
        var publisher: ContributorList?
        var language: StringOrArray?
        var subject: ContributorList?
        var description: String?
        var modified: String?
    }

    // MARK: Conversion

    func catalogFeed(baseURL: URL) -> CatalogFeed {
        var feed = CatalogFeed()
        feed.title = metadata?.title

        var navLinks = navigation ?? []
        var pubs = publications ?? []
        for group in groups ?? [] {
            navLinks.append(contentsOf: group.navigation ?? [])
            pubs.append(contentsOf: group.publications ?? [])
        }

        feed.navigation = navLinks.compactMap { link in
            guard let url = CatalogText.resolve(link.href, against: baseURL) else { return nil }
            let title = link.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            return CatalogNavigationLink(id: link.href, title: title, url: url, subtitle: nil)
        }

        feed.entries = pubs.compactMap { $0.catalogEntry(baseURL: baseURL) }

        for link in links ?? [] {
            let rels = link.rel?.values ?? []
            if rels.contains("next"), let url = CatalogText.resolve(link.href, against: baseURL) {
                feed.nextPageURL = url
            }
            if rels.contains("search") {
                if link.templated == true || link.href.contains("{searchTerms}") {
                    feed.searchTemplate = link.href
                } else if link.type?.lowercased().contains("opensearchdescription") == true,
                          let url = CatalogText.resolve(link.href, against: baseURL) {
                    feed.searchDescriptionURL = url
                }
            }
        }
        return feed
    }
}

private extension OPDS2Feed.Publication {
    func catalogEntry(baseURL: URL) -> CatalogEntry? {
        let title = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }

        let acquisitions: [AcquisitionLink] = (links ?? []).compactMap { link in
            let rels = link.rel?.values ?? []
            // OPDS 2 publications often omit the rel on the acquisition link and
            // rely on it being in `links` at all; treat a bare link with a known
            // media type as a generic acquisition.
            let acquisitionRel = rels.first { $0.hasPrefix("http://opds-spec.org/acquisition") }
            guard acquisitionRel != nil || (link.type.flatMap { BookFormat(mimeType: $0)?.isSupported } == true) else {
                return nil
            }
            guard let url = CatalogText.resolve(link.href, against: baseURL) else { return nil }
            var price: AcquisitionLink.Price?
            if let p = link.properties?.price, let value = p.value {
                price = .init(amount: Decimal(value), currencyCode: p.currency ?? "USD")
            }
            return AcquisitionLink(
                url: url,
                mimeType: link.type ?? "",
                relation: .init(rel: acquisitionRel ?? ""),
                price: price
            )
        }
        guard !acquisitions.isEmpty else { return nil }

        let imageLinks = images ?? []
        let cover = imageLinks.first.flatMap { CatalogText.resolve($0.href, against: baseURL) }
        let thumbnail = imageLinks.last.flatMap { CatalogText.resolve($0.href, against: baseURL) }

        return CatalogEntry(
            id: metadata?.identifier ?? title,
            title: title,
            authors: metadata?.author?.values ?? [],
            summary: metadata?.description.map(CatalogText.strippingHTML),
            publisher: metadata?.publisher?.values.first,
            language: metadata?.language?.values.first,
            subjects: metadata?.subject?.values ?? [],
            coverURL: cover ?? thumbnail,
            thumbnailURL: thumbnail ?? cover,
            updated: metadata?.modified.flatMap(CatalogText.parseDate),
            acquisitions: acquisitions
        )
    }
}

// MARK: - Flexible JSON shapes

/// OPDS 2 fields like `rel` and `language` are "string or array of string".
private struct StringOrArray: Decodable {
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

/// `author`/`publisher`/`subject` may each be a string, an object with a `name`,
/// or an array mixing both.
private struct ContributorList: Decodable {
    let values: [String]

    private struct Named: Decodable {
        var name: String?
        var sortAs: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            values = [single]
        } else if let many = try? container.decode([String].self) {
            values = many
        } else if let one = try? container.decode(Named.self) {
            values = [one.name].compactMap { $0 }
        } else if let objects = try? container.decode([Named].self) {
            values = objects.compactMap(\.name)
        } else {
            values = []
        }
    }
}
