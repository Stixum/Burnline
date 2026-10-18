import Foundation

/// Which completed weeks the History window lists, and what its toggle says.
///
/// The scoreboard sits under the chart and grows by a row every week, so all
/// but the newest few fold behind a toggle. Not persisted: like the chart mode,
/// a restored state is one nobody chose in this sitting, and the folded list is
/// the one that keeps the breakdown on screen.
///
/// 🔴 **The week in the breakdown is never folded away.** The breakdown's range
/// menu can pick any week, and its bars must add up to a number the reader can
/// see. A selected week past the fold is appended after the newest ones; its
/// row carries its own dates, so the jump is labelled rather than implied.
public enum HistoryScoreboardDisclosure {
    /// About a month — the span Claude Code keeps transcripts for, and so the
    /// span the chart's recent weeks are drawn from.
    public static let collapsedCount = 4

    public struct Layout: Equatable, Sendable {
        /// Indices into the newest-first rows, in display order.
        public let visibleIndices: [Int]
        /// Nil when every week fits without one.
        public let toggleTitle: String?
    }

    public static func layout(rowCount: Int, selectedIndex: Int?,
                              isExpanded: Bool) -> Layout {
        let all = Array(0..<rowCount)
        // A toggle is a row tall: folding one week saves nothing and costs a click.
        guard rowCount > collapsedCount + 1 else {
            return Layout(visibleIndices: all, toggleTitle: nil)
        }
        if isExpanded {
            return Layout(visibleIndices: all, toggleTitle: "Show fewer weeks")
        }
        var visible = Array(0..<collapsedCount)
        if let selectedIndex, selectedIndex >= collapsedCount, selectedIndex < rowCount {
            visible.append(selectedIndex)
        }
        return Layout(visibleIndices: visible, toggleTitle: "Show all \(rowCount) weeks")
    }
}
