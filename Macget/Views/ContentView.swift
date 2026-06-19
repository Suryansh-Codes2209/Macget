import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var listVM: DownloadListViewModel
    let appEnvironment: AppEnvironment
    @Bindable var mediaPick: MediaPickModel

    @State private var showingAddSheet = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            DownloadListView(vm: listVM)
                .navigationTitle("Macget")
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Label("Add Download", systemImage: "plus")
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        .help("Add Download (⌘N)")

                        Button { listVM.pauseAll() } label: {
                            Label("Pause All", systemImage: "pause.fill")
                        }
                        .help("Pause All Active Downloads")

                        Button { listVM.resumeAll() } label: {
                            Label("Resume All", systemImage: "play.fill")
                        }
                        .help("Resume All Paused Downloads")

                        Button { listVM.clearCompleted() } label: {
                            Label("Clear Completed", systemImage: "checkmark.circle")
                        }
                        .help("Remove Completed Downloads From the List")
                    }
                }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddDownloadSheet(
                vm: AddDownloadViewModel(engine: appEnvironment.engine, settings: appEnvironment.settings),
                isPresented: $showingAddSheet
            )
        }
        .sheet(isPresented: Binding(
            get: { mediaPick.isPresented },
            set: { if !$0 { mediaPick.cancel() } }
        )) {
            MediaPickSheet(model: mediaPick)
        }
        .searchable(text: $listVM.searchText, prompt: "Search downloads")
        .onChange(of: listVM.searchText) { _, _ in listVM.filterRefreshed() }
        .onChange(of: listVM.selectedFilter) { _, _ in listVM.filterRefreshed() }
        .onReceive(NotificationCenter.default.publisher(for: .openAddDownload)) { _ in
            showingAddSheet = true
        }
        .onDrop(of: [.url, .text], isTargeted: nil) { providers in
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
                    if let url, let valid = URLValidation.parsePlausibleHTTPURL(url.absoluteString) {
                        Task { @MainActor in appEnvironment.enqueue(url: valid) }
                    }
                }
                enqueuedAny = true
            } else if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { str, _ in
                    if let s = str as? String, let valid = URLValidation.parsePlausibleHTTPURL(s) {
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
            HStack {
                Label(filter.displayName, systemImage: icon(for: filter))
                Spacer()
                Text("\(listVM.count(for: filter))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .tag(filter)
        }
        .navigationTitle("Filter")
        .listStyle(.sidebar)
        .frame(minWidth: 160)
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
