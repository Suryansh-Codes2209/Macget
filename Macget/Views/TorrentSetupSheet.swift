import SwiftUI
import AppKit

/// One-time confirmation shown before MacGet's first torrent.
///
/// This is deliberately explicit about uploading. A download manager that
/// quietly starts serving data on the user's connection would be a surprise, and
/// the listening port is a real change to their machine's network posture.
struct TorrentSetupSheet: View {
    @Bindable var model: TorrentSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 460)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Turn on torrent support")
                    .font(.headline)
                Text("BitTorrent downloads and uploads at the same time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .acknowledge:
            VStack(alignment: .leading, spacing: 10) {
                bullet(
                    "arrow.up.circle",
                    "You'll upload too.",
                    "BitTorrent shares pieces with other peers while you download, and keeps seeding afterwards. You can cap the upload rate and how long it seeds in Settings › Torrents."
                )
                bullet(
                    "network",
                    "A listening port opens.",
                    "MacGet listens on port 6881 by default so peers can reach you. Your IP address is visible to others in the same swarm — that's how BitTorrent works."
                )
                bullet(
                    "checkmark.shield",
                    "You're responsible for what you transfer.",
                    "MacGet doesn't index or search for torrents. Only download material you have the right to."
                )
                if !TorrentToolInstaller.isInstalled {
                    bullet(
                        "shippingbox",
                        "aria2 will be installed.",
                        "MacGet uses aria2 as its torrent engine and installs it with Homebrew. It isn't bundled, because it needs several system libraries."
                    )
                }
            }

        case .installing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installing aria2…")
                    Text("This runs `brew install aria2` and can take a minute.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 90)

        case .failed(let message, let command):
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't install aria2", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.medium))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command {
                    HStack(spacing: 8) {
                        Text(command)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    }
                    Text("Run that in Terminal, then choose Try Again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func bullet(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
            switch model.phase {
            case .acknowledge:
                Button(model.alreadyAcknowledged ? "Install aria2" : "Enable Torrents") {
                    model.confirm()
                }
                .keyboardShortcut(.defaultAction)
            case .installing:
                Button("Enable Torrents") {}.disabled(true)
            case .failed:
                Button("Try Again") { model.retry() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
