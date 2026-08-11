import SwiftUI

/// Violet fill = what has been consumed. White marker = the pace target.
/// Fill behind the marker means under budget.
struct UsageBar: View {
    let estimatedPercent: Double?
    let targetPercent: Double

    private var fillFraction: Double {
        min(max((estimatedPercent ?? 0) / 100, 0), 1)
    }
    private var markerFraction: Double {
        min(max(targetPercent / 100, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)

                if estimatedPercent != nil {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(2, geometry.size.width * fillFraction))
                }

                Rectangle()
                    .fill(Theme.textPrimary)
                    .frame(width: 2, height: geometry.size.height + 8)
                    .offset(x: geometry.size.width * markerFraction - 1)
            }
        }
        .frame(height: 9)
        .accessibilityHidden(true)   // the numbers below carry this information
    }
}
