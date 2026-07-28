import SwiftUI

/// Live throughput as a scrolling area chart.
///
/// The scroll is the point. Sampling lands every 250 ms, and a chart that only
/// redraws on new data lurches four times a second — which reads as a stuttering
/// download even when throughput is flat. Instead a `TimelineView` advances a
/// sub-sample offset every frame and slides the whole curve left by exactly one
/// step per sample, so new data arrives at the right edge of a curve that was
/// already moving. That continuous drift is what makes an installer's speed
/// graph feel live rather than polled.
///
/// The timeline is dropped entirely when nothing is downloading: a frozen curve
/// has nothing to interpolate, and a display-linked redraw of an idle panel is
/// pure battery cost.
struct SpeedChartView: View {
    let series: SpeedSeries
    /// Drives the animated redraw and the leading dot. False when idle.
    let isLive: Bool
    var height: CGFloat = 96
    /// Shown under the current-speed numeral, e.g. the filename or "All active".
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chartBody
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.Palette.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.Palette.stroke, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        if isLive {
            TimelineView(.animation) { context in
                canvas(now: context.date)
            }
        } else {
            // Static render — the curve is whatever the last samples were.
            canvas(now: series.lastAppendedAt ?? Date())
        }
    }

    private func canvas(now: Date) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: &context, size: size, now: now)
        }
        .accessibilityLabel("Download speed graph")
        .accessibilityValue(ByteFormatter.speedString(series.current))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ByteFormatter.speedString(series.current))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.progressGradient)
                    .contentTransition(.numericText())
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                statLabel("PEAK", ByteFormatter.speedString(series.peak))
                statLabel("AVG", ByteFormatter.speedString(series.average))
            }
        }
    }

    private func statLabel(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        drawGridlines(in: &context, size: size)

        let values = series.smoothed
        guard values.count >= 2 else { return }

        let scale = series.chartScale()
        let step = size.width / CGFloat(series.capacity - 1)
        let shift = -interpolation(now: now) * step

        func point(_ i: Int) -> CGPoint {
            let x = size.width - CGFloat(values.count - 1 - i) * step + shift
            let normalized = min(1, max(0, values[i] / scale))
            return CGPoint(x: x, y: size.height - CGFloat(normalized) * (size.height - 4) - 2)
        }

        var line = Path()
        line.move(to: point(0))
        for i in 1..<values.count { line.addLine(to: point(i)) }

        var area = line
        area.addLine(to: CGPoint(x: point(values.count - 1).x, y: size.height))
        area.addLine(to: CGPoint(x: point(0).x, y: size.height))
        area.closeSubpath()

        context.fill(area, with: .linearGradient(
            Gradient(colors: [Theme.Palette.amber.opacity(0.42),
                              Theme.Palette.amber.opacity(0.02)]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: size.height)
        ))

        context.stroke(line, with: .linearGradient(
            Gradient(colors: [Theme.Palette.amber, Theme.Palette.honey]),
            startPoint: .zero,
            endPoint: CGPoint(x: size.width, y: 0)
        ), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

        if isLive {
            drawLeadingDot(at: point(values.count - 1), in: &context)
        }
    }

    /// Faint horizontal rules at thirds. Unlabeled on purpose — the numbers are
    /// in the header, and axis text at this size is noise.
    private func drawGridlines(in context: inout GraphicsContext, size: CGSize) {
        for fraction in [0.33, 0.66] {
            var rule = Path()
            let y = size.height * fraction
            rule.move(to: CGPoint(x: 0, y: y))
            rule.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(rule, with: .color(Theme.Palette.stroke.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        }
    }

    /// The bright head of the curve, with a bloom behind it.
    private func drawLeadingDot(at p: CGPoint, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 4))
            layer.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                       with: .color(Theme.Palette.honey.opacity(0.7)))
        }
        context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                     with: .color(Theme.Palette.honey))
    }

    /// Progress from the last sample toward the next, 0...1. Clamped so a paused
    /// or backgrounded panel doesn't slide the curve off screen after a gap.
    private func interpolation(now: Date) -> CGFloat {
        guard isLive, let last = series.lastAppendedAt else { return 0 }
        let interval = Double(InspectorModel.sampleInterval.components.seconds)
            + Double(InspectorModel.sampleInterval.components.attoseconds) / 1e18
        guard interval > 0 else { return 0 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(last) / interval)))
    }
}
