import Foundation
import Observation

/// The usable network links, for the UI.
///
/// One instance for the whole app (owned by `MacgetApp`), so the window toolbar
/// and Settings read the same list from a single `NetworkLinkMonitor`
/// subscription instead of each opening their own.
@MainActor
@Observable
final class ConnectionsModel {
    /// Preference order, default route first — as `NetworkLinkMonitor` publishes them.
    private(set) var links: [NetworkLink] = []

    @ObservationIgnored private let monitor: NetworkLinkMonitor
    @ObservationIgnored private var task: Task<Void, Never>?

    init(monitor: NetworkLinkMonitor = .shared) {
        self.monitor = monitor
    }

    /// Idempotent; safe to call from every view that appears.
    func start() {
        guard task == nil else { return }
        let monitor = monitor
        task = Task { [weak self] in
            await monitor.start()
            for await snapshot in await monitor.updates() {
                guard !Task.isCancelled else { return }
                self?.links = snapshot.links
            }
        }
    }
}
