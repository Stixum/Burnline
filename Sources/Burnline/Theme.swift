import SwiftUI

enum Theme {
    // Dark family, hardcoded. The popover does not follow system appearance —
    // that is the portfolio standard: one scheme per product, committed to.
    static let background = Color(red: 10 / 255, green: 10 / 255, blue: 15 / 255)       // #0a0a0f
    static let surface = Color(red: 18 / 255, green: 18 / 255, blue: 26 / 255)          // #12121a
    static let track = Color(red: 28 / 255, green: 28 / 255, blue: 38 / 255)            // #1c1c26
    static let hairline = Color.white.opacity(0.08)

    static let accent = Color(red: 124 / 255, green: 92 / 255, blue: 255 / 255)         // #7C5CFF
    static let success = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)        // #4ade80
    static let danger = Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)        // #f87171

    // Muted greys picked to clear 4.5:1 against #0a0a0f — the design standards
    // call out low-alpha muted text on near-black as a recurring failure.
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 180 / 255, green: 180 / 255, blue: 196 / 255) // #B4B4C4, 9.3:1
    static let textMuted = Color(red: 133 / 255, green: 133 / 255, blue: 154 / 255)     // #85859A, 5.3:1

    // SOFT radius camp
    static let radiusCard: CGFloat = 12
    static let radiusControl: CGFloat = 10
    static let radiusRow: CGFloat = 8

    static let popoverWidth: CGFloat = 300
}

extension View {
    /// Paints the whole window including the title bar. A plain `.background()`
    /// leaves the default translucent material showing whatever sits behind the
    /// window. `containerBackground` is macOS 15+, so 14 falls back.
    @ViewBuilder
    func windowBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(Theme.background, for: .window)
        } else {
            self.background(Theme.background)
        }
    }

    /// Uppercase tracked eyebrow, per the portfolio micro-label standard.
    func eyebrow() -> some View {
        self.font(.system(size: 10, weight: .bold))
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(Theme.textMuted)
    }
}
