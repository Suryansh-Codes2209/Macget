import SwiftUI

/// One connected network as the toolbar shows it.
struct ConnectionChip: Equatable, Identifiable {
    let id: String
    let displayName: String
    let kind: NetworkLink.Kind
    let isDefaultRoute: Bool
    /// The user hasn't switched this link off for combining.
    let isEnabled: Bool
    /// 0 when the link is idle or its share of the traffic isn't known.
    let speedBytesPerSec: Double
    /// The speed is apportioned (torrents sharing the daemon), shown with "≈".
    var isEstimate = false
}

/// Pure decisions behind the toolbar's Connections item, kept out of the view
/// so they're testable.
enum ConnectionsSummary {
    /// Beyond this the item would crowd out the toolbar's buttons; the rest
    /// collapse into "+N" and are listed in the popover.
    static let maxVisibleChips = 3

    /// One chip per usable link, in the monitor's preference order.
    ///
    /// Speeds come from `totals` (the per-link aggregate, which is only populated
    /// while two or more links carry bytes). With no breakdown, all traffic is
    /// attributed to the default route — but only when fewer than two links are
    /// eligible for combining, because only then is every byte known to ride it.
    static func chips(links: [NetworkLink],
                      totals: [LinkStat],
                      totalSpeed: Double,
                      bonding: BondingSettings) -> [ConnectionChip] {
        let measured = Dictionary(totals.map { ($0.linkID, $0.speedBytesPerSec) }, uniquingKeysWith: +)
        let estimated = Set(totals.filter(\.isEstimate).map(\.linkID))
        let allOnDefault = totals.isEmpty && totalSpeed > 0
            && BondingPolicy.activeLinks(links, settings: bonding, excluded: []).count < 2
        return links.map { link in
            ConnectionChip(
                id: link.id,
                displayName: link.displayName,
                kind: link.kind,
                isDefaultRoute: link.isDefaultRoute,
                isEnabled: bonding.isLinkEnabled(link.id),
                speedBytesPerSec: measured[link.id] ?? (allOnDefault && link.isDefaultRoute ? totalSpeed : 0),
                isEstimate: estimated.contains(link.id)
            )
        }
    }

    /// The total adds information when several chips move — or when bytes are
    /// moving but no chip can say which link carries them (bonding on, but this
    /// download didn't split), so the toolbar never reads idle mid-download.
    static func showsTotal(_ chips: [ConnectionChip], totalSpeed: Double) -> Bool {
        let moving = chips.filter { $0.speedBytesPerSec > 0 }.count
        return moving >= 2 || (moving == 0 && totalSpeed > 0)
    }

    /// "1.2 MB/s", or "≈ 1.2 MB/s" when apportioned — as `LinkBreakdownText.caption`.
    static func speedText(_ chip: ConnectionChip) -> String {
        (chip.isEstimate ? "≈ " : "") + ByteFormatter.speedString(chip.speedBytesPerSec)
    }

    /// "Connections: Wi-Fi 1.0 MB/s, iPhone USB (not used). Combining on."
    static func accessibilityLabel(chips: [ConnectionChip], totalSpeed: Double, combining: Bool) -> String {
        let items = chips.map { chip -> String in
            var text = chip.displayName
            if chip.speedBytesPerSec > 0 { text += " " + speedText(chip) }
            if combining && !chip.isEnabled { text += " (not used)" }
            return text
        }
        var label = "Connections: \(items.joined(separator: ", ")). Combining \(combining ? "on" : "off")."
        if showsTotal(chips, totalSpeed: totalSpeed) {
            label += " Total \(ByteFormatter.speedString(totalSpeed))."
        }
        return label
    }
}

/// The toolbar's always-visible row of connected networks: a combining glyph,
/// then a dot, name and live speed per link, then the total when several move.
struct LinkStripView: View {
    let chips: [ConnectionChip]
    let totalSpeed: Double
    let combining: Bool

    private var visible: ArraySlice<ConnectionChip> { chips.prefix(ConnectionsSummary.maxVisibleChips) }
    private var overflow: Int { chips.count - visible.count }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(combining ? AnyShapeStyle(Theme.Palette.amber) : AnyShapeStyle(.secondary))
                .fontWeight(.medium)

            ForEach(visible) { chip in
                ChipLabel(chip: chip, dimmed: combining && !chip.isEnabled)
            }

            if overflow > 0 {
                Text("+\(overflow)")
                    .foregroundStyle(.secondary)
            }

            if ConnectionsSummary.showsTotal(chips, totalSpeed: totalSpeed) {
                Divider().frame(height: 12)
                HStack(spacing: 4) {
                    Text("Total").foregroundStyle(.secondary)
                    SpeedText(bytesPerSec: totalSpeed).fontWeight(.semibold)
                }
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 4)
        // Speeds tick every 250 ms; only the idle ↔ moving transitions change
        // the layout, and those should ease rather than snap.
        .animation(.snappy(duration: 0.2), value: chips.map { $0.speedBytesPerSec > 0 })
        .animation(.snappy(duration: 0.2), value: ConnectionsSummary.showsTotal(chips, totalSpeed: totalSpeed))
    }

    private struct ChipLabel: View {
        let chip: ConnectionChip
        let dimmed: Bool

        var body: some View {
            HStack(spacing: 5) {
                Circle()
                    .fill(LinkPalette.color(for: chip.kind))
                    .frame(width: 7, height: 7)
                Text(chip.displayName)
                    .truncationMode(.tail)
                    // "Thunderbolt Ethernet Slot 2" shouldn't push buttons off.
                    .frame(maxWidth: 120, alignment: .leading)
                if chip.speedBytesPerSec > 0 {
                    SpeedText(bytesPerSec: chip.speedBytesPerSec, isEstimate: chip.isEstimate)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .opacity(dimmed ? 0.45 : 1)
        }
    }
}

/// A speed in a fixed-width, digit-aligned slot, so neighbours don't shuffle
/// as the number changes.
struct SpeedText: View {
    let bytesPerSec: Double
    var isEstimate = false

    private var prefix: String { isEstimate ? "≈ " : "" }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Widest realistic reading; reserves the slot without being shown.
            Text(prefix + "888.8 MB/s").hidden()
            Text(prefix + ByteFormatter.speedString(bytesPerSec))
                .contentTransition(.numericText())
        }
        .monospacedDigit()
    }
}
