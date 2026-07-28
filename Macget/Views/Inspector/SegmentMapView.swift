import SwiftUI

/// The file drawn as its work-stealing pieces, in file order.
///
/// This is the answer to "is it actually downloading in parts?" — MacGet slices
/// a ranged download into up to `ChunkPlanner.maxPieces` pieces and lets finished
/// workers steal the next outstanding one, but until now none of that was
/// visible: one bar creeping right looks identical to a single-connection
/// download. Here each piece is a cell, cells fill left to right, and the ones a
/// worker currently holds pulse — so the parallelism and the work-stealing are
/// both legible.
///
/// Drawn in a `Canvas` rather than as a grid of views: 256 cells with animated
/// borders is a lot of view identity for something that redraws several times a
/// second, and the layout is a plain grid the canvas can compute directly.
struct SegmentMapView: View {
    let segments: [SegmentInfo]
    /// True while a coordinator is running — gates the pulse animation.
    let isLive: Bool

    /// Target cell edge. The real size shrinks to whatever fits the band, never
    /// below `minCell`, so 8 pieces and 256 pieces both read.
    private let preferredCell: CGFloat = 13
    private let minCell: CGFloat = 4
    private let gap: CGFloat = 2
    /// Fixed band height. The grid is sized to fit inside it and centered, which
    /// keeps the panel's layout stable as the piece count changes between
    /// downloads — an inspector that reflows every time you click a row is worse
    /// than one that leaves a little air around a short grid.
    private let bandHeight: CGFloat = 88

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if isLive {
                    // 20 Hz is plenty for a pulse and a progress fill; the
                    // display-linked default would redraw hundreds of cells for
                    // motion nobody can see.
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                        canvas(now: context.date)
                    }
                } else {
                    canvas(now: Date())
                }
            }
            .frame(height: bandHeight)

            legend
        }
    }

    // MARK: - Layout

    private struct Layout {
        let columns: Int
        let cell: CGFloat
        /// Vertical inset that centers the grid in the band.
        let topInset: CGFloat
    }

    /// Largest cell size (down to `minCell`) that fits every piece inside the
    /// band at the width the canvas actually got.
    ///
    /// Derived from the real canvas size rather than an estimate, so the grid can
    /// never disagree with the frame it's drawn into and spill out the bottom.
    private func layout(for size: CGSize) -> Layout {
        let count = max(1, segments.count)
        var cell = preferredCell
        while cell > minCell {
            let columns = max(1, Int((size.width + gap) / (cell + gap)))
            let rows = Int(ceil(Double(count) / Double(columns)))
            if CGFloat(rows) * (cell + gap) - gap <= size.height {
                return Layout(columns: columns,
                              cell: cell,
                              topInset: max(0, (size.height - (CGFloat(rows) * (cell + gap) - gap)) / 2))
            }
            cell -= 1
        }
        let columns = max(1, Int((size.width + gap) / (minCell + gap)))
        return Layout(columns: columns, cell: minCell, topInset: 0)
    }

    // MARK: - Drawing

    private func canvas(now: Date) -> some View {
        Canvas { context, size in
            let layout = layout(for: size)
            // One shared phase so active cells breathe together instead of
            // shimmering independently, which reads as noise.
            let pulse = isLive
                ? 0.55 + 0.45 * (0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 3.0))
                : 1.0

            for (index, segment) in segments.enumerated() {
                let row = index / layout.columns
                let column = index % layout.columns
                let origin = CGPoint(
                    x: CGFloat(column) * (layout.cell + gap),
                    y: layout.topInset + CGFloat(row) * (layout.cell + gap)
                )
                guard origin.y + layout.cell <= size.height + 0.5 else { break }
                draw(segment, at: origin, cell: layout.cell, pulse: pulse, in: &context)
            }
        }
    }

    private func draw(
        _ segment: SegmentInfo,
        at origin: CGPoint,
        cell: CGFloat,
        pulse: Double,
        in context: inout GraphicsContext
    ) {
        let radius = max(1, cell * 0.22)
        let rect = CGRect(origin: origin, size: CGSize(width: cell, height: cell))
        let shape = Path(roundedRect: rect, cornerRadius: radius)

        // Pending ground, always drawn — the partial fill sits on top of it.
        context.fill(shape, with: .color(Theme.Palette.stroke.opacity(0.7)))

        let fraction = segment.fractionComplete
        if fraction > 0 {
            let filled = CGRect(origin: origin,
                                size: CGSize(width: cell * CGFloat(fraction), height: cell))
            context.drawLayer { layer in
                layer.clip(to: shape)
                layer.fill(Path(filled), with: .linearGradient(
                    Gradient(colors: [Theme.Palette.amber, Theme.Palette.honey]),
                    startPoint: origin,
                    endPoint: CGPoint(x: origin.x + cell, y: origin.y + cell)
                ))
            }
        }

        if segment.isActive {
            context.stroke(shape,
                           with: .color(Theme.Palette.honey.opacity(pulse)),
                           lineWidth: 1.5)
        } else if segment.attempts > 1 && !segment.isComplete {
            // A piece that has been retried is worth seeing before it turns into
            // a failed download.
            context.stroke(shape, with: .color(Theme.Palette.error.opacity(0.7)), lineWidth: 1)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem(color: Theme.Palette.amber, "\(completed) done")
            if inFlight > 0 {
                legendItem(color: Theme.Palette.honey, "\(inFlight) in flight")
            }
            legendItem(color: Theme.Palette.stroke, "\(pending) pending")
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private func legendItem(color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
        }
    }

    private var completed: Int { segments.filter(\.isComplete).count }
    private var inFlight: Int { segments.filter { $0.isActive && !$0.isComplete }.count }
    private var pending: Int { segments.count - completed - inFlight }
}
