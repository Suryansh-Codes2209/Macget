import SwiftUI

/// A category rendered as a collapsible folder.
///
/// Replaces the flat, non-interactive section heading the list used to draw.
/// The tile geometry (34pt, 8pt radius) is deliberately identical to
/// `DownloadRowCard.icon` so a folder's glyph and its children's glyphs sit on
/// the same vertical line — the indent on the cards is what makes the hierarchy
/// legible, and it only works if the two agree.
///
/// Not selectable: the list's selection stays a `Set<UUID>` of downloads, so a
/// click here toggles the folder without disturbing what's selected. The caller
/// applies `.selectionDisabled(true)`; this view just doesn't participate.
struct CategoryFolderRow: View {
    let category: DownloadCategory
    let itemCount: Int
    let totalBytes: Int64
    let isExpanded: Bool
    let toggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)

            tile

            Text(category.displayName)
                .font(.headline)
                .foregroundStyle(Theme.Palette.textPrimary)

            Spacer(minLength: 8)

            Text(summary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.rowInset)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Palette.amber.opacity(isHovering ? 0.10 : 0.05))
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: toggle)
        .animation(.easeOut(duration: 0.15), value: isExpanded)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.displayName), \(summary)")
        .accessibilityHint(isExpanded ? "Collapse folder" : "Expand folder")
        .accessibilityAddTraits(.isButton)
    }

    /// An open folder when expanded, so the row reads as a folder even with the
    /// chevron out of the corner of your eye.
    private var tile: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.Palette.amber.opacity(0.15))
            .frame(width: 34, height: 34)
            .overlay {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Palette.amber)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: category.symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Palette.onAccent)
                    .frame(width: 15, height: 15)
                    .background(Theme.Palette.amber, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.Palette.surface, lineWidth: 1.5))
                    .offset(x: 4, y: 4)
            }
    }

    private var summary: String {
        let items = itemCount == 1 ? "1 item" : "\(itemCount) items"
        return "\(items) · \(ByteFormatter.string(totalBytes))"
    }
}
