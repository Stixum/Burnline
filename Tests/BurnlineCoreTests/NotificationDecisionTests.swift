import Foundation
import Testing
@testable import BurnlineCore

// Day 3 of a 7-day window (2 full days elapsed), target ≈ 28.6%.
private let windowStart = Date(timeIntervalSince1970: 1_800_000_000)
private let windowEnd = windowStart.addingTimeInterval(7 * 86_400)
private let now = windowStart.addingTimeInterval(2 * 86_400)

private func decisionSnapshot(estimate: Double?,
                              fiveHour: FiveHourStatus? = nil) -> Snapshot {
    let window = Window(start: windowStart, end: windowEnd, now: now)
    return Snapshot(window: window, targetPercent: window.targetPercent,
                    estimatedPercent: estimate, projectedPercent: nil,
                    unitsInWindow: 0, calibrationAge: nil,
                    source: estimate == nil ? .paceOnly : .live(capturedAt: now),
                    isScanning: false, fiveHour: fiveHour)
}

private let onSettings = NotificationSettings(
    enabled: true, behindPacePoints: 10, weeklyPercent: 90, fiveHourPercent: 80)

private func fiveHourAt(_ percent: Double, resetsIn: TimeInterval = 6_000) -> FiveHourStatus {
    FiveHourStatus(usedPercent: percent, resetsAt: now.addingTimeInterval(resetsIn),
                   timeRemaining: resetsIn)
}

@Test func decisionCrossingFiresOnceThenSuppresses() {
    // Target ~28.6, estimate 45 → 16.4 points behind: past the 10-point line.
    let snap = decisionSnapshot(estimate: 45)
    let first = NotificationDecision.evaluate(snapshot: snap, settings: onSettings,
                                              targetMode: .realTime,
                                              marks: NotificationMarks())
    #expect(first.emissions.map(\.signal) == [.behindPace])
    // Still above on the next evaluation: the mark suppresses.
    let second = NotificationDecision.evaluate(snapshot: snap, settings: onSettings,
                                               targetMode: .realTime,
                                               marks: first.marks)
    #expect(second.emissions.isEmpty)
    #expect(second.marks == first.marks)
}

@Test func decisionRearmsWhenTheWeeklyWindowRolls() {
    let snap = decisionSnapshot(estimate: 45)
    let fired = NotificationDecision.evaluate(snapshot: snap, settings: onSettings,
                                              targetMode: .realTime,
                                              marks: NotificationMarks()).marks
    // Same crossing, next window: the mark belongs to the old reset instant.
    let nextWindow = Window(start: windowEnd, end: windowEnd.addingTimeInterval(7 * 86_400),
                            now: windowEnd.addingTimeInterval(2 * 86_400))
    let nextSnap = Snapshot(window: nextWindow, targetPercent: nextWindow.targetPercent,
                            estimatedPercent: 45, projectedPercent: nil,
                            unitsInWindow: 0, calibrationAge: nil,
                            source: .live(capturedAt: nextWindow.now), isScanning: false)
    let next = NotificationDecision.evaluate(snapshot: nextSnap, settings: onSettings,
                                             targetMode: .realTime, marks: fired)
    #expect(next.emissions.map(\.signal) == [.behindPace])
}

@Test func decisionFiveHourMarkDiesWithItsOwnResetNotTheWeekly() {
    // Fire at 82%, then present the same percentage in the *next* 5-hour
    // window — same weekly window throughout.
    let snap1 = decisionSnapshot(estimate: nil, fiveHour: fiveHourAt(82))
    let fired = NotificationDecision.evaluate(snapshot: snap1, settings: onSettings,
                                              targetMode: .realTime,
                                              marks: NotificationMarks())
    #expect(fired.emissions.map(\.signal) == [.fiveHour])

    let snap2 = decisionSnapshot(estimate: nil,
                                 fiveHour: fiveHourAt(82, resetsIn: 6_000 + 5 * 3_600))
    let next = NotificationDecision.evaluate(snapshot: snap2, settings: onSettings,
                                             targetMode: .realTime, marks: fired.marks)
    #expect(next.emissions.map(\.signal) == [.fiveHour])

    // And the converse: the weekly mark does not suppress the 5-hour signal.
    #expect(fired.marks.weekly == nil)
    #expect(fired.marks.fiveHour != nil)
}

@Test func decisionWeeklyMarkSurvivesAFiveHourRoll() {
    // Both windows fire together; then the 5-hour window rolls forward while
    // the weekly window stays put. The 5-hour signal re-fires against its new
    // reset, and the weekly mark — keyed to the unchanged weekly reset —
    // still suppresses. The converse direction of
    // decisionFiveHourMarkDiesWithItsOwnResetNotTheWeekly.
    let snap1 = decisionSnapshot(estimate: 92, fiveHour: fiveHourAt(82))
    let fired = NotificationDecision.evaluate(snapshot: snap1, settings: onSettings,
                                              targetMode: .realTime,
                                              marks: NotificationMarks())
    #expect(fired.emissions.contains { $0.signal == .weekly })
    #expect(fired.emissions.contains { $0.signal == .fiveHour })

    let snap2 = decisionSnapshot(estimate: 92,
                                 fiveHour: fiveHourAt(82, resetsIn: 6_000 + 5 * 3_600))
    let next = NotificationDecision.evaluate(snapshot: snap2, settings: onSettings,
                                             targetMode: .realTime, marks: fired.marks)
    #expect(next.emissions.map(\.signal) == [.fiveHour])
}

@Test func decisionThresholdEditRearmsAndOscillationRefires() {
    let snap = decisionSnapshot(estimate: 92)   // over both weekly 90 and pace
    var settings = onSettings
    let at90 = NotificationDecision.evaluate(snapshot: snap, settings: settings,
                                             targetMode: .realTime,
                                             marks: NotificationMarks())
    #expect(at90.emissions.contains { $0.signal == .weekly })

    settings.weeklyPercent = 85                 // edit re-arms
    let at85 = NotificationDecision.evaluate(snapshot: snap, settings: settings,
                                             targetMode: .realTime, marks: at90.marks)
    #expect(at85.emissions.contains { $0.signal == .weekly })

    settings.weeklyPercent = 90                 // restore: recorded mark is now 85 → fires again.
    let back = NotificationDecision.evaluate(snapshot: snap, settings: settings,
                                             targetMode: .realTime, marks: at85.marks)
    #expect(back.emissions.contains { $0.signal == .weekly })
    // This third fire is the spec's accepted oscillation consequence, asserted
    // deliberately so nobody "fixes" it into silent-after-edit.
}

@Test func decisionPaceOnlySnapshotSilencesWeeklyAndPaceButNotFiveHour() {
    let snap = decisionSnapshot(estimate: nil, fiveHour: fiveHourAt(82))
    let result = NotificationDecision.evaluate(snapshot: snap, settings: onSettings,
                                               targetMode: .realTime,
                                               marks: NotificationMarks())
    #expect(result.emissions.map(\.signal) == [.fiveHour])
}

@Test func decisionAbsentFiveHourIsSilentAndWritesNoMark() {
    let snap = decisionSnapshot(estimate: 10)   // under every threshold
    let result = NotificationDecision.evaluate(snapshot: snap, settings: onSettings,
                                               targetMode: .realTime,
                                               marks: NotificationMarks())
    #expect(result.emissions.isEmpty)
    #expect(result.marks == NotificationMarks())
}

@Test func decisionMasterToggleOffEmitsNothingAndLeavesMarksAlone() {
    var off = onSettings
    off.enabled = false
    let existing = NotificationMarks(
        weekly: NotificationMarks.Mark(resetsAt: 1, threshold: 90))
    let result = NotificationDecision.evaluate(
        snapshot: decisionSnapshot(estimate: 99, fiveHour: fiveHourAt(99)),
        settings: off, targetMode: .realTime, marks: existing)
    #expect(result.emissions.isEmpty)
    #expect(result.marks == existing)
}

@Test func decisionEnableMidWindowAlreadyOverFiresImmediately() {
    // No previous-snapshot state: value past threshold + no mark = fire. This
    // is the correct first-run behavior, pinned here on purpose.
    let result = NotificationDecision.evaluate(
        snapshot: decisionSnapshot(estimate: 92),
        settings: onSettings, targetMode: .realTime, marks: NotificationMarks())
    #expect(result.emissions.count == 2)   // behind pace AND weekly
}

@Test func decisionDownwardCorrectionThenReclimbDoesNotRefire() {
    // Fire at 91, capture corrects to 88, extrapolation climbs back to 91:
    // the mark from the first fire still suppresses.
    let fired = NotificationDecision.evaluate(
        snapshot: decisionSnapshot(estimate: 91), settings: onSettings,
        targetMode: .realTime, marks: NotificationMarks()).marks
    let below = NotificationDecision.evaluate(
        snapshot: decisionSnapshot(estimate: 88), settings: onSettings,
        targetMode: .realTime, marks: fired)
    #expect(!below.emissions.contains { $0.signal == .weekly })
    let reclimb = NotificationDecision.evaluate(
        snapshot: decisionSnapshot(estimate: 91), settings: onSettings,
        targetMode: .realTime, marks: below.marks)
    #expect(!reclimb.emissions.contains { $0.signal == .weekly })
}

@Test func decisionUsesTheConfiguredTargetMode() {
    // Estimate 40 is ~11.4 points behind the real-time target (28.6%) but
    // ~2.9 AHEAD of the end-of-day target (day 3 allowance ≈ 42.9%), so the
    // mode genuinely changes the answer.
    let snap = decisionSnapshot(estimate: 40)
    let realTime = NotificationDecision.evaluate(snapshot: snap, settings: onSettings,
                                                 targetMode: .realTime,
                                                 marks: NotificationMarks())
    let endOfDay = NotificationDecision.evaluate(snapshot: snap, settings: onSettings,
                                                 targetMode: .endOfDay,
                                                 marks: NotificationMarks())
    #expect(realTime.emissions.contains { $0.signal == .behindPace })
    #expect(!endOfDay.emissions.contains { $0.signal == .behindPace })
}

@Test func decisionFiresExactlyAtEachThreshold() {
    // The contract is "at or past the threshold": a value landing EXACTLY on
    // the line must fire. Pins >= against a >-mutant that no other test catches.

    // Behind pace: the fixture's real-time target is exactly 2/7 × 100, so an
    // estimate of that plus the 10-point setting puts delta at exactly -10.
    // Computed from the same expression, not a decimal literal, so it's exact
    // (verified: delta == -10.0 bit-for-bit).
    let atPaceLine = NotificationDecision.evaluate(
        snapshot: decisionSnapshot(estimate: 200.0 / 7 + 10), settings: onSettings,
        targetMode: .realTime, marks: NotificationMarks())
    #expect(atPaceLine.emissions.contains { $0.signal == .behindPace })

    // Weekly: estimate exactly at the 90 setting.
    let atWeeklyLine = NotificationDecision.evaluate(
        snapshot: decisionSnapshot(estimate: 90), settings: onSettings,
        targetMode: .realTime, marks: NotificationMarks())
    #expect(atWeeklyLine.emissions.contains { $0.signal == .weekly })

    // Five-hour: the capture's figure exactly at the 80 setting.
    let atFiveHourLine = NotificationDecision.evaluate(
        snapshot: decisionSnapshot(estimate: nil, fiveHour: fiveHourAt(80)),
        settings: onSettings, targetMode: .realTime, marks: NotificationMarks())
    #expect(atFiveHourLine.emissions.contains { $0.signal == .fiveHour })
}

@Test func decisionBodyTextCarriesWordAndNumber() {
    let result = NotificationDecision.evaluate(
        snapshot: decisionSnapshot(estimate: 45), settings: onSettings,
        targetMode: .realTime, marks: NotificationMarks(),
        timeZone: TimeZone(identifier: "America/Chicago")!)
    let emission = result.emissions[0]
    #expect(emission.title == "Behind pace")
    #expect(emission.body.contains("16 points over target"))
    #expect(emission.body.contains("day 3 of 7"))
    #expect(emission.identifier == "burnline.behind-pace")
}
