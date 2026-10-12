import SwiftUI

/// Stable colors per link kind, so "green" always means the phone.
enum LinkPalette {
    static func color(for kind: NetworkLink.Kind) -> Color {
        switch kind {
        case .wifi: return .blue
        case .tethered: return .green
        case .wiredEthernet: return .orange
        case .other: return .gray
        }
    }
}

enum LinkBreakdownText {
    /// "Wi-Fi 1.2 MB/s · iPhone USB 3.4 MB/s", prefixed "≈ " when apportioned.
    static func caption(_ links: [LinkStat]) -> String {
        let moving = links.filter { $0.speedBytesPerSec > 0 }
        let body = moving.map { "\($0.displayName) \(ByteFormatter.speedString($0.speedBytesPerSec))" }
            .joined(separator: " · ")
        return links.contains(where: \.isEstimate) ? "≈ " + body : body
    }

    static func accessibility(_ links: [LinkStat]) -> String {
        let total = links.reduce(0) { $0 + $1.speedBytesPerSec }
        return links.filter { $0.speedBytesPerSec > 0 }.map { link in
            let percent = total > 0 ? Int((link.speedBytesPerSec / total * 100).rounded()) : 0
            return "\(link.displayName), \(ByteFormatter.speedString(link.speedBytesPerSec)), \(percent) percent of current speed"
        }.joined(separator: "; ")
    }

    static func statusText(_ status: LinkStat.Status) -> String {
        switch status {
        case .active: return "Active"
        case .rejectedByServer: return "Not accepted by server"
        case .down: return "Link down"
        }
    }
}

/// A thin stacked bar of each link's share of current speed, with a caption.
struct LinkBreakdownView: View {
    let links: [LinkStat]
    var showsCaption = true

    private var moving: [LinkStat] { links.filter { $0.speedBytesPerSec > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                let total = max(moving.reduce(0) { $0 + $1.speedBytesPerSec }, 1)
                HStack(spacing: 1) {
                    ForEach(moving) { link in
                        Rectangle()
                            .fill(LinkPalette.color(for: link.kind))
                            .frame(width: max(2, geo.size.width * link.speedBytesPerSec / total))
                    }
                }
            }
            .frame(height: 3)
            .clipShape(Capsule())

            if showsCaption {
                Text(LinkBreakdownText.caption(links))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LinkBreakdownText.accessibility(links))
    }
}
