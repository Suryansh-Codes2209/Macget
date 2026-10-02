import SwiftUI
import Charts

/// Stacked throughput by network link: the height is total speed, each band is
/// one link's contribution.
struct LinkSpeedChartView: View {
    let series: [String: SpeedSeries]
    let links: [LinkStat]
    var height: CGFloat = 72

    private struct Point: Identifiable {
        let index: Int
        let linkID: String
        let name: String
        let value: Double
        var id: String { "\(linkID)-\(index)" }
    }

    private var points: [Point] {
        links.flatMap { link -> [Point] in
            (series[link.linkID]?.samples ?? []).enumerated().map {
                Point(index: $0.offset, linkID: link.linkID, name: link.displayName, value: $0.element)
            }
        }
    }

    var body: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Sample", point.index),
                y: .value("Speed", point.value),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Link", point.name))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(
            domain: links.map(\.displayName),
            range: links.map { LinkPalette.color(for: $0.kind) }
        )
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(ByteFormatter.speedString(v)) }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: height)
        .accessibilityLabel(LinkBreakdownText.accessibility(links))
    }
}
