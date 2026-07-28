import SwiftUI

/// Settings tab for BitTorrent: the master switch, seeding limits, and the
/// listening port.
struct TorrentSettingsView: View {
    @Bindable var vm: SettingsViewModel
    @Bindable var setup: TorrentSetupModel

    /// Recomputed when the view appears rather than stored, so installing aria2
    /// in another window is reflected without a relaunch.
    @State private var aria2Installed = TorrentToolInstaller.isInstalled

    var body: some View {
        Form {
            Section {
                Toggle("Enable torrent downloads", isOn: torrentsEnabledBinding)
                Text("BitTorrent uploads while it downloads and opens a listening port. MacGet doesn't search for or index torrents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Image(systemName: aria2Installed ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(aria2Installed ? Theme.Palette.success : Theme.Palette.paused)
                    Text(aria2Installed
                         ? "aria2 engine installed"
                         : "aria2 engine not installed — needed for torrents")
                        .font(.caption)
                    Spacer()
                    if !aria2Installed {
                        Button("Install…") {
                            setup.present(alreadyAcknowledged: vm.settings.torrentsEnabled) {
                                aria2Installed = TorrentToolInstaller.isInstalled
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Seeding") {
                // 0 disables the corresponding limit; aria2 stops at whichever
                // limit is reached first.
                HStack {
                    Text("Seed until ratio")
                    Spacer()
                    TextField("", value: $vm.settings.torrentSeedRatio, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("…or for at most")
                    Spacer()
                    TextField("", value: $vm.settings.torrentSeedMinutes, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("minutes").foregroundStyle(.secondary)
                }
                Text("Whichever comes first. Set either to 0 to skip that limit; set both to 0 to stop as soon as the download finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Upload limit")
                    Spacer()
                    TextField("Unlimited", value: uploadLimitKBBinding, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("KB/s").foregroundStyle(.secondary)
                }
            }
            .disabled(!vm.settings.torrentsEnabled)

            Section("Network") {
                HStack {
                    Text("Listening port")
                    Spacer()
                    TextField("", value: $vm.settings.torrentListenPort, format: .number.grouping(.never))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Enable DHT (find peers without a tracker)", isOn: $vm.settings.torrentDHTEnabled)
                Text("Port changes take effect the next time the torrent engine starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!vm.settings.torrentsEnabled)
        }
        .formStyle(.grouped)
        .onAppear { aria2Installed = TorrentToolInstaller.isInstalled }
    }

    /// Turning the switch on routes through the acknowledgement sheet rather than
    /// flipping the setting directly — the same gate the Add flow uses.
    private var torrentsEnabledBinding: Binding<Bool> {
        Binding(
            get: { vm.settings.torrentsEnabled },
            set: { newValue in
                guard newValue else {
                    vm.settings.torrentsEnabled = false
                    return
                }
                setup.present(alreadyAcknowledged: false) {
                    vm.settings.torrentsEnabled = true
                    aria2Installed = TorrentToolInstaller.isInstalled
                }
            }
        )
    }

    /// Settings store bytes/sec; users think in KB/s.
    private var uploadLimitKBBinding: Binding<Int?> {
        Binding(
            get: { vm.settings.torrentMaxUploadBytesPerSec.map { $0 / 1024 } },
            set: { vm.settings.torrentMaxUploadBytesPerSec = $0.map { $0 * 1024 } }
        )
    }
}
