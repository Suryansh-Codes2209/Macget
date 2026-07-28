import SwiftUI

/// Quality picker shown when a video is sent from the browser extension. Probes
/// the page for available resolutions, then lets the user choose one to download.
struct MediaPickSheet: View {
    @Bindable var model: MediaPickModel
    @State private var selection: String?
    /// Playlist state: which entries are checked, and the single quality to apply.
    @State private var checkedEntries: Set<String> = []
    @State private var playlistQuality: MediaPlaylistQuality = .best

    private var isPlaylist: Bool {
        if case .playlist = model.session?.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(18)
        .frame(width: isPlaylist ? 460 : 400)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isPlaylist ? "list.and.film" : "arrow.down.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(isPlaylist ? "Download playlist" : "Download video")
                    .font(.headline)
                if let title = model.session?.title, !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.session?.state {
        case .probing, .none:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finding available qualities…")
                    Text("First run may take a moment to set up a one-time helper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 120)

        case .ready(let options):
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        optionRow(option)
                        if option.id != options.last?.id { Divider() }
                    }
                }
            }
            .frame(height: 200)
            .onAppear { if selection == nil { selection = options.first?.id } }

        case .playlist(let entries):
            playlistContent(entries)

        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Palette.paused)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 120)
        }
    }

    @ViewBuilder
    private func playlistContent(_ entries: [PlaylistEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(checkedEntries.count == entries.count ? "Deselect All" : "Select All") {
                    checkedEntries = checkedEntries.count == entries.count
                        ? []
                        : Set(entries.map(\.id))
                }
                .buttonStyle(.link)
                Spacer()
                Text("\(checkedEntries.count) of \(entries.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        playlistRow(idx: idx, entry: entry)
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
            }
            .frame(height: 200)
            HStack {
                Text("Quality")
                Picker("Quality", selection: $playlistQuality) {
                    ForEach(MediaPlaylistQuality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                Spacer()
            }
        }
        .onAppear { if checkedEntries.isEmpty { checkedEntries = Set(entries.map(\.id)) } }
    }

    private func playlistRow(idx: Int, entry: PlaylistEntry) -> some View {
        Button {
            if checkedEntries.contains(entry.id) { checkedEntries.remove(entry.id) }
            else { checkedEntries.insert(entry.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: checkedEntries.contains(entry.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checkedEntries.contains(entry.id) ? Color.accentColor : .secondary)
                Text("\(idx + 1).")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(entry.title ?? entry.id)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func optionRow(_ option: MediaPickOption) -> some View {
        Button {
            selection = option.id
        } label: {
            HStack {
                Image(systemName: selection == option.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selection == option.id ? Color.accentColor : .secondary)
                Text(option.label)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
            if case .playlist(let entries) = model.session?.state {
                Button("Download \(checkedEntries.count)") {
                    let chosen = entries.filter { checkedEntries.contains($0.id) }
                    model.pickPlaylist(chosen, quality: playlistQuality)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checkedEntries.isEmpty)
            } else {
                Button("Download") {
                    if let id = selection,
                       case .ready(let options) = model.session?.state,
                       let option = options.first(where: { $0.id == id }) {
                        model.pick(option)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isReady)
            }
        }
    }

    private var isReady: Bool {
        if case .ready = model.session?.state { return selection != nil }
        return false
    }
}
