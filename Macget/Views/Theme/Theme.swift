import SwiftUI

/// The app's design tokens in one place.
///
/// Every semantic color resolves through `Assets.xcassets`, so light/dark (and
/// the system's Increase Contrast variants) are handled by the asset catalog
/// rather than by branching in views. Nothing here holds state — it's a
/// namespace, not a type you instantiate.
///
/// The palette is warm amber/honey over warm-neutral surfaces, and it is now the
/// whole brand: the app icon, the wordmark, the marketing site, the docs, and the
/// browser extension all derive from these same values. The site has no light
/// mode, so it uses the *dark* variant of each token below.
///
/// This file is the source of truth. When a color changes here, it also has to
/// change in `frontend/app/globals.css`, `site/index.html`, and the branding SVGs
/// under `Resources/Branding/` — run `scripts/render-icons.sh` after the latter.
enum Theme {

    // MARK: - Palette

    enum Palette {
        /// Primary accent. Also the app-wide `AccentColor`, so most stock
        /// controls pick it up without an explicit `.tint()`.
        static let amber = Color("BrandAmber")
        /// Lighter partner to `amber`; the far end of `progressGradient`.
        static let honey = Color("BrandHoney")

        /// Window and list background.
        static let surface = Color("SurfaceWarm")
        /// Row-card fill, one step above `surface`.
        static let surfaceElevated = Color("SurfaceWarmElevated")
        /// Hairline borders and inactive progress track.
        static let stroke = Color("SurfaceWarmStroke")

        /// Body text on warm surfaces, and on `amber` fills.
        ///
        /// Deliberately *not* `.primary`/`.secondary`: AppKit auto-inverts the
        /// semantic foreground colors to white on a selected table row, which
        /// blanked list rows whose card fill stayed light. These are explicit,
        /// so nothing the selection does can repaint them.
        ///
        /// Amber is a light color in *both* appearances — `#E8963C` light,
        /// `#F0A64E` dark — so white-on-amber is 2.37:1 either way and there is
        /// no mode in which it's readable. `textPrimary` on amber is 8.8:1,
        /// which is why the light variant here is the one used on accent fills
        /// (count pills, prominent buttons) regardless of appearance.
        static let textPrimary = Color("TextPrimary")
        static let textSecondary = Color("TextSecondary")
        /// Fixed dark ink for text sitting on an `amber`/`honey` fill. Doesn't
        /// flip with appearance, because the fill it sits on doesn't either.
        static let onAccent = Color(.sRGB, red: 0x2B / 255, green: 0x1F / 255, blue: 0x12 / 255)

        static let success = Color("StatusSuccess")
        static let error = Color("StatusError")
        static let paused = Color("StatusPaused")
        /// The one deliberately cool token: a seeding torrent is moving bytes
        /// *out*, and reusing a warm color would blur it into the download states.
        static let seeding = Color("StatusSeeding")
    }

    /// Fill for progress bars and other "in motion" surfaces.
    static let progressGradient = LinearGradient(
        colors: [Palette.amber, Palette.honey],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: - Metrics

    enum Radius {
        static let card: CGFloat = 10
        static let control: CGFloat = 6
        static let pill: CGFloat = 999
    }

    enum Spacing {
        static let rowInset: CGFloat = 12
        static let cardGap: CGFloat = 6
        static let sectionGap: CGFloat = 16
    }

    // MARK: - File-type tints

    /// Tint for a file-type icon.
    ///
    /// These stay spread across the hue wheel — collapsing them all into the
    /// amber family would harmonize beautifully and destroy the only thing the
    /// color is there for, which is telling a video from an archive at a glance.
    /// What changed from the old set is saturation: these are muted mid-tones
    /// with a warm bias, chosen to read on both the light and dark card fills
    /// rather than the stock neon `.pink`/`.teal`/`.indigo`.
    static func color(for category: FileTypeIcon.Category) -> Color {
        switch category {
        case .video:    return Color(.sRGB, red: 0.77, green: 0.40, blue: 0.29) // terracotta
        case .audio:    return Color(.sRGB, red: 0.61, green: 0.42, blue: 0.62) // muted mauve
        case .image:    return Color(.sRGB, red: 0.31, green: 0.60, blue: 0.56) // muted teal
        case .archive:  return Color(.sRGB, red: 0.63, green: 0.44, blue: 0.29) // clay
        case .pdf:      return Color(.sRGB, red: 0.75, green: 0.27, blue: 0.23) // deep rust
        case .document: return Color(.sRGB, red: 0.31, green: 0.48, blue: 0.65) // slate blue
        case .code:     return Color(.sRGB, red: 0.42, green: 0.56, blue: 0.37) // olive
        case .app:      return Color(.sRGB, red: 0.48, green: 0.42, blue: 0.66) // muted indigo
        case .disk:     return Color(.sRGB, red: 0.54, green: 0.50, blue: 0.46) // warm grey
        case .generic:  return .secondary
        }
    }

    // MARK: - Status

    /// Corner badge for terminal/paused states. Active states (downloading,
    /// queued) return nil — their progress is shown by the row's progress track.
    static func statusBadge(_ status: DownloadStatus) -> (symbol: String, color: Color)? {
        switch status {
        case .completed: return ("checkmark", Palette.success)
        case .failed:    return ("exclamationmark", Palette.error)
        case .paused:    return ("pause.fill", Palette.paused)
        case .cancelled: return ("xmark", .secondary)
        case .downloading, .queued: return nil
        }
    }
}
