import SwiftUI

/// Choose which files inside a multi-file torrent to download.
///
/// Only meaningful once aria2 has resolved metadata — for a magnet that's after
/// the handoff, which is why the sheet is reachable from the row's context menu
/// rather than shown up-front.
struct TorrentFilePickerSheet: View {
    let filename: String
    let files: [TorrentFileEntry]
    @Binding var isPresented: Bool
    /// Called with the indices to keep. Applying restarts the torrent so aria2
    /// picks up the new `--select-file`.
    let onApply: (Set<Int>) -> Void

    @State private var selected: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 520, height: 460)
        .onAppear {
            selected = Set(files.filter(\.selected).map(\.index))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Choose files")
                .font(.headline)
            Text(filename)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var list: some View {
        List {
            ForEach(files) { file in
                Toggle(isOn: binding(for: file)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // The full path matters in a torrent whose files share
                            // a leaf name across season/disc folders.
                            if file.path != file.displayName {
                                Text(file.path)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        Spacer()
                        Text(ByteFormatter.string(file.length))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("All") { selected = Set(files.map(\.index)) }
            Button("None") { selected = [] }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(selected.count) of \(files.count) selected")
                    .font(.caption)
                Text(ByteFormatter.string(selectedBytes))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                onApply(selected)
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
            // Selecting nothing would download nothing; make that a dead end
            // rather than a silently empty torrent.
            .disabled(selected.isEmpty)
        }
    }

    private var selectedBytes: Int64 {
        files.filter { selected.contains($0.index) }.reduce(0) { $0 + $1.length }
    }

    private func binding(for file: TorrentFileEntry) -> Binding<Bool> {
        Binding(
            get: { selected.contains(file.index) },
            set: { isOn in
                if isOn { selected.insert(file.index) } else { selected.remove(file.index) }
            }
        )
    }
}
