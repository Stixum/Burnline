import SwiftUI
import Sparkle

/// Sparkle wrapper.
///
/// The update check is the only network request Burnline makes on its own
/// initiative. No telemetry, no profile (`SUSendProfileInfo` is explicitly
/// false in Info.plist) — just a GET of the appcast.
///
/// 🔴 **Started at launch, from `MenuBarLabel`'s task, and nowhere later.** The
/// controller is built with `startingUpdater: true`, so Sparkle starts as a side
/// effect of the first access to `shared` — and until 2026-09-05 the only
/// accesses were in `SettingsView`. A user who installed the DMG and never
/// opened Settings therefore never had the updater running at all: no
/// scheduled check, no update offered, while the README promised both. The
/// laziness is kept (it costs nothing), but `startAtLaunch()` is what makes the
/// first access happen whether or not a window is ever opened.
///
/// ⚠️ **Unavailable outside a bundle.** Sparkle needs `Bundle.main`'s
/// `Info.plist` — feed URL, public key, version — and the debug binary has
/// none, so starting it there fails and puts up a modal "Unable to Check For
/// Updates" alert on every launch. That alert is what froze the History window
/// in the screenshot harness (see CLAUDE.md). Same guard as `Notifier`: a
/// process without a bundle identifier gets a no-op updater, not a broken one.
@MainActor
final class Updater {
    static let shared = Updater()

    /// A bare executable has no `Info.plist`, so `swift run` and
    /// `.build/debug/Burnline` land here. Under `swift test` `Bundle.main` is
    /// the xctest host, which has one — so this is not a test guard.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Starts Sparkle by forcing the first access to `shared`. Idempotent.
    static func startAtLaunch() {
        guard isAvailable else { return }
        _ = shared
    }

    /// `nil` outside a bundle, where every method below is a no-op.
    private let controller: SPUStandardUpdaterController? = Updater.isAvailable
        ? SPUStandardUpdaterController(startingUpdater: true,
                                       updaterDelegate: nil, userDriverDelegate: nil)
        : nil

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        guard let controller else { return }
        // LSUIElement processes are never activated, so Sparkle's window opens
        // behind everything and the button reads as dead — the same trap that
        // made SettingsLink no-op in this app.
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
