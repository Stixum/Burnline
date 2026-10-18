import SwiftUI
import Charts
import BurnlineCore

/// The direct label at the end of each History burn curve, so a series is
/// identifiable without tracing a colour back to the legend. Both chart modes
/// draw their labels through this one view.
///
/// 🔴 **Laid out together, never as one annotation per point.** An annotation
/// is fitted to the plot on its own and knows nothing of its neighbours. In
/// Percent mode the axis is pinned at 100, so two prior weeks that both finish
/// near their allowance end in the same corner, and on 2026-10-18 "Oct 2 –
/// Oct 9" at 100% and "Oct 9 – Oct 16" at 92% printed on top of each other as
/// `Oct12–Oct16`. Units mode escaped only because its auto-fitted axis leaves
/// headroom above the tallest line, and two weeks ending at near-equal totals
/// collided there the same way. `HistoryEndLabels` stacks them; the chart's
/// proxy is only asked where each point landed.
///
/// The dots stay on the chart as `PointMark`s. Only the text is drawn here.
struct HistoryEndLabelOverlay: View {
    /// One series' label, at that series' last point in data space.
    struct Label {
        let text: String
        let fraction: Double
        let value: Double
    }

    let labels: [Label]
    let proxy: ChartProxy
    let plotFrame: CGRect

    /// The labels' point size, shared by the `Text` and the measurement that
    /// lays it out — two numbers that must never drift apart.
    private static let fontSize: CGFloat = 10

    var body: some View {
        let font = NSFont.systemFont(ofSize: Self.fontSize, weight: .semibold)
        let requests = labels.map { label in
            let size = (label.text as NSString).size(withAttributes: [.font: font])
            return HistoryEndLabels.Request(
                anchorX: plotFrame.minX + (proxy.position(forX: label.fraction) ?? 0),
                anchorY: plotFrame.minY + (proxy.position(forY: label.value) ?? 0),
                width: ceil(size.width), height: ceil(size.height))
        }
        let boxes = HistoryEndLabels.place(
            requests,
            in: HistoryEndLabels.Plot(minX: plotFrame.minX, minY: plotFrame.minY,
                                      maxX: plotFrame.maxX, maxY: plotFrame.maxY))
        ForEach(Array(zip(labels, boxes).enumerated()), id: \.offset) { _, pair in
            // ⚠️ A text token, NOT the series colour. Two of the three ramp
            // colours are below the contrast floor for text at this size —
            // they are legible as lines and not as labels.
            Text(pair.0.text)
                .font(.system(size: Self.fontSize, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
                .position(x: pair.1.midX, y: pair.1.midY)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Draws a chart's end labels over its plot area.
    func historyEndLabels(_ labels: [HistoryEndLabelOverlay.Label]) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    HistoryEndLabelOverlay(labels: labels, proxy: proxy,
                                           plotFrame: geometry[plotFrame])
                }
            }
        }
    }
}
