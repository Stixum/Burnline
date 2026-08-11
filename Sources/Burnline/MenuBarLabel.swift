import SwiftUI
import BurnlineCore

/// The menu bar item's label, and the app's start-up hook.
///
/// No color here on purpose — macOS tints menu bar content for light and dark
/// bars, and a hardcoded color is unreadable on one of them.
struct MenuBarLabel: View {
    let store: UsageStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(MenuBarFormatter.text(for: store.snapshot,
                                   target: store.settings.targetMode,
                                   display: store.settings.menuBarMode))
            .monospacedDigit()
            .accessibilityLabel(MenuBarFormatter.accessibilityLabel(
                for: store.snapshot,
                target: store.settings.targetMode,
                display: store.settings.menuBarMode))
            // The label is live from launch, so this starts the refresh loop
            // even if the popover is never opened.
            .task {
                // The app is hardcoded dark, so declare that to AppKit. Without
                // it, system controls (pickers, steppers, checkboxes, title bar)
                // render for light mode and come out near-black on near-black.
                NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
                store.start()
                // Lets the settings window be opened without a click, so it can
                // be verified from a terminal.
                if ProcessInfo.processInfo.environment["BURNLINE_OPEN_SETTINGS"] == "1" {
                    SettingsWindow.open(using: openWindow)
                    FileHandle.standardError.write(Data(
                        "BURNLINE effectiveAppearance=\(NSApplication.shared.effectiveAppearance.name.rawValue)\n".utf8))
                }
            }
    }
}

enum SettingsWindow {
    static let id = "burnline-settings"

    /// A `Settings` scene reached by `SettingsLink` does not work from an
    /// `LSUIElement` app — the process is never activated, so the scene has
    /// nothing to attach to and the click appears to do nothing. An explicit
    /// window plus an activate call is the combination that actually shows up.
    @MainActor
    static func open(using openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
