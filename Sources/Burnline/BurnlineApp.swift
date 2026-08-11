import SwiftUI
import BurnlineCore

@main
struct BurnlineApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            // No color here on purpose — macOS tints menu bar content for light
            // and dark bars, and a hardcoded color breaks one of them.
            Text(MenuBarFormatter.text(for: store.snapshot))
                .monospacedDigit()
                .accessibilityLabel(MenuBarFormatter.accessibilityLabel(for: store.snapshot))
                // The label is live from launch, so this starts the refresh loop
                // even if the popover is never opened.
                .task { store.start() }
        }
        .menuBarExtraStyle(.window)

        // A real Settings scene, not a sheet: a menu bar popover dismisses when
        // it loses focus, which would tear a sheet down with it.
        Settings {
            SettingsView(store: store)
        }
    }
}
