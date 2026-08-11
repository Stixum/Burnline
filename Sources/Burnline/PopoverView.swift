import SwiftUI
import BurnlineCore

// Placeholder — replaced in Task 5.
struct PopoverView: View {
    @Bindable var store: UsageStore

    var body: some View {
        Text(MenuBarFormatter.text(for: store.snapshot))
            .padding()
    }
}
