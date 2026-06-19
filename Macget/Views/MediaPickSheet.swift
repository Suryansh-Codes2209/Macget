import SwiftUI

/// Quality picker shown when a video is sent from the browser extension. Probes
/// the page for available resolutions, then lets the user choose one to download.
struct MediaPickSheet: View {
    @Bindable var model: MediaPickModel
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 400)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Download video")
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

        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 120)
        }
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

    private var isReady: Bool {
        if case .ready = model.session?.state { return selection != nil }
        return false
    }
}
