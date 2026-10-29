import Foundation

/// Where the History chart hangs the direct label at the end of each line, so
/// no two labels overlap.
///
/// 🔴 **Hung independently, they collided.** Each label used to be a Swift
/// Charts annotation fitted to the plot on its own, and nothing knew about its
/// neighbours. Percent mode pins the axis at 0…100, so two prior weeks that
/// both finish near their allowance end in the same top-right corner: on
/// 2026-10-18 "Oct 2 – Oct 9" at 100% and "Oct 9 – Oct 16" at 92% rendered
/// on top of each other as `Oct12–Oct16`. The units chart's auto-fitted axis
/// leaves headroom above the tallest line, which hid the defect there until two
/// weeks ended at the same total; a fixed domain has none, and at 100% a label
/// cannot move up at all. Both charts now place their labels through here.
///
/// So the labels are laid out together: each starts just above its own point,
/// and any two that share a column are stacked apart — downward from the top
/// edge, then upward from the bottom edge — keeping the order their lines end
/// in, so the upper label still names the upper line.
///
/// Everything here is layout geometry in the plot's own points, y growing
/// downward the way SwiftUI measures it. Nothing a reader is shown as a
/// figure comes from it.
public enum HistoryEndLabels {

    /// Whether the chart draws a legend. A single series is already named by
    /// its direct label, and a one-entry legend is furniture.
    public static func legendIsVisible(seriesCount: Int) -> Bool {
        seriesCount >= 2
    }

    /// Whether a series is named at the end of its line.
    ///
    /// ⚠️ **The live week only, whenever there is a legend.** Labelling every
    /// line put three names in one corner: prior weeks finish near their
    /// allowance together, their stacked plates crowded the `now` rule's label
    /// and covered the lines they named, and the legend already said the same
    /// thing. `rampIndex` 0 is the live window (`HistoryOverlay`).
    public static func isLabelled(rampIndex: Int, seriesCount: Int) -> Bool {
        rampIndex == 0 || !legendIsVisible(seriesCount: seriesCount)
    }

    /// The gap between a line's last point and the bottom of its label.
    public static let spacing: Double = 3
    /// The least space between two stacked labels.
    public static let gap: Double = 1

    /// The plot area the labels must stay inside.
    public struct Plot: Equatable, Sendable {
        public let minX: Double
        public let minY: Double
        public let maxX: Double
        public let maxY: Double

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }

        var midX: Double { (minX + maxX) / 2 }
    }

    /// One label to place: the line's last point and the label's size.
    public struct Request: Equatable, Sendable {
        public let anchorX: Double
        public let anchorY: Double
        public let width: Double
        public let height: Double

        public init(anchorX: Double, anchorY: Double, width: Double, height: Double) {
            self.anchorX = anchorX
            self.anchorY = anchorY
            self.width = width
            self.height = height
        }
    }

    /// Where one label landed.
    public struct Box: Equatable, Sendable {
        public let minX: Double
        public let minY: Double
        public let width: Double
        public let height: Double

        public var maxX: Double { minX + width }
        public var maxY: Double { minY + height }
        public var midX: Double { minX + width / 2 }
        public var midY: Double { minY + height / 2 }
    }

    /// One box per request, in the order given.
    public static func place(_ requests: [Request], in plot: Plot) -> [Box] {
        // Horizontally: hang on the side the line has not reached yet.
        //
        // ⚠️ A label reaching back LEFT sits over the stretch the line just
        // came from, and for the live week that stretch is where a re-grant's
        // ring and dashed drop sit: a week ending a few hours after a re-grant
        // printed its name straight across the event. Only a right-half
        // endpoint reaches left, where reaching right would run off the plot.
        let minXs = requests.map { request in
            let preferred = request.anchorX < plot.midX
                ? request.anchorX
                : request.anchorX - request.width
            return clamp(preferred, plot.minX, plot.maxX - request.width)
        }
        // Vertically: just above the point, wherever there is room.
        let wanted = requests.map { $0.anchorY - spacing - $0.height }
        var minYs = zip(wanted, requests).map { top, request in
            clamp(top, plot.minY, plot.maxY - request.height)
        }

        // 🔴 Ordered by where each LINE ends, not by where its label was
        // clamped to. At the top edge both labels clamp to the same row, and
        // breaking that tie by input order put the 92% week's name above the
        // 100% week's line.
        let order = requests.indices.sorted { a, b in
            (wanted[a], a) < (wanted[b], b)
        }
        func shareAColumn(_ a: Int, _ b: Int) -> Bool {
            minXs[a] < minXs[b] + requests[b].width + gap
                && minXs[b] < minXs[a] + requests[a].width + gap
        }

        // Down from the top: each label clears every higher one it shares a
        // column with. This is the pass that rescues two labels at 100%.
        for (rank, index) in order.enumerated() {
            for above in order[..<rank] where shareAColumn(above, index) {
                minYs[index] = max(minYs[index], minYs[above] + requests[above].height + gap)
            }
        }
        // Up from the bottom: a label pushed past the bottom edge comes back
        // inside and takes the ones above it along. Every pair the first pass
        // separated stays separated, because this pass only ever moves a label
        // up to clear the ones already settled below it.
        for (rank, index) in order.enumerated().reversed() {
            minYs[index] = min(minYs[index], plot.maxY - requests[index].height)
            for below in order[(rank + 1)...] where shareAColumn(index, below) {
                minYs[index] = min(minYs[index], minYs[below] - gap - requests[index].height)
            }
        }

        return requests.indices.map { index in
            Box(minX: minXs[index], minY: minYs[index],
                width: requests[index].width, height: requests[index].height)
        }
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), max(lower, upper))
    }
}
