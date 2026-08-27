import SwiftUI
import Sparkle

/// Sparkle wrapper.
///
/// The update check is the only network request Burnline makes on its own
/// initiative. No telemetry, no profile (`SUSendProfileInfo` is explicitly
/// false in Info.plist) — just a GET of the appcast.
///
/// Constructing the controller with `startingUpdater: true` starts the updater
/// as a side effect of the first access to `shared`, which happens when the
/// Settings window first renders. That is intended: automatic checks need the
/// updater running, and starting it earlier (at launch) would be equally
/// correct. What must not happen is it never starting at all.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        // LSUIElement processes are never activated, so Sparkle's window opens
        // behind everything and the button reads as dead — the same trap that
        // made SettingsLink no-op in this app.
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
