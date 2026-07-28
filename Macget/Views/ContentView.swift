import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var listVM: DownloadListViewModel
    let appEnvironment: AppEnvironment
    @Bindable var mediaPick: MediaPickModel
    @Bindable var authPrompt: AuthPromptModel
    let inspector: InspectorModel

    @State private var showingAddSheet = false
    @State private var showingBookBrowser = false
    /// Lives here rather than in `DownloadListView` so the Sort menu can sit in
    /// the window toolbar alongside the other actions.
    @State private var sortMode: DownloadSortMode = .queue
    /// Hoisted out of the list for the same reason as `sortMode`, plus one more:
    /// the inspector shows whatever is selected, so the selection can't be
    /// private to the list any more.
    @State private var selection: Set<UUID> = []
    /// The activity panel opens with the window and stays open across launches.
    /// Persisted rather than hard-coded so hiding it remains possible on a small
    /// display — but the default is on, so it's there unless you close it.
    @AppStorage("showActivityInspector") private var showingInspector = true

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            DownloadListView(vm: listVM,
                             sortMode: $sortMode,
                             selection: $selection)
                .navigationTitle("Macget")
                .toolbar {
                    // Grouped rather than one undifferentiated run of five
                    // buttons: create, then bulk transport, then list hygiene.
                    ToolbarItemGroup {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Label("Add Download", systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut("n", modifiers: .command)
                        .help("Add Download (⌘N)")

                        Button {
                            showingBookBrowser = true
                        } label: {
                            Label("Browse Books", systemImage: "books.vertical")
                        }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                        .help("Browse Book Catalogs (⇧⌘B)")
                    }

                    ToolbarSpacer(.fixed)

                    ToolbarItemGroup {
                        Button { listVM.pauseAll() } label: {
                            Label("Pause All", systemImage: "pause.fill")
                        }
                        .help("Pause All Active Downloads")

                        Button { listVM.resumeAll() } label: {
                            Label("Resume All", systemImage: "play.fill")
                        }
                        .help("Resume All Paused Downloads")
                    }

                    ToolbarSpacer(.flexible)

                    ToolbarItemGroup {
                        // Where the table's column-header sorting went.
                        Menu {
                            Picker("Sort By", selection: $sortMode) {
                                ForEach(DownloadSortMode.allCases) { mode in
                                    Label(mode.displayName, systemImage: mode.symbol)
                                        .tag(mode)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                        // The list is always grouped into category folders, so
                        // the sort applies within each folder.
                        .help("Change Order Within Each Folder")

                        Button { listVM.clearCompleted() } label: {
                            Label("Clear Completed", systemImage: "checkmark.circle")
                        }
                        .help("Remove Completed Downloads From the List")

                        Button { showingInspector.toggle() } label: {
                            Label("Activity", systemImage: "chart.bar.xaxis.ascending")
                        }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help("Show Speed and Piece Activity (⌥⌘I)")
                    }
                }
                .inspector(isPresented: $showingInspector) {
                    DownloadInspectorView(model: inspector)
                }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddDownloadSheet(
                vm: AddDownloadViewModel(environment: appEnvironment, settings: appEnvironment.settings),
                isPresented: $showingAddSheet
            )
        }
        .sheet(isPresented: $showingBookBrowser) {
            BookBrowserView(
                model: appEnvironment.bookBrowser(),
                isPresented: $showingBookBrowser
            )
        }
        .sheet(isPresented: Binding(
            get: { mediaPick.isPresented },
            set: { if !$0 { mediaPick.cancel() } }
        )) {
            MediaPickSheet(model: mediaPick)
        }
        .sheet(isPresented: Binding(
            get: { authPrompt.isPresented },
            set: { if !$0 { authPrompt.cancel() } }
        )) {
            AuthPromptSheet(model: authPrompt)
        }
        .sheet(isPresented: Binding(
            get: { appEnvironment.torrentSetup.isPresented },
            set: { if !$0 { appEnvironment.torrentSetup.cancel() } }
        )) {
            TorrentSetupSheet(model: appEnvironment.torrentSetup)
        }
        .searchable(text: $listVM.searchText, prompt: "Search downloads")
        .onChange(of: listVM.searchText) { _, _ in listVM.filterRefreshed() }
        .onChange(of: listVM.selectedFilter) { _, _ in listVM.filterRefreshed() }
        // The panel polls the engine, so it only samples while it's on screen.
        .onChange(of: showingInspector, initial: true) { _, shown in
            inspector.isPresented = shown
        }
        // A multi-selection has no single subject; the panel falls back to the
        // aggregate view rather than picking one arbitrarily.
        .onChange(of: selection, initial: true) { _, ids in
            inspector.setTarget(ids.count == 1 ? ids.first : nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAddDownload)) { _ in
            showingAddSheet = true
        }
        .onDrop(of: [.fileURL, .url, .text], isTargeted: nil) { providers in
            handleDroppedProviders(providers)
        }
    }

    /// Handle URLs / text dropped onto the app window. Returns true if any
    /// provider yielded a valid http(s) URL we enqueued.
    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        var enqueuedAny = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    // A dropped .torrent file is a local file, not an http URL, so
                    // it has to be recognized before the http validation below.
                    if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                        Task { @MainActor in appEnvironment.addTorrent(torrentFile: url) }
                    } else if let valid = URLValidation.parsePlausibleHTTPURL(url.absoluteString) {
                        Task { @MainActor in appEnvironment.enqueue(url: valid) }
                    }
                }
                enqueuedAny = true
            } else if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { str, _ in
                    guard let s = str as? String else { return }
                    // Magnets arrive as plain text far more often than as URLs.
                    if let magnet = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
                       magnet.scheme?.lowercased() == "magnet" {
                        Task { @MainActor in appEnvironment.addTorrent(magnet: magnet) }
                    } else if let valid = URLValidation.parsePlausibleHTTPURL(s) {
                        Task { @MainActor in appEnvironment.enqueue(url: valid) }
                    }
                }
                enqueuedAny = true
            }
        }
        return enqueuedAny
    }

    @ViewBuilder
    private var sidebar: some View {
        List(StatusFilter.allCases, selection: $listVM.selectedFilter) { filter in
            let isSelected = listVM.selectedFilter == filter
            HStack(spacing: 8) {
                Image(systemName: icon(for: filter))
                    .foregroundStyle(isSelected ? Theme.Palette.amber : .secondary)
                    .frame(width: 18)
                Text(filter.displayName)
                Spacer(minLength: 6)
                countPill(listVM.count(for: filter), isSelected: isSelected)
            }
            .tag(filter)
        }
        .navigationTitle("Filter")
        .listStyle(.sidebar)
        .frame(minWidth: 170)
    }

    /// Count badge on a filter row. Reads as a quiet chip at rest and picks up
    /// the accent on the active filter.
    ///
    /// The active pill uses `onAccent`, not white: amber is a light color in both
    /// appearances (`#E8963C` / `#F0A64E`), so white on it is 2.37:1 — below the
    /// 4.5:1 floor — while the dark ink is 8.8:1.
    private func countPill(_ count: Int, isSelected: Bool) -> some View {
        Text("\(count)")
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(isSelected ? Theme.Palette.onAccent : Theme.Palette.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                isSelected ? AnyShapeStyle(Theme.Palette.amber)
                           : AnyShapeStyle(Theme.Palette.stroke),
                in: Capsule(style: .continuous)
            )
    }

    private func icon(for filter: StatusFilter) -> String {
        switch filter {
        case .all:       return "tray.full"
        case .active:    return "arrow.down.circle"
        case .paused:    return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed:    return "exclamationmark.triangle"
        }
    }
}
