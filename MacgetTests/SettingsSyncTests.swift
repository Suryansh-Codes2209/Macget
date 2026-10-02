import XCTest
@testable import Macget

/// The app's settings have two writers — the shared `SettingsViewModel` and
/// `AppEnvironment` itself (torrent / media opt-ins) — and one file. A write
/// by either must never be undone by the other saving a stale copy.
@MainActor
final class SettingsSyncTests: XCTestCase {

    /// Stands in for `AppEnvironment`, which can't be built in a test (it loads
    /// settings.json, starts the engine and installs native-messaging manifests).
    /// Its self-writes mirror `requireTorrentSupport` / `enableMediaExtractionIfNeeded`.
    @MainActor
    private final class FakeHost: SettingsHost {
        var settings = AppSettings()
        var onSettingsChanged: ((AppSettings) -> Void)?
        let torrentSetup = TorrentSetupModel()
        private(set) var saves: [AppSettings] = []

        func updateSettings(_ newSettings: AppSettings) {
            settings = newSettings
            saves.append(newSettings)
            onSettingsChanged?(newSettings)
        }

        func enableTorrentsInternally() {
            var updated = settings
            updated.torrentsEnabled = true
            updateSettings(updated)
        }

        func enableMediaInternally() {
            var updated = settings
            updated.mediaExtractionEnabled = true
            updateSettings(updated)
        }
    }

    func test_environmentSelfWriteSurvivesLaterBondingEdit() {
        let host = FakeHost()
        let vm = SettingsViewModel(host: host, initial: host.settings)

        host.enableTorrentsInternally()
        host.enableMediaInternally()
        vm.edit { $0.bonding.enabled = true }

        XCTAssertTrue(host.settings.torrentsEnabled)
        XCTAssertTrue(host.settings.mediaExtractionEnabled)
        XCTAssertTrue(host.settings.bonding.enabled)
        XCTAssertEqual(vm.settings, host.settings)
    }

    func test_viewModelMirrorsEnvironmentSelfWrite() {
        let host = FakeHost()
        let vm = SettingsViewModel(host: host, initial: host.settings)
        host.enableTorrentsInternally()
        XCTAssertTrue(vm.settings.torrentsEnabled, "the Settings window must not keep a stale copy")
    }

    func test_plainPersistAfterSelfWriteKeepsIt() {
        // The Settings window path: mutate vm.settings, then persistAndPropagate().
        let host = FakeHost()
        let vm = SettingsViewModel(host: host, initial: host.settings)
        host.enableTorrentsInternally()
        vm.settings.bonding.setLink("en7", enabled: false)
        vm.persistAndPropagate()
        XCTAssertTrue(host.settings.torrentsEnabled)
        XCTAssertEqual(host.settings.bonding.disabledLinkIDs, ["en7"])
    }

    func test_ownSaveEchoDoesNotLoop() {
        let host = FakeHost()
        let vm = SettingsViewModel(host: host, initial: host.settings)
        vm.edit { $0.bonding.enabled = true }
        XCTAssertEqual(host.saves.count, 1)
    }
}
