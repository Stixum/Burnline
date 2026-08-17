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
    static let warning = Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)        // #fbbf24
    static let danger = Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)        // #f87171

    // Muted greys clear **7:1 (AAA)** against #0a0a0f, not merely 4.5:1 (AA).
    // AA is a floor for body text at normal sizes; almost everything here is
    // 10–11.5pt, and the design standards call out low-alpha muted text on
    // near-black as a recurring failure. The old #85859A measured 5.47:1 and
    // read as grey-on-grey at those sizes.
    static let textPrimary = Color.white                                                // 19.4:1
    static let textSecondary = Color(red: 196 / 255, green: 196 / 255, blue: 210 / 255) // #C4C4D2, 11.5:1
    static let textMuted = Color(red: 168 / 255, green: 168 / 255, blue: 188 / 255)     // #A8A8BC, 8.5:1

    // MARK: - Burn curve recency ramp

    // ⚠️ **Marks, not text.** Colour on the overlaid burn curves encodes
    // RECENCY, not identity — which is why there is deliberately no categorical
    // palette here. Newest is the accent; each older week steps back toward the
    // background.
    //
    // Contrast is measured against `background` (#0a0a0f) against the **3:1**
    // floor a graphical mark has to clear, a looser floor than the 7:1 the text
    // tokens above hold themselves to. That is the whole reason #85859A appears
    // here after being rejected a few lines up: it is unreadable as 11pt text
    // and perfectly legible as a 2px line.
    //
    // 🔴 **Two prior weeks, and no more.** The next step down this ramp measures
    // 2.94:1 — under the floor, i.e. a line some readers cannot see at all.
    // Adding a fourth series means finding a different encoding, not a fourth
    // grey.
    static let curveNewest = accent                                                     // 4.54:1
    static let curveOlder = Color(red: 180 / 255, green: 180 / 255, blue: 196 / 255)     // #B4B4C4, 9.66:1
    static let curveOldest = Color(red: 133 / 255, green: 133 / 255, blue: 154 / 255)    // #85859A, 5.47:1

    /// Newest first. The index is the series' position in the overlay.
    static let curveRamp = [curveNewest, curveOlder, curveOldest]

    /// Clamped rather than subscripted: a fourth series would trap, and the ramp
    /// having exactly three entries is a contrast decision that a caller counting
    /// windows has no reason to know about.
    static func curve(at index: Int) -> Color {
        curveRamp[min(max(index, 0), curveRamp.count - 1)]
    }

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
