import Testing
import Foundation
@testable import BurnlineCore

@Test func aUnitChartIsSummarisedByWhereEachWeekEnded() {
    let value = HistoryAccessibility.unitCurvesValue([
        .init(label: "This week", value: 180_000_000),
        .init(label: "Nov 13 – Nov 20", value: 885_000_000),
    ])
    #expect(value == "This week, 180 million units; Nov 13 – Nov 20, 885 million units")
}

@Test func aPercentChartIsSummarisedInPercent() {
    let value = HistoryAccessibility.percentCurvesValue([
        .init(label: "This week", value: 20),
        .init(label: "Nov 13 – Nov 20", value: 84),
    ])
    #expect(value == "This week, 20 percent; Nov 13 – Nov 20, 84 percent")
}

@Test func aChartWithNoWeeksSaysSoRatherThanNothing() {
    #expect(HistoryAccessibility.unitCurvesValue([]) == "No weeks recorded yet")
    #expect(HistoryAccessibility.percentCurvesValue([]) == "No weeks recorded yet")
}

@Test func aBreakdownBarSpeaksItsUnitsAndShare() {
    #expect(HistoryAccessibility.breakdownValue(units: 440_000_000, share: 0.5)
            == "440 million units, 50 percent")
    #expect(HistoryAccessibility.breakdownValue(units: 1_400_000_000, share: 0.004)
            == "1.4 billion units, under 1 percent")
    #expect(HistoryAccessibility.breakdownValue(units: 97_100_000, share: 0.995)
            == "97.1 million units, over 99 percent")
}

/// The spoken form is built from the visible one, so the two cannot disagree.
@Test func spokenUnitsSpellOutEverySuffixTheVisibleLabelUses() {
    for value in [0.0, 512, 37_000, 885_000_000, 1.4e9, 2.5e12, .infinity] {
        let spoken = HistoryAccessibility.spokenUnits(value)
        #expect(!spoken.contains("—"))
        #expect(spoken.last.map { !"KMBT".contains($0) } ?? false, "\(value) → \(spoken)")
    }
    #expect(HistoryAccessibility.spokenUnits(.infinity) == "unknown")
}
