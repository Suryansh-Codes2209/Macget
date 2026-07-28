import SwiftUI

/// One download rendered as a card.
///
/// Replaces the `Table` row that used to spread these facts across six columns.
/// The card shows the same information in two lines — identity on top, motion
/// below — which lets the progress bar be wide enough to actually read.
///
/// Deliberately *not* glass: Liquid Glass is for chrome (toolbar, status bar),
/// never for content. Cards use the warm surface tokens instead.
struct DownloadRowCard: View {
    let row: DownloadRowItem
    let isSelected: Bool
    /// Live thread-count changes. Nil-safe: terminal rows never show the stepper.
    let setThreads: (Int) -> Void

    @State private var isHovering = false
    @Environment(\.backgroundProminence) private var backgroundProminence

    /// True when this row sits inside the List's *emphasized* selection — the
    /// focused-window case where AppKit has already flipped the row's text to
    /// white. Everything the card draws has to invert with it: leaving the light
    /// `surfaceElevated` fill in place puts white text on cream and the row goes
    /// blank. An unfocused selection keeps dark text on a grey band, so it stays
    /// on the resting treatment.
    private var isEmphasized: Bool { backgroundProminence == .increased }

    private var primaryText: Color { isEmphasized ? .white : .primary }
    private var secondaryText: Color { isEmphasized ? .white.opacity(0.75) : .secondary }

    /// A status color, or white when it would otherwise sit on the accent band.
    private func statusText(_ color: Color) -> Color { isEmphasized ? .white : color }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 6) {
                titleLine
                detailLine
            }
        }
        .padding(.horizontal, Theme.Spacing.rowInset)
        .padding(.vertical, 10)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
        )
        // No shadow on the accent band — it reads as grime rather than lift.
        .shadow(color: .black.opacity(isEmphasized ? 0 : (isHovering ? 0.10 : 0.04)),
                radius: isHovering ? 6 : 2, y: isHovering ? 2 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityElement(children: .combine)
    }

    /// On the accent band the card becomes a translucent white panel so the
    /// selection reads through it and the card shape survives; at rest it's the
    /// opaque warm surface.
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(isEmphasized ? AnyShapeStyle(Color.white.opacity(0.16))
                               : AnyShapeStyle(Theme.Palette.surfaceElevated))
            .overlay {
                if isSelected && !isEmphasized {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.Palette.amber.opacity(0.10))
                }
            }
    }

    private var borderColor: Color {
        if isEmphasized { return .white.opacity(0.45) }
        return isSelected ? Theme.Palette.amber : Theme.Palette.stroke
    }

    // MARK: - Icon

    /// File-type symbol in a tinted tile, with the status badge in the corner.
    /// Same badge logic the table row used, moved to `Theme.statusBadge`.
    private var icon: some View {
        // The category tints are muted mid-tones tuned for the card fill; on the
        // accent band they turn to mud, so the tile goes monochrome there.
        let tint = Theme.color(for: FileTypeIcon.category(for: row.filename))
        let tileFill = isEmphasized ? Color.white.opacity(0.22) : tint.opacity(0.15)
        let glyph = isEmphasized ? Color.white : tint
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(tileFill)
            .frame(width: 34, height: 34)
            .overlay {
                Image(systemName: FileTypeIcon.symbolName(for: row.filename))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(glyph)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge = Theme.statusBadge(row.status) {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(badge.color, in: Circle())
                        .overlay(Circle().strokeBorder(
                            isEmphasized ? Color.white.opacity(0.9) : Theme.Palette.surfaceElevated,
                            lineWidth: 1.5))
                        .offset(x: 4, y: 4)
                }
            }
            .help(row.filename)
    }

    // MARK: - Line 1 — identity

    private var titleLine: some View {
        HStack(spacing: 8) {
            Text(row.filename)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.body.weight(.medium))
                .foregroundStyle(primaryText)

            if row.isTorrent {
                Text("TORRENT")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(statusText(Theme.Palette.seeding))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(isEmphasized ? Color.white.opacity(0.22)
                                             : Theme.Palette.seeding.opacity(0.15),
                                in: Capsule(style: .continuous))
            }

            Spacer(minLength: 8)

            Text(ByteFormatter.string(row.totalBytes))
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(secondaryText)

            threadsControl
        }
    }

    /// Live thread adjustment, revealed on hover so the resting card stays calm.
    /// Terminal rows have nothing to adjust, so they reserve no space for it.
    @ViewBuilder
    private var threadsControl: some View {
        if !row.status.isTerminal {
            HStack(spacing: 3) {
                Image(systemName: "square.stack.3d.up")
                    .font(.caption2)
                    .foregroundStyle(secondaryText)
                Text("\(row.threadCount)")
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(primaryText)
                    .frame(minWidth: 14, alignment: .trailing)
                Stepper("Threads", value: Binding(get: { row.threadCount }, set: setThreads),
                        in: 1...Download.maxThreadCount)
                    .labelsHidden()
                    .controlSize(.mini)
                    .disabled(!row.supportsRange)
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .help(row.supportsRange
                  ? "Adjust parallel chunks live (1–\(Download.maxThreadCount)). Splits the largest in-flight chunk."
                  : "Server doesn't support Range requests — extra threads won't help.")
        }
    }

    // MARK: - Line 2 — motion

    @ViewBuilder
    private var detailLine: some View {
        switch row.status {
        case .downloading:
            activeLine
        case .paused:
            HStack(spacing: 8) {
                ProgressTrack(value: row.fractionComplete)
                Text(percentString(row.fractionComplete))
                    .monospacedDigit().font(.caption)
                    .foregroundStyle(secondaryText)
                Text("Paused")
                    .font(.caption).foregroundStyle(statusText(Theme.Palette.paused))
            }
        case .completed:
            completedLine
        case .failed:
            Text(row.error ?? "Failed")
                .font(.caption)
                .foregroundStyle(statusText(Theme.Palette.error))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.error ?? "Failed")
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(secondaryText)
        case .queued:
            Text("Queued").font(.caption).foregroundStyle(secondaryText)
        }
    }

    /// Media downloads spend time in phases that move no bytes (setup, ffmpeg
    /// merge). When there's no usable fraction — or we're explicitly merging —
    /// show the indeterminate sweep with the phase label so the row never looks
    /// frozen. HTTP downloads have `phase == nil` and keep the determinate bar.
    @ViewBuilder
    private var activeLine: some View {
        let indeterminate = row.phase.map { $0 == .merging || row.fractionComplete == 0 } ?? false

        HStack(spacing: 8) {
            ProgressTrack(value: indeterminate ? nil : row.fractionComplete)

            if indeterminate, let phase = row.phase {
                Text(phase.label)
                    .font(.caption)
                    .foregroundStyle(secondaryText)
            } else {
                Text(percentString(row.fractionComplete))
                    .monospacedDigit().font(.caption)
                    .foregroundStyle(primaryText)
                    .frame(minWidth: 34, alignment: .trailing)
            }

            speedAndETA
        }
    }

    /// Torrents move bytes both ways; showing only the download rate hides half
    /// of what's going on.
    @ViewBuilder
    private var speedAndETA: some View {
        if row.isTorrent, row.uploadSpeedBytesPerSec > 0 {
            HStack(spacing: 6) {
                Label(ByteFormatter.speedString(row.speedBytesPerSec), systemImage: "arrow.down")
                    .foregroundStyle(statusText(Theme.Palette.amber))
                Label(ByteFormatter.speedString(row.uploadSpeedBytesPerSec), systemImage: "arrow.up")
                    .foregroundStyle(statusText(Theme.Palette.seeding))
            }
            .font(.caption)
            .monospacedDigit()
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
        } else {
            HStack(spacing: 4) {
                Text(ByteFormatter.speedString(row.speedBytesPerSec))
                    .foregroundStyle(statusText(Theme.Palette.amber))
                if let eta = row.etaSeconds, eta > 0 {
                    Text("·").foregroundStyle(secondaryText.opacity(0.6))
                    Text(ByteFormatter.etaString(eta))
                        .foregroundStyle(secondaryText)
                }
            }
            .font(.caption)
            .monospacedDigit()
        }
    }

    /// A finished torrent keeps uploading until it hits the seed limit, so
    /// "Completed" alone would look like nothing is happening.
    @ViewBuilder
    private var completedLine: some View {
        if row.isTorrent, row.isSeeding, row.uploadSpeedBytesPerSec > 0 {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(statusText(Theme.Palette.seeding))
                Text("Seeding")
                    .foregroundStyle(primaryText)
                if let ratio = row.ratio {
                    Text(String(format: "· %.2f", ratio))
                        .monospacedDigit()
                        .foregroundStyle(secondaryText)
                }
                Text("· " + ByteFormatter.speedString(row.uploadSpeedBytesPerSec))
                    .monospacedDigit()
                    .foregroundStyle(secondaryText)
            }
            .font(.caption)
            .help("Uploading to peers until the seed ratio or time limit in Settings is reached")
        } else {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(statusText(Theme.Palette.success))
                Text("Completed")
                    .foregroundStyle(statusText(Theme.Palette.success))
            }
            .font(.caption)
        }
    }

    private func percentString(_ frac: Double) -> String {
        String(format: "%.0f%%", frac * 100)
    }
}
