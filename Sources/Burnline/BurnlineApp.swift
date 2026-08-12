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

        Window("Welcome to Burnline", id: OnboardingWindow.id) {
            OnboardingView(store: store)
                .preferredColorScheme(.dark)
                .windowBackground()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // The popover's contents in a plain window, so they can be screenshotted
        // from a terminal. A MenuBarExtra popover can only be opened by clicking
        // it, and three defects in this app were invisible in code review and
        // obvious in a picture. Opened by BURNLINE_OPEN_POPOVER=1, never by the
        // user — the menu bar item remains the only way in normally.
        Window("Burnline", id: PopoverWindow.id) {
            PopoverView(store: store)
                .preferredColorScheme(.dark)
                .windowBackground()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
