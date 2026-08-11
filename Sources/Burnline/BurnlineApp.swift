import SwiftUI
import BurnlineCore

@main
struct BurnlineApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        // An explicit Window, not a Settings scene: SettingsLink silently does
        // nothing in an LSUIElement app. See SettingsWindow.open.
        Window("Burnline Settings", id: SettingsWindow.id) {
            SettingsView(store: store)
                .preferredColorScheme(.dark)
                .windowBackground()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
