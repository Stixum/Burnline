import Testing
import Foundation
@testable import BurnlineCore

private func snapshot(estimated: Double?, target: Double,
                      projected: Double? = nil,
                      fiveHour: FiveHourStatus? = nil,
                      scanning: Bool = false) -> Snapshot {
    let start = Date(timeIntervalSince1970: 0)
    let window = Window(start: start, end: start.addingTimeInterval(7 * 86_400),
                        now: start.addingTimeInterval(7 * 86_400 * target / 100))
    return Snapshot(window: window, targetPercent: target, estimatedPercent: estimated,
                    projectedPercent: projected, unitsInWindow: 0, calibrationAge: nil,
                    isScanning: scanning, fiveHour: fiveHour)
}

private func text(_ snapshot: Snapshot, _ display: MenuBarMode,
                  target: TargetMode = .realTime) -> String {
    MenuBarFormatter.text(for: snapshot, target: target, display: display)
}

// MARK: - Delta: + means over budget

/// `Snapshot.delta` is `target - estimate`, so positive means *under*. The menu
/// bar inverts it: on a usage meter a leading `+` reads as overspent.
@Test func deltaShowsAPlusWhenOverBudget() {
    #expect(text(snapshot(estimated: 90, target: 71), .delta) == "+19")
}

@Test func deltaShowsAMinusWhenUnderBudget() {
    #expect(text(snapshot(estimated: 40, target: 71), .delta) == "-31")
}

@Test func deltaExactlyOnPaceIsUnsigned() {
    #expect(text(snapshot(estimated: 71, target: 71), .delta) == "0")
}

/// The two settings stay orthogonal — "Compare against" still chooses which
/// target the delta is measured from.
@Test func deltaHonoursTheEndOfDayTarget() {
    let snap = snapshot(estimated: 64, target: 65)
    #expect(text(snap, .delta, target: .endOfDay) != text(snap, .delta, target: .realTime))
}

// MARK: - The other formats

@Test func usedOnlyShowsConsumptionAlone() {
    #expect(text(snapshot(estimated: 64.4, target: 65), .used) == "64%")
}

@Test func projectionShowsWhereTheWeekLands() {
    #expect(text(snapshot(estimated: 64, target: 65, projected: 98.6), .projection) == "99%")
}

@Test func fiveHourShowsTheShortWindow() {
    let five = FiveHourStatus(usedPercent: 3, resetsAt: Date(timeIntervalSince1970: 100),
                              timeRemaining: 4_200)
    #expect(text(snapshot(estimated: 64, target: 65, fiveHour: five), .fiveHour) == "3%")
}

@Test func usedOverTargetIsUnchanged() {
    #expect(text(snapshot(estimated: 40.4, target: 71.4), .usedOverTarget) == "40/71")
}

// MARK: - Empty states. The menu bar is four characters wide and must not invent.

/// Pace-only is a valid, documented state for the default format: the clock
/// target alone is the app this started as.
@Test func usedOverTargetStillFallsBackToTheBareTarget() {
    #expect(text(snapshot(estimated: nil, target: 71.4), .usedOverTarget) == "71")
}

/// Every other format needs a usage figure. Showing the target instead would be
/// read as usage.
@Test func formatsNeedingUsageShowADashWithoutIt() {
    let paceOnly = snapshot(estimated: nil, target: 71.4)
    #expect(text(paceOnly, .delta) == "—")
    #expect(text(paceOnly, .used) == "—")
    #expect(text(paceOnly, .projection) == "—")
    #expect(text(paceOnly, .fiveHour) == "—")
}

/// Below 2% elapsed the projection is suppressed at source.
@Test func aSuppressedProjectionShowsADash() {
    #expect(text(snapshot(estimated: 64, target: 65, projected: nil), .projection) == "—")
}

/// `five_hour` is absent on some plans.
@Test func anAbsentFiveHourShowsADash() {
    #expect(text(snapshot(estimated: 64, target: 65, fiveHour: nil), .fiveHour) == "—")
}

@Test func everyFormatShowsTheScanningEllipsis() {
    let scanning = snapshot(estimated: nil, target: 0, scanning: true)
    for mode in MenuBarMode.allCases {
        #expect(text(scanning, mode) == "…")
    }
}

// MARK: - Accessibility is not abbreviated

/// The visual is four characters; the spoken version has no such limit, so it
/// stays comprehensive whichever format is on screen.
@Test func accessibilitySpellsEverythingOutInEveryFormat() {
    let snap = snapshot(estimated: 40, target: 71)
    for mode in MenuBarMode.allCases {
        let label = MenuBarFormatter.accessibilityLabel(for: snap, target: .realTime, display: mode)
        #expect(label.contains("40"))
        #expect(label.contains("71"))
    }
}

@Test func accessibilityAddsTheFiveHourWhenThatFormatIsShown() {
    let five = FiveHourStatus(usedPercent: 3, resetsAt: Date(timeIntervalSince1970: 100),
                              timeRemaining: 4_200)
    let snap = snapshot(estimated: 40, target: 71, fiveHour: five)
    let label = MenuBarFormatter.accessibilityLabel(for: snap, target: .realTime, display: .fiveHour)
    #expect(label.lowercased().contains("5-hour"))
}

// MARK: - Settings copy

@Test func everyFormatHasSettingsCopy() {
    for mode in MenuBarMode.allCases {
        #expect(!mode.title.isEmpty)
        #expect(!mode.explanation.isEmpty)
    }
}
