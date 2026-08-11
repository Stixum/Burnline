import Testing
import Foundation
@testable import BurnlineCore

private func snapshot(estimated: Double?, target: Double, scanning: Bool = false) -> Snapshot {
    let start = Date(timeIntervalSince1970: 0)
    let window = Window(start: start, end: start.addingTimeInterval(7 * 86_400),
                        now: start.addingTimeInterval(7 * 86_400 * target / 100))
    return Snapshot(window: window, targetPercent: target, estimatedPercent: estimated,
                    projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                    isScanning: scanning)
}

@Test func showsActualOverTargetWhenCalibrated() {
    #expect(MenuBarFormatter.text(for: snapshot(estimated: 40.4, target: 71.4)) == "40/71")
}

@Test func showsTargetAloneWhenUncalibrated() {
    #expect(MenuBarFormatter.text(for: snapshot(estimated: nil, target: 71.4)) == "71")
}

@Test func showsEllipsisWhileFirstScanRuns() {
    #expect(MenuBarFormatter.text(for: snapshot(estimated: nil, target: 0, scanning: true)) == "…")
}

@Test func roundsToWholePercent() {
    #expect(MenuBarFormatter.text(for: snapshot(estimated: 39.6, target: 71.5)) == "40/72")
}

@Test func clampsOutlandishEstimates() {
    #expect(MenuBarFormatter.text(for: snapshot(estimated: 4_000, target: 50)) == "999/50")
}

@Test func accessibilityLabelSpellsBothNumbersOut() {
    let label = MenuBarFormatter.accessibilityLabel(for: snapshot(estimated: 40, target: 71))
    #expect(label.contains("40"))
    #expect(label.contains("71"))
    #expect(label.lowercased().contains("under budget"))
}

@Test func accessibilityLabelSaysOverBudgetWhenOver() {
    let label = MenuBarFormatter.accessibilityLabel(for: snapshot(estimated: 90, target: 71))
    #expect(label.lowercased().contains("over budget"))
}
