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

        // Resizable, unlike the others: it carries two charts and a table, and
        // the useful width depends on how long the user's project names are.
        Window("Burnline History", id: HistoryWindow.id) {
            HistoryView(store: store)
                .preferredColorScheme(.dark)
                .windowBackground()
        }
        // The page runs past 850pt at this width, so *something* is below the
        // fold at any height that still fits a laptop. 820 puts the fold partway
        // down "Where it went": the scoreboard and the burn curves including
        // their legend are whole, and enough bars show to read the shape and to
        // make it obvious there are more. It also clears the ~875pt of usable
        // height on a 1440×900 display, the smallest still in common use — a
        // taller default would just be clamped there and lose the centring.
        // Only the first open reads this; macOS persists the frame afterwards.
        .defaultSize(width: 780, height: 820)
        .defaultPosition(.center)

        Window("Burnline Setup", id: OnboardingWindow.id) {
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
