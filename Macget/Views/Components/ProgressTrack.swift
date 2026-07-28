import SwiftUI

/// A capsule progress bar filled with the app's amber→honey gradient.
///
/// Exists because `ProgressView(value:).progressViewStyle(.linear)` takes a flat
/// tint and can't be given a gradient, and because the indeterminate case needs
/// to look *alive*: media downloads sit in phases (setup, ffmpeg merge) that move
/// no bytes, and a frozen-looking bar there reads as a hung download.
///
/// Pass `nil` for `value` to get the indeterminate sweep.
struct ProgressTrack: View {
    /// Completion in 0...1, or `nil` for indeterminate.
    var value: Double?
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.backgroundProminence) private var backgroundProminence
    @State private var sweeping = false

    /// Inside a focused List selection the band is already the accent color, so
    /// an amber fill on an amber ground shows nothing. Go monochrome there.
    private var isEmphasized: Bool { backgroundProminence == .increased }

    private var fill: AnyShapeStyle {
        isEmphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.progressGradient)
    }

    private var trackFill: Color {
        isEmphasized ? .white.opacity(0.25) : Theme.Palette.stroke
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(trackFill)

                if let value {
                    Capsule(style: .continuous)
                        .fill(fill)
                        .frame(width: geo.size.width * value.clampedToUnitInterval)
                } else {
                    indeterminateFill(in: geo.size.width)
                }
            }
        }
        .frame(height: height)
        // Snapshots land every 250ms; easing across that gap turns a staircase
        // into a glide.
        .animation(.easeOut(duration: 0.25), value: value)
    }

    @ViewBuilder
    private func indeterminateFill(in width: CGFloat) -> some View {
        if reduceMotion {
            // No sweep to chase — a static partial fill still signals "working"
            // without animating anything.
            Capsule(style: .continuous)
                .fill(fill)
                .opacity(0.3)
        } else {
            let bandWidth = max(40, width * 0.35)
            Capsule(style: .continuous)
                .fill(fill)
                .frame(width: bandWidth)
                .offset(x: sweeping ? width : -bandWidth)
                .animation(
                    .linear(duration: 1.1).repeatForever(autoreverses: false),
                    value: sweeping
                )
                .onAppear { sweeping = true }
                .onDisappear { sweeping = false }
                .clipped()
        }
    }
}

private extension Double {
    var clampedToUnitInterval: Double { Swift.min(1, Swift.max(0, self)) }
}
