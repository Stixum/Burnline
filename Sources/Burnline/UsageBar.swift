import SwiftUI
import BurnlineCore

/// Violet fill = what has been consumed. Solid white marker = the real-time
/// pace target. The translucent band beyond it runs to the end-of-day target
/// and *is* today's remaining allowance — spend into it and you finish the day
/// level. The dashed marker closes the band.
struct UsageBar: View {
    let estimatedPercent: Double?
    let targetPercent: Double
    let endOfDayPercent: Double
    /// Which target the headline numbers use; drawn slightly heavier.
    let mode: TargetMode

    private func fraction(_ percent: Double) -> Double {
        min(max(percent / 100, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let nowX = width * fraction(targetPercent)
            let endX = width * fraction(endOfDayPercent)

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)

                // Today's allowance.
                Rectangle()
                    .fill(Color.white.opacity(0.13))
                    .frame(width: max(0, endX - nowX))
                    .offset(x: nowX)

                if estimatedPercent != nil {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(2, width * fraction(estimatedPercent ?? 0)))
                }

                marker(solid: true, at: nowX, height: geometry.size.height,
                       emphasised: mode == .realTime)
                marker(solid: false, at: endX, height: geometry.size.height,
                       emphasised: mode == .endOfDay)
            }
            .clipShape(Capsule())
        }
        .frame(height: 11)
        .accessibilityHidden(true)   // the numbers below carry this information
    }

    private func marker(solid: Bool, at x: CGFloat, height: CGFloat,
                        emphasised: Bool) -> some View {
        Group {
            if solid {
                Rectangle().fill(Theme.textPrimary)
            } else {
                // Dashed, so it reads as the softer of the two targets.
                Rectangle()
                    .fill(Theme.textPrimary)
                    .mask(
                        VStack(spacing: 2) {
                            ForEach(0..<4, id: \.self) { _ in
                                Rectangle().frame(height: 2)
                            }
                        }
                    )
            }
        }
        .frame(width: emphasised ? 2.5 : 1.5, height: height + 8)
        .opacity(emphasised ? 1 : 0.75)
        .offset(x: x - (emphasised ? 1.25 : 0.75))
    }
}
