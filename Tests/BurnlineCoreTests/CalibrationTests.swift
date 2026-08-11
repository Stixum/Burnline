import Testing
import Foundation
@testable import BurnlineCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func anchor(percent: Double, units: Double, daysAgo: Double = 0) -> CalibrationAnchor {
    CalibrationAnchor(id: UUID(),
                      timestamp: now.addingTimeInterval(-daysAgo * 86_400),
                      observedPercent: percent,
                      unitsInWindow: units)
}

@Test func noAnchorsMeansNoEstimate() {
    #expect(Calibration.unitsPerPercent([], now: now) == nil)
    #expect(Calibration.estimatedPercent(unitsInWindow: 5_000, anchors: [], now: now) == nil)
}

@Test func singleAnchorIsASimpleDivide() {
    let anchors = [anchor(percent: 40, units: 4_000)]
    #expect(abs(Calibration.unitsPerPercent(anchors, now: now)! - 100) < 1e-9)
    let estimate = Calibration.estimatedPercent(unitsInWindow: 7_100, anchors: anchors, now: now)
    #expect(abs(estimate! - 71) < 1e-9)
}

@Test func multipleAnchorsFitThroughTheOrigin() {
    // Perfectly consistent anchors must reproduce the exact ratio.
    let anchors = [anchor(percent: 20, units: 2_000, daysAgo: 9),
                   anchor(percent: 50, units: 5_000, daysAgo: 2),
                   anchor(percent: 80, units: 8_000)]
    #expect(abs(Calibration.unitsPerPercent(anchors, now: now)! - 100) < 1e-9)
}

@Test func fitIsWeightedTowardLargerPercentages() {
    // Sum(u*p)/Sum(p^2): (10*100 + 90*10000)/(100 + 8100) = 901000/8200 ~= 109.878
    let anchors = [anchor(percent: 10, units: 100),      // ratio 10
                   anchor(percent: 90, units: 10_000)]   // ratio 111.1
    let fit = Calibration.unitsPerPercent(anchors, now: now)!
    #expect(abs(fit - 109.878) < 0.01)
}

@Test func anchorsBelowFivePercentAreRejected() {
    let anchors = [anchor(percent: 3, units: 999_999)]
    #expect(Calibration.unitsPerPercent(anchors, now: now) == nil)
}

@Test func anchorsOlderThanSixtyDaysAreRejected() {
    let anchors = [anchor(percent: 50, units: 5_000, daysAgo: 61)]
    #expect(Calibration.unitsPerPercent(anchors, now: now) == nil)
}

@Test func staleAnchorsAreDroppedButFreshOnesSurvive() {
    let anchors = [anchor(percent: 50, units: 99_999, daysAgo: 61),
                   anchor(percent: 50, units: 5_000, daysAgo: 1)]
    #expect(abs(Calibration.unitsPerPercent(anchors, now: now)! - 100) < 1e-9)
}

@Test func onlyTheMostRecentEightAnchorsCount() {
    // Nine anchors: the oldest has a wildly different ratio and must be excluded.
    var anchors = (0..<8).map { anchor(percent: 50, units: 5_000, daysAgo: Double($0)) }
    anchors.append(anchor(percent: 50, units: 500_000, daysAgo: 20))
    #expect(abs(Calibration.unitsPerPercent(anchors, now: now)! - 100) < 1e-9)
    #expect(Calibration.validAnchors(anchors, now: now).count == 8)
}

@Test func zeroUnitAnchorsAreRejected() {
    #expect(Calibration.unitsPerPercent([anchor(percent: 50, units: 0)], now: now) == nil)
}

@Test func estimateIsNotCappedAtOneHundred() {
    let anchors = [anchor(percent: 50, units: 5_000)]
    let estimate = Calibration.estimatedPercent(unitsInWindow: 13_000, anchors: anchors, now: now)
    #expect(abs(estimate! - 130) < 1e-9)
}

@Test func ageReportsTheFreshestAnchor() {
    let anchors = [anchor(percent: 50, units: 5_000, daysAgo: 9),
                   anchor(percent: 50, units: 5_000, daysAgo: 2)]
    let age = Calibration.age(of: anchors, now: now)!
    #expect(abs(age - 2 * 86_400) < 1e-6)
}
