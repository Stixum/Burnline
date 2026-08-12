import Testing
import Foundation
@testable import BurnlineCore

// How often to refresh the anchor is a judgement about cost against precision,
// so it is a pure function with the reasoning in tests rather than a constant
// someone tunes by feel. One poll costs ~3.5 CPU-seconds and a 759 MB spike for
// ~27s, and no message quota at all.

private let relaxedInputs = (weekly: 20.0, fiveHour: 10.0, projected: 60.0)

@Test func theRelaxedIntervalStillNeverLetsTheFigureGoStale() {
    let interval = PollDecision.interval(weeklyPercent: relaxedInputs.weekly,
                                         fiveHourPercent: relaxedInputs.fiveHour,
                                         projectedPercent: relaxedInputs.projected,
                                         ceiling: .sixty)
    // Derived from the staleness threshold, not hardcoded: the anchor must be
    // refreshed before the UI would ever call it extrapolated, whatever that
    // threshold becomes.
    #expect(interval < CaptureAge.stalenessThreshold)
    #expect(interval == PollDecision.relaxed)
}

/// Any one of the three signals can be the binding constraint, so the worst wins.
@Test func pressureOnAnySignalShortensTheInterval() {
    let byWeekly = PollDecision.interval(weeklyPercent: 85, fiveHourPercent: 5,
                                         projectedPercent: 50, ceiling: .sixty)
    let byFiveHour = PollDecision.interval(weeklyPercent: 20, fiveHourPercent: 75,
                                           projectedPercent: 50, ceiling: .sixty)
    let byProjection = PollDecision.interval(weeklyPercent: 20, fiveHourPercent: 5,
                                             projectedPercent: 130, ceiling: .sixty)
    for interval in [byWeekly, byFiveHour, byProjection] {
        #expect(interval == PollDecision.elevated)
    }
}

/// The five-hour window is the one that bites soonest and is never extrapolated
/// between anchors, so it earns the tightest band on its own.
@Test func criticalPressureWinsOverEverythingElse() {
    #expect(PollDecision.interval(weeklyPercent: 95, fiveHourPercent: 5,
                                  projectedPercent: 50, ceiling: .sixty)
            == PollDecision.critical)
    #expect(PollDecision.interval(weeklyPercent: 10, fiveHourPercent: 93,
                                  projectedPercent: 50, ceiling: .sixty)
            == PollDecision.critical)
}

/// The setting is a ceiling, never a floor: it can make polling more frequent
/// but never less, so choosing it can't accidentally make the figure staler
/// than the pressure bands intend.
@Test func theCeilingOnlyEverTightens() {
    let relaxedAtFifteen = PollDecision.interval(weeklyPercent: relaxedInputs.weekly,
                                                 fiveHourPercent: relaxedInputs.fiveHour,
                                                 projectedPercent: relaxedInputs.projected,
                                                 ceiling: .fifteen)
    #expect(relaxedAtFifteen == 15 * 60)

    // Critical pressure is already tighter than any ceiling, so the ceiling
    // must not loosen it.
    let criticalAtSixty = PollDecision.interval(weeklyPercent: 95, fiveHourPercent: 95,
                                                projectedPercent: 200, ceiling: .sixty)
    #expect(criticalAtSixty == PollDecision.critical)
}

/// Early in a window there is no estimate and no projection. Missing signals
/// must not read as pressure, or a fresh window would poll at the tightest rate.
@Test func intervalIgnoresMissingSignalsRatherThanTreatingThemAsPressure() {
    #expect(PollDecision.interval(weeklyPercent: nil, fiveHourPercent: nil,
                                  projectedPercent: nil, ceiling: .sixty)
            == PollDecision.relaxed)
}

/// Nothing the user can choose exceeds an hour.
@Test func noCeilingOptionExceedsAnHour() {
    for option in RefreshInterval.allCases {
        #expect(option.seconds <= 3_600)
    }
}
