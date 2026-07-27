import SwiftUI

/// Browse OPDS catalogs and send books to the download queue.
///
/// Layout is a three-part split: catalog picker + shelves on the left, a cover
/// grid in the middle, and the selected book's detail on the right.
struct BookBrowserView: View {
    @Bindable var model: BookBrowserModel
    @Binding var isPresented: Bool

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                shelfSidebar
                    .frame(minWidth: 190, idealWidth: 220, maxWidth: 320)
                mainContent
                    .frame(minWidth: 380)
                if let entry = model.selectedEntry {
                    BookDetailPane(entry: entry, model: model)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 560, idealHeight: 660)
        .onAppear { model.bootstrap() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly)
            .disabled(!model.canGoBack)
            .help("Back")

            Picker("Catalog", selection: $model.selectedSourceID) {
                ForEach(model.enabledSources) { source in
                    Text(source.name).tag(Optional(source.id))
                }
            }
            .labelsHidden()
            .frame(width: 190)
            .disabled(model.enabledSources.isEmpty)

            TextField("Search this catalog", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit { model.runSearch() }

            Button("Search") { model.runSearch() }
                .disabled(model.searchText.trimmingCharacters(in: .whitespaces).isEmpty)

            Spacer()

            Button {
                model.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("Reload")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Shelves

    @ViewBuilder
    private var shelfSidebar: some View {
        List {
            if !model.breadcrumbTitles.isEmpty {
                Section("Location") {
                    ForEach(Array(model.breadcrumbTitles.enumerated()), id: \.offset) { index, title in
                        Label(title, systemImage: index == 0 ? "books.vertical" : "folder")
                            .foregroundStyle(index == model.breadcrumbTitles.count - 1 ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            if !model.navigation.isEmpty {
                Section("Shelves") {
                    ForEach(model.navigation) { link in
                        Button {
                            model.open(link)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.title).lineLimit(1)
                                if let subtitle = link.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Grid

    @ViewBuilder
    private var mainContent: some View {
        switch model.state {
        case .idle:
            placeholder(
                icon: "books.vertical",
                title: "No catalogs enabled",
                message: "Turn on a catalog in Settings › Catalogs, or add your own OPDS feed."
            )

        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading catalog…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            placeholder(icon: "exclamationmark.triangle", title: "Couldn't load this catalog", message: message) {
                Button("Try Again") { model.reload() }
            }

        case .loaded:
            if model.entries.isEmpty {
                placeholder(
                    icon: model.navigation.isEmpty ? "magnifyingglass" : "folder",
                    title: model.navigation.isEmpty ? "No books here" : "Pick a shelf",
                    message: model.navigation.isEmpty
                        ? "This feed returned no results. Try a different search."
                        : "Choose a shelf on the left to see its books."
                )
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(model.entries) { entry in
                    BookGridCell(entry: entry, isSelected: entry.id == model.selectedEntryID)
                        .onTapGesture { model.selectedEntryID = entry.id }
                        .onAppear { model.loadMoreIfNeeded(currentItem: entry) }
                }
            }
            .padding(16)

            if model.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 16)
            }
        }
    }

    private func placeholder(icon: String, title: String, message: String) -> some View {
        placeholder(icon: icon, title: title, message: message) { EmptyView() }
    }

    private func placeholder<Action: View>(
        icon: String,
        title: String,
        message: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            action()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let status = model.statusMessage {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(status).font(.callout).lineLimit(1)
            } else if !model.entries.isEmpty {
                Text("\(model.entries.count) book\(model.entries.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Public-domain and openly-licensed catalogs")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Grid cell

private struct BookGridCell: View {
    let entry: CatalogEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
            Text(entry.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.authorLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
            if let url = entry.thumbnailURL ?? entry.coverURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholderGlyph
                    default:
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                placeholderGlyph
            }
        }
        .frame(height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var placeholderGlyph: some View {
        Image(systemName: "book.closed")
            .font(.system(size: 28))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Detail pane

private struct BookDetailPane: View {
    let entry: CatalogEntry
    @Bindable var model: BookBrowserModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(entry.title)
                    .font(.title3.weight(.semibold))
                Text(entry.authorLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let publisher = entry.publisher, !publisher.isEmpty {
                    detailRow("Publisher", publisher)
                }
                if let language = entry.language, !language.isEmpty {
                    detailRow("Language", language)
                }
                if !entry.subjects.isEmpty {
                    detailRow("Subjects", entry.subjects.prefix(6).joined(separator: ", "))
                }

                if let summary = entry.summary, !summary.isEmpty {
                    Divider()
                    Text(summary)
                        .font(.callout)
                        .textSelection(.enabled)
                }

                Divider()
                formats
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    @ViewBuilder
    private var formats: some View {
        if entry.downloadableAcquisitions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not available for download")
                    .font(.subheadline.weight(.medium))
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Download")
                    .font(.subheadline.weight(.medium))
                ForEach(sortedFormats, id: \.id) { link in
                    Button {
                        model.download(entry, link: link)
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                            Text(link.format?.displayName ?? link.mimeType)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var sortedFormats: [AcquisitionLink] {
        entry.downloadableAcquisitions.sorted { lhs, rhs in
            let left = lhs.format?.preferenceRank ?? 99
            let right = rhs.format?.preferenceRank ?? 99
            return left < right
        }
    }

    /// Explain *why* a book can't be downloaded — DRM and paywalls are very
    /// different situations for the reader.
    private var unavailableReason: String {
        if entry.acquisitions.contains(where: { $0.format == .drmProtected }) {
            return "This edition is DRM-protected. The link is a license file, not the book, so MacGet can't fetch it — you'll need a reader app that supports the publisher's DRM."
        }
        if let priced = entry.acquisitions.first(where: { $0.price != nil }) {
            return "This edition is for sale (\(priced.price?.display ?? "paid")). Open the catalog in your browser to buy it."
        }
        if entry.acquisitions.contains(where: { $0.relation == .borrow }) {
            return "This edition is loan-only. Borrowing happens on the library's site."
        }
        return "This entry doesn't offer a format MacGet can download."
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
