import Testing
import Foundation
import AppKit
@testable import BurnlineCore

// History check fix 3 (2026-11-26): the weekly figure Burnline charts, puts in
// the menu bar and paces against is Anthropic's ALL-MODELS limit, while the
// per-model limit (Fable, 94% that day) is a second figure beside it. Nothing
// said which was which: Sean's plan panel read "75% all models · 94% Fable"
// and the History caption said only "the weekly limit". Every all-models
// surface now names it, and the per-model row never does.

private func legendSnapshot(estimated: Double?) -> Snapshot {
    let start = Date(timeIntervalSince1970: 0)
    let window = Window(start: start, end: start.addingTimeInterval(7 * 86_400),
                        now: start.addingTimeInterval(3 * 86_400))
    return Snapshot(window: window, targetPercent: 43, estimatedPercent: estimated,
                    projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                    source: estimated == nil
                        ? .paceOnly : .live(capturedAt: start.addingTimeInterval(3 * 86_400)),
                    isScanning: false)
}

private func fable(_ percent: Double, _ severity: String = "critical") -> UsageUtilization.ScopedLimit {
    UsageUtilization.ScopedLimit(percent: percent, severity: severity, modelName: "Fable",
                                 resetsAt: nil)
}

@Test func thePercentCaptionNamesTheAllModelsLimit() {
    #expect(HistoryChartMode.percent.subtitle
            == "Anthropic's percentage of the weekly limit, all models, as captured")
    // Units are tokens from this Mac, not a limit: the name must not migrate.
    #expect(!HistoryChartMode.units.subtitle.contains(UsageUtilization.allModelsName))
}

@Test func thePopoversUsedFigureNamesTheAllModelsLimit() {
    #expect(legendSnapshot(estimated: 74).usedLegend == "74% used · all models")
}

@Test func withNoFigureTheLegendClaimsNoLimit() {
    // Pace-only has no usage figure, so there is nothing to name.
    #expect(legendSnapshot(estimated: nil).usedLegend == "usage unknown")
}

@Test func thePerModelRowNeverCallsItselfAllModels() {
    // 🔴 Both rows stay true: the per-model row is named by its model and
    // never by the all-models name, so the two can never read alike.
    for severity in ["normal", "warning", "critical"] {
        let row = fable(94, severity)
        #expect(row.rowLabel == "Fable weekly")
        #expect(!row.rowLabel.contains(UsageUtilization.allModelsName))
        #expect(!row.rowValue.contains(UsageUtilization.allModelsName))
        #expect(row.rowLabel != legendSnapshot(estimated: 94).usedLegend)
    }
}

@Test func thePerModelTooltipPointsAtAFigureThePopoverNowNames() {
    // The tooltip has said "separate from the all-models figure above" since
    // fix 2, while nothing above it said "all models". It is true only while
    // the legend carries the name.
    #expect(fable(94).rowHelp.contains("all-models figure above"))
    #expect(legendSnapshot(estimated: 74).usedLegend.contains(UsageUtilization.allModelsName))
}

@Test func theSpokenMenuBarLabelNamesTheAllModelsLimit() {
    let label = MenuBarFormatter.accessibilityLabel(for: legendSnapshot(estimated: 74))
    #expect(label.contains("74 percent used across all models"))
    // A pace-only label has no usage figure to qualify.
    let paceOnly = MenuBarFormatter.accessibilityLabel(for: legendSnapshot(estimated: nil))
    #expect(!paceOnly.contains(UsageUtilization.allModelsName))
}

@Test func theWidestLegendStillFitsBesideTheTarget() {
    // `PopoverView.legend`: an HStack of two 10.5pt monospaced-digit texts and
    // a Spacer, inside the 300pt panel's 14pt padding. The widest left side is
    // a clamped 999%, the widest right side three-digit targets both ways.
    let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    func width(_ text: String) -> Double {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
    let left = legendSnapshot(estimated: 4_000).usedLegend
    #expect(left == "999% used · all models")
    let right = "today 100% · now 100%"
    let budget: Double = 300 - 2 * 14 - 2 * 8 - 8
    #expect(width(left) + width(right) <= budget)
}
