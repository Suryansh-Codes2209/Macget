import AppKit
import Observation

/// The menu bar item: a progress ring plus aggregate speed, and a menu for
/// checking or pausing downloads without raising the window.
///
/// AppKit rather than SwiftUI's `MenuBarExtra` because the ring is a drawn
/// image, which `MenuBarExtra`'s label can't produce cleanly.
///
/// **It reads the view model, not the engine.** `DownloadEngine.events` is a
/// single-consumer `AsyncStream`; a second `for await` over it would split
/// events between the two consumers and silently starve the list. Observing
/// `DownloadListViewModel` keeps one consumer and one source of truth.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    private let listVM: DownloadListViewModel
    private let statusItem: NSStatusItem
    private var model: StatusBarModel

    init(listVM: DownloadListViewModel) {
        self.listVM = listVM
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.model = StatusBarModel(rows: listVM.rows, totalSpeed: listVM.totalSpeed, linkTotals: listVM.linkTotals)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading

        render()
        observe()
    }

    // MARK: - Observation

    /// Redraw only when the values actually shown change, so an idle MacGet does
    /// no per-frame work. `withObservationTracking` fires once, hence the
    /// re-arm inside `onChange`.
    private func observe() {
        withObservationTracking {
            _ = listVM.rows
            _ = listVM.totalSpeed
            _ = listVM.linkTotals
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.render()
                self.observe()
            }
        }
    }

    private func render() {
        let next = StatusBarModel(rows: listVM.rows, totalSpeed: listVM.totalSpeed, linkTotals: listVM.linkTotals)
        guard next != model || statusItem.button?.image == nil else { return }
        model = next

        guard let button = statusItem.button else { return }
        button.image = Self.icon(fraction: model.isActive ? model.fractionComplete : nil,
                                 active: model.isActive)
        button.title = model.titleText.isEmpty ? "" : " \(model.titleText)"
        button.toolTip = model.headerText
    }

    // MARK: - Icon

    private static let iconSize = NSSize(width: 16, height: 16)

    /// Idle draws the plain glyph as a *template* so AppKit tints it for the
    /// current menu bar appearance. The active ring can't be a template — a
    /// template image is a mask and would lose the accent colour that makes the
    /// filled portion readable — so it is redrawn on every progress change,
    /// which also picks up an appearance switch within a second or so.
    static func icon(fraction: Double?, active: Bool) -> NSImage {
        guard active else {
            let image = NSImage(systemSymbolName: "arrow.down.circle",
                                accessibilityDescription: "MacGet")
                ?? NSImage(size: iconSize)
            image.isTemplate = true
            return image
        }

        let image = NSImage(size: iconSize, flipped: false) { rect in
            let lineWidth: CGFloat = 2
            let box = rect.insetBy(dx: lineWidth / 2 + 0.5, dy: lineWidth / 2 + 0.5)
            let center = NSPoint(x: box.midX, y: box.midY)
            let radius = min(box.width, box.height) / 2

            let track = NSBezierPath(ovalIn: box)
            track.lineWidth = lineWidth
            NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
            track.stroke()

            // An indeterminate download (no Content-Length) gets the empty
            // track only — a ring at an invented angle would be a lie.
            if let fraction, fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center,
                              radius: radius,
                              startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(min(1, max(0, fraction))),
                              clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                NSColor.controlAccentColor.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Menu

    /// Rebuilt on open rather than on a timer: the menu is only ever read while
    /// it is on screen, so keeping it live the rest of the time is wasted work.
    func menuWillOpen(_ menu: NSMenu) {
        render()
        menu.removeAllItems()

        let header = NSMenuItem(title: model.headerText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let summary = model.linkSummaryText {
            let item = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !model.entries.isEmpty {
            menu.addItem(.separator())
            for entry in model.entries {
                let item = NSMenuItem(
                    title: "\(Self.truncate(entry.filename))   \(entry.percentText)",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
            if let overflow = model.overflowText {
                let item = NSMenuItem(title: overflow, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(action(title: "Pause All", selector: #selector(pauseAll)))
        menu.addItem(action(title: "Resume All", selector: #selector(resumeAll)))
        menu.addItem(.separator())
        menu.addItem(action(title: "Open MacGet", selector: #selector(openMacGet)))
    }

    private func action(title: String, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Torrent and media names run long; the menu shouldn't stretch to fit them.
    static func truncate(_ name: String, limit: Int = 44) -> String {
        guard name.count > limit else { return name }
        return name.prefix(limit - 1) + "…"
    }

    // MARK: - Actions

    @objc private func pauseAll() { listVM.pauseAll() }
    @objc private func resumeAll() { listVM.resumeAll() }

    @objc private func openMacGet() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // The window was closed outright; this is the same path the Dock
            // icon uses to have SwiftUI rebuild one.
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
    }
}
