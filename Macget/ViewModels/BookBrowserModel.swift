import Foundation
import Observation
import OSLog

/// Drives the book browser sheet: pick a catalog, browse its shelves or search
/// it, then send a chosen format to the download queue.
///
/// Navigation is a simple stack of feed URLs, so "Back" works the same whether
/// the user drilled through shelves or ran a search.
@MainActor
@Observable
final class BookBrowserModel {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    // MARK: Catalogs

    private(set) var sources: [CatalogSource] = []
    var selectedSourceID: UUID? {
        didSet {
            guard selectedSourceID != oldValue else { return }
            searchText = ""
            resetToRoot()
        }
    }

    var selectedSource: CatalogSource? {
        sources.first { $0.id == selectedSourceID }
    }

    /// Only enabled catalogs are offered in the picker.
    var enabledSources: [CatalogSource] { sources.filter(\.isEnabled) }

    // MARK: Current feed

    private(set) var state: LoadState = .idle
    private(set) var feedTitle: String?
    private(set) var navigation: [CatalogNavigationLink] = []
    /// Accumulated across pages — `rel="next"` appends rather than replaces.
    private(set) var entries: [CatalogEntry] = []
    private(set) var nextPageURL: URL?
    private(set) var isLoadingMore = false

    /// Feed URLs visited, deepest last. The first element is the catalog root.
    private var breadcrumbs: [(title: String, url: URL)] = []
    var canGoBack: Bool { breadcrumbs.count > 1 }
    var breadcrumbTitles: [String] { breadcrumbs.map(\.title) }

    var searchText = ""
    private(set) var isSearchResult = false

    var selectedEntryID: CatalogEntry.ID? {
        didSet {
            guard selectedEntryID != oldValue else { return }
            resolveAcquisitionsForSelection()
        }
    }
    var selectedEntry: CatalogEntry? {
        entries.first { $0.id == selectedEntryID }
    }
    /// True while an entry's real download links are being fetched (archive.org
    /// only — OPDS feeds carry them inline).
    private(set) var isResolvingSelection = false

    /// Transient confirmation shown after a book is queued.
    private(set) var statusMessage: String?

    // MARK: Dependencies

    private let service: CatalogService
    private let onDownload: (CatalogEntry, AcquisitionLink) -> Void
    private let log = Logger(subsystem: "com.macget", category: "BookBrowser")

    /// Generation counter so a slow in-flight response can't overwrite the feed
    /// after the user has already navigated somewhere else.
    private var loadGeneration = 0

    init(
        service: CatalogService = CatalogService(),
        sources: [CatalogSource] = CatalogStore.load(),
        onDownload: @escaping (CatalogEntry, AcquisitionLink) -> Void
    ) {
        self.service = service
        self.sources = sources
        self.onDownload = onDownload
        self.selectedSourceID = sources.first(where: \.isEnabled)?.id
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard case .idle = state else { return }
        resetToRoot()
    }

    /// Re-read the catalog list after the user edits it in Settings.
    func refreshSources() {
        sources = CatalogStore.load()
        if let id = selectedSourceID, sources.contains(where: { $0.id == id && $0.isEnabled }) { return }
        selectedSourceID = enabledSources.first?.id
    }

    // MARK: - Navigation

    private func resetToRoot() {
        guard let source = selectedSource else {
            breadcrumbs = []
            entries = []
            navigation = []
            state = .idle
            return
        }
        breadcrumbs = [(title: source.name, url: source.feedURL)]
        isSearchResult = false

        // The root is fetched through `rootFeed`, not `loadFeed` — archive.org has
        // no feed document at its base URL, so its shelves are synthesized.
        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        selectedEntryID = nil
        Task {
            do {
                let feed = try await service.rootFeed(for: source)
                guard generation == loadGeneration else { return }
                apply(feed, replacingResults: true)
            } catch {
                guard generation == loadGeneration else { return }
                fail(error)
            }
        }
    }

    func open(_ link: CatalogNavigationLink) {
        breadcrumbs.append((title: link.title, url: link.url))
        isSearchResult = false
        load(url: link.url, replacingResults: true)
    }

    func goBack() {
        guard canGoBack else { return }
        breadcrumbs.removeLast()
        guard let destination = breadcrumbs.last else { return }
        isSearchResult = false
        load(url: destination.url, replacingResults: true)
    }

    func reload() {
        guard let current = breadcrumbs.last else { return }
        load(url: current.url, replacingResults: true)
    }

    // MARK: - Searching

    func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = selectedSource else { return }
        guard !query.isEmpty else {
            resetToRoot()
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        selectedEntryID = nil

        Task {
            do {
                let feed = try await service.search(query: query, in: source)
                guard generation == loadGeneration else { return }
                breadcrumbs = [
                    (title: source.name, url: source.feedURL),
                    (title: "Results for \u{201C}\(query)\u{201D}", url: source.feedURL),
                ]
                isSearchResult = true
                apply(feed, replacingResults: true)
            } catch {
                guard generation == loadGeneration else { return }
                fail(error)
            }
        }
    }

    // MARK: - Loading

    private func load(url: URL, replacingResults: Bool) {
        guard let source = selectedSource else { return }
        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        if replacingResults { selectedEntryID = nil }

        Task {
            do {
                let feed = try await service.loadFeed(at: url, for: source)
                guard generation == loadGeneration else { return }
                apply(feed, replacingResults: replacingResults)
            } catch {
                guard generation == loadGeneration else { return }
                fail(error)
            }
        }
    }

    /// Fetch the next page and append. Called when the grid nears its end.
    func loadMoreIfNeeded(currentItem entry: CatalogEntry) {
        guard !isLoadingMore, let next = nextPageURL else { return }
        // Trigger when the user reaches the last handful of rows.
        guard let index = entries.firstIndex(where: { $0.id == entry.id }),
              index >= entries.count - 6 else { return }

        guard let source = selectedSource else { return }
        isLoadingMore = true
        let generation = loadGeneration
        Task {
            defer { isLoadingMore = false }
            do {
                let feed = try await service.loadFeed(at: next, for: source)
                guard generation == loadGeneration else { return }
                appendPage(feed)
            } catch {
                guard generation == loadGeneration else { return }
                // A failed *additional* page shouldn't blow away results already
                // on screen — just stop paginating.
                log.error("Failed to load next page: \(error.localizedDescription, privacy: .public)")
                nextPageURL = nil
            }
        }
    }

    private func apply(_ feed: CatalogFeed, replacingResults: Bool) {
        feedTitle = feed.title
        navigation = feed.navigation
        if replacingResults {
            entries = feed.entries
        } else {
            entries.append(contentsOf: feed.entries)
        }
        nextPageURL = feed.nextPageURL
        state = .loaded
    }

    private func appendPage(_ feed: CatalogFeed) {
        // Some catalogs repeat entries across page boundaries; de-dupe by id so
        // the grid doesn't show the same book twice.
        let known = Set(entries.map(\.id))
        entries.append(contentsOf: feed.entries.filter { !known.contains($0.id) })
        navigation.append(contentsOf: feed.navigation)
        nextPageURL = feed.nextPageURL
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        state = .failed(message)
        entries = []
        navigation = []
        nextPageURL = nil
        log.error("Catalog load failed: \(message, privacy: .public)")
    }

    // MARK: - Resolving download links

    /// archive.org search results carry only an identifier, so the real file list
    /// is fetched when the user selects a book. OPDS entries already have theirs
    /// and this returns immediately without a request.
    private func resolveAcquisitionsForSelection() {
        guard let source = selectedSource, source.kind == .archiveOrg else { return }
        guard let entryID = selectedEntryID,
              let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = entries[index]
        // Already resolved — a details-only entry has exactly one text/html link.
        guard entry.downloadableAcquisitions.isEmpty else { return }

        isResolvingSelection = true
        let generation = loadGeneration
        Task {
            defer { isResolvingSelection = false }
            do {
                let links = try await service.resolveAcquisitions(for: entry, in: source)
                guard generation == loadGeneration,
                      let current = entries.firstIndex(where: { $0.id == entryID }) else { return }
                entries[current].acquisitions = links
            } catch {
                log.error("Could not resolve files for \(entryID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Downloading

    /// The format offered by the one-click download button: the best-ranked
    /// downloadable format on the entry.
    func preferredLink(for entry: CatalogEntry) -> AcquisitionLink? {
        entry.downloadableAcquisitions.min { lhs, rhs in
            let left = lhs.format?.preferenceRank ?? 99
            let right = rhs.format?.preferenceRank ?? 99
            return left < right
        }
    }

    func download(_ entry: CatalogEntry, link: AcquisitionLink) {
        onDownload(entry, link)
        let format = link.format?.displayName ?? "file"
        show(status: "Added \u{201C}\(entry.title)\u{201D} (\(format)) to downloads.")
    }

    private func show(status message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if statusMessage == message { statusMessage = nil }
        }
    }
}

// MARK: - Filename

enum BookFilename {
    /// Build a readable destination filename for a catalog download:
    /// `Title - Author.epub`, sanitized and length-capped.
    ///
    /// Preferred over the server's own name because catalogs commonly serve
    /// `2701.epub` or `download?id=84`, which is useless in a Downloads folder.
    static func make(title: String, authors: [String], format: BookFormat?) -> String {
        var stem = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let author = authors.first?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            stem += " - \(author)"
        }
        let ext = format?.fileExtension ?? "bin"
        // `sanitize` substitutes "download" for an empty name, and
        // `truncatedToByteLimit` preserves the extension while trimming the stem.
        let full = "\(FilenameResolver.sanitize(stem)).\(ext)"
        return FilenameResolver.truncatedToByteLimit(full)
    }
}
