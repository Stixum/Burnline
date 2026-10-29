import Testing
import Foundation
@testable import BurnlineCore

// The History chart names each line with a label hung off its last point.
// Percent mode pins the axis at 0…100, so two prior weeks that both finish near
// their allowance end in the same corner of the plot. Hung independently and
// fitted to the plot, the two labels landed on each other: on 2026-10-18,
// "Oct 2 – Oct 9" ending at 100% and "Oct 9 – Oct 16" ending at 92% rendered
// as `Oct12–Oct16`. `Sources/Burnline` has no test target, so the placement is
// a Core rule and these watch it.

/// The Percent chart's plot area as measured on the 1.6.1 window: 100% at the
/// top edge, 0% at the bottom, 168pt apart.
private let plot = HistoryEndLabels.Plot(minX: 0, minY: 0, maxX: 700, maxY: 168)

/// Where a reading sits vertically on that plot.
private func y(percent: Double) -> Double {
    plot.maxY - (plot.maxY - plot.minY) * percent / 100
}

/// A label the size `Text` renders a week's name at 10pt semibold.
private func label(x: Double, percent: Double, width: Double = 66) -> HistoryEndLabels.Request {
    HistoryEndLabels.Request(anchorX: x, anchorY: y(percent: percent), width: width, height: 12)
}

private func overlap(_ a: HistoryEndLabels.Box, _ b: HistoryEndLabels.Box) -> Bool {
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
}

private func expectLegible(_ boxes: [HistoryEndLabels.Box],
                           sourceLocation: SourceLocation = #_sourceLocation) {
    for (i, a) in boxes.enumerated() {
        #expect(a.minX >= plot.minX && a.maxX <= plot.maxX
                && a.minY >= plot.minY && a.maxY <= plot.maxY,
                "label \(i) left the plot: \(a)", sourceLocation: sourceLocation)
        for (j, b) in boxes.enumerated() where j > i {
            #expect(!overlap(a, b), "labels \(i) and \(j) overlap: \(a) / \(b)",
                    sourceLocation: sourceLocation)
        }
    }
}

@Test func priorWeeksEndingAt100And92PercentKeepTheirLabelsApart() {
    // 🔴 The defect as it shipped in 1.6.1. Newest first, as the chart passes
    // them: the 92% week, then the 100% week, both ending at the reset.
    let boxes = HistoryEndLabels.place([label(x: plot.maxX, percent: 92, width: 68),
                                        label(x: plot.maxX, percent: 100, width: 62)],
                                       in: plot)
    expectLegible(boxes)
    // The labels stack in the order their lines end, or each one names the
    // other week's line.
    #expect(boxes[1].maxY <= boxes[0].minY)
}

@Test func twoWeeksBothAtTheCeilingStackDownwardBecauseNeitherCanMoveUp() {
    // 🔴 The edge the task names: at 100% a label has no room above it, so
    // nudging "up" is not a fix. One of them has to give way downward.
    let boxes = HistoryEndLabels.place([label(x: plot.maxX, percent: 100),
                                        label(x: plot.maxX, percent: 100)],
                                       in: plot)
    expectLegible(boxes)
    #expect(boxes[0].minY == plot.minY)
}

@Test func weeksEndingTogetherAtTheFloorStackUpward() {
    // The mirror case: a label pushed down past the bottom edge must come back
    // up, taking the ones above it along.
    let boxes = HistoryEndLabels.place([label(x: plot.maxX, percent: 0),
                                        label(x: plot.maxX, percent: 0),
                                        label(x: plot.maxX, percent: 1)],
                                       in: plot)
    expectLegible(boxes)
}

@Test func aLabelWithRoomHangsJustAboveItsOwnPoint() {
    // Nothing moves that does not have to. A label in the left half starts at
    // its point and reaches right, into the stretch the line has not reached
    // yet; one in the right half ends at its point.
    let left = HistoryEndLabels.place([label(x: 200, percent: 30)], in: plot)[0]
    #expect(left.minX == 200)
    #expect(left.maxY == y(percent: 30) - HistoryEndLabels.spacing)

    let right = HistoryEndLabels.place([label(x: 600, percent: 30)], in: plot)[0]
    #expect(right.maxX == 600)
    #expect(right.maxY == y(percent: 30) - HistoryEndLabels.spacing)
}

@Test func labelsInDifferentColumnsAreNotDisplacedByEachOther() {
    // The live week ends mid-plot; a prior week at the same height ends at the
    // reset. They share a row, not a column, and neither should move.
    let boxes = HistoryEndLabels.place([label(x: 250, percent: 40),
                                        label(x: plot.maxX, percent: 40)],
                                       in: plot)
    expectLegible(boxes)
    #expect(boxes[0].maxY == y(percent: 40) - HistoryEndLabels.spacing)
    #expect(boxes[1].maxY == y(percent: 40) - HistoryEndLabels.spacing)
}

// Three labels in one corner were clutter: the prior weeks finish near their
// allowance together, their stacked names crowded the `now` rule's label, and
// the legend below the plot already names them by colour. Only the live week
// is labelled at its end; a chart drawing one series has no legend, so that
// series keeps its label whichever week it is.

@Test func onlyTheLiveWeekIsLabelledWhenTheLegendNamesThePriors() {
    #expect(HistoryEndLabels.legendIsVisible(seriesCount: 3))
    #expect(HistoryEndLabels.isLabelled(rampIndex: 0, seriesCount: 3))
    #expect(!HistoryEndLabels.isLabelled(rampIndex: 1, seriesCount: 3))
    #expect(!HistoryEndLabels.isLabelled(rampIndex: 2, seriesCount: 3))
}

@Test func aLonePriorWeekKeepsItsLabelBecauseNoLegendIsDrawn() {
    #expect(!HistoryEndLabels.legendIsVisible(seriesCount: 1))
    #expect(HistoryEndLabels.isLabelled(rampIndex: 1, seriesCount: 1))
}

@Test func twoPriorsWithoutTheLiveWeekAreLeftToTheLegend() {
    // The first quarter-hour after a reset: the live window has too few points
    // to draw, so the chart holds two priors and the legend names both.
    #expect(!HistoryEndLabels.isLabelled(rampIndex: 1, seriesCount: 2))
    #expect(!HistoryEndLabels.isLabelled(rampIndex: 2, seriesCount: 2))
}
