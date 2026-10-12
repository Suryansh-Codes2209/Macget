import SwiftUI

/// The main window's "Connections" toolbar item: the always-visible link strip,
/// opening a popover to switch combining on or off per link.
///
/// Writes go through the app's single `SettingsViewModel`, the same instance the
/// Settings window edits, so neither copy can go stale and overwrite the other.
struct ConnectionsToolbarButton: View {
    let connections: ConnectionsModel
    let listVM: DownloadListViewModel
    let settingsVM: SettingsViewModel

    @State private var showingPopover = false

    private var combining: Bool { settingsVM.settings.bonding.enabled }

    private var chips: [ConnectionChip] {
        ConnectionsSummary.chips(links: connections.links,
                                 totals: listVM.linkTotals,
                                 totalSpeed: listVM.totalSpeed,
                                 bonding: settingsVM.settings.bonding)
    }

    var body: some View {
        let chips = chips
        Button {
            showingPopover.toggle()
        } label: {
            LinkStripView(chips: chips, totalSpeed: listVM.totalSpeed, combining: combining)
        }
        .help(combining
              ? "Combining connections — click to choose which networks to use"
              : "Connected networks — click to combine them for faster downloads")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ConnectionsSummary.accessibilityLabel(chips: chips, totalSpeed: listVM.totalSpeed, combining: combining))
        .accessibilityHint("Shows connection options")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            ConnectionsPopover(chips: chips, settingsVM: settingsVM)
        }
    }
}

/// Combine switch, one switch per link, and the mobile-data caveat.
struct ConnectionsPopover: View {
    let chips: [ConnectionChip]
    let settingsVM: SettingsViewModel

    private var combining: Binding<Bool> {
        Binding(
            get: { settingsVM.settings.bonding.enabled },
            set: { newValue in
                settingsVM.edit { $0.bonding.enabled = newValue }
            }
        )
    }

    private func linkEnabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settingsVM.settings.bonding.isLinkEnabled(id) },
            set: { newValue in
                settingsVM.edit { $0.bonding.setLink(id, enabled: newValue) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: combining) {
                Text("Combine connections").font(.headline)
            }
            .toggleStyle(.switch)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(chips) { chip in
                    row(chip)
                }
            }
            // Per-link choices only matter while combining; they stay visible so
            // the user can see — and pre-set — what turning it on would use.
            .disabled(!combining.wrappedValue)

            Divider()

            Text("Uses every enabled connection at once for multi-connection downloads and torrents. Data from a tethered phone counts against your mobile plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func row(_ chip: ConnectionChip) -> some View {
        Toggle(isOn: linkEnabled(chip.id)) {
            HStack(spacing: 8) {
                Circle()
                    .fill(LinkPalette.color(for: chip.kind))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chip.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if chip.isDefaultRoute {
                        Text("Default route")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if chip.speedBytesPerSec > 0 {
                    SpeedText(bytesPerSec: chip.speedBytesPerSec, isEstimate: chip.isEstimate)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel(chip.isDefaultRoute ? "\(chip.displayName), default route" : chip.displayName)
    }
}
