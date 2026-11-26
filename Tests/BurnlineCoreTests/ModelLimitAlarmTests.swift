import Foundation
import Testing
@testable import BurnlineCore

// The per-model weekly limit (Fable, on Sean's plan) as a real limit, not a
// footnote. On 2026-11-26 Fable stood at 94% with Anthropic's own grading
// `critical` while the all-models figure Burnline tracks read 74% `normal`:
// the limit about to stop work was a plain grey row, the refresh slowed to its
// 45-minute band, and nothing notified. Sean chose (2026-11-26): colour and
// mark the row by Anthropic's severity, refresh on the higher of the two
// figures, and notify on warning and critical.

// MARK: - Fixtures

// Day 6 of a 7-day window, the shape of the 2026-11-26 evening.
private let alarmWindowStart = Date(timeIntervalSince1970: 1_800_000_000)
private let alarmWindowEnd = alarmWindowStart.addingTimeInterval(7 * 86_400)
private let alarmNow = alarmWindowStart.addingTimeInterval(6 * 86_400)
private let chicago = TimeZone(identifier: "America/Chicago")!

private func fable(_ percent: Double, _ severity: String,
                   resetsAt: Date? = alarmWindowEnd) -> UsageUtilization.ScopedLimit {
    UsageUtilization.ScopedLimit(percent: percent, severity: severity, modelName: "Fable",
                                 resetsAt: resetsAt)
}

private func alarmSnapshot(_ scoped: UsageUtilization.ScopedLimit?,
                           regrant: Snapshot.Regrant? = nil) -> Snapshot {
    let window = Window(start: alarmWindowStart, end: alarmWindowEnd, now: alarmNow)
    return Snapshot(window: window, targetPercent: window.targetPercent,
                    estimatedPercent: 74, projectedPercent: nil,
                    unitsInWindow: 0, calibrationAge: nil,
                    source: .live(capturedAt: alarmNow), isScanning: false,
                    scopedWeekly: scoped, regrant: regrant)
}

// Thresholds the all-models figure (74) does not reach, so only the model
// signal can fire.
private let notificationsOn = NotificationSettings(
    enabled: true, behindPacePoints: 100, weeklyPercent: 99, fiveHourPercent: 99)

private func evaluate(_ snapshot: Snapshot, marks: NotificationMarks = NotificationMarks(),
                      settings: NotificationSettings = notificationsOn)
-> (emissions: [NotificationDecision.Emission], marks: NotificationMarks) {
    NotificationDecision.evaluate(snapshot: snapshot, settings: settings,
                                  targetMode: .realTime, marks: marks, timeZone: chicago)
}

// MARK: - The popover row

@Test func aCriticalModelLimitIsDrawnAsCriticalWithTheWord() {
    let limit = fable(94, "critical")
    #expect(limit.rowStyle == .critical)
    #expect(limit.rowValue == "94% · critical")
}

@Test func aWarningModelLimitIsDrawnAsAWarningWithTheWord() {
    let limit = fable(81, "warning")
    #expect(limit.rowStyle == .warning)
    #expect(limit.rowValue == "81% · warning")
}

@Test func aNormalModelLimitStaysAPlainRow() {
    let limit = fable(12, "normal")
    #expect(limit.rowStyle == .plain)
    #expect(limit.rowValue == "12%")
}

@Test func anUnfamiliarRaisedSeverityIsTreatedAsAWarning() {
    // The same rule as extra usage: anything but "normal" is raised. A grade
    // this build has never seen is still Anthropic saying "look at this".
    let limit = fable(60, "Elevated")
    #expect(limit.rowStyle == .warning)
    #expect(limit.rowValue == "60% · elevated")
}

@Test func theModelLimitTooltipSaysItStopsOnItsOwn() {
    let help = fable(94, "critical").rowHelp
    #expect(help.contains("Anthropic grades this limit critical"))
    #expect(help.contains("Fable stops at its own limit"))
}

@Test func theWidestModelLimitRowFitsThePopover() {
    // Drawn as a symbol row when raised: 240pt for label and value together.
    let widest = UsageUtilization.ScopedLimit(percent: 100, severity: "critical",
                                              modelName: "Opus 5.5", resetsAt: nil)
    #expect(RowWidth.pair(widest.rowLabel, widest.rowValue) <= RowWidth.symbolRowBudget)
}

private let sean2026_11_26 = """
{"fetchedAtMs":1795732484464,"utilization":{
 "seven_day":{"utilization":74,"resets_at":"2026-11-27T07:00:00.403111+00:00"},
 "limits":[
  {"kind":"weekly_all","group":"weekly","percent":74,"severity":"normal",
   "resets_at":"2026-11-27T07:00:00.403111+00:00","scope":null,"is_active":false},
  {"kind":"weekly_scoped","group":"weekly","percent":94,"severity":"critical",
   "resets_at":"2026-11-27T07:00:00.403273+00:00",
   "scope":{"model":{"display_name":"Fable"}},"is_active":true}]}}
"""

@Test func theModelLimitKeepsItsSeverityAndResetInstant() throws {
    let utilization = try JSONDecoder().decode(UsageUtilization.self,
                                               from: Data(sean2026_11_26.utf8))
    let scoped = try #require(utilization.scopedWeekly)
    #expect(scoped.rowStyle == .critical)
    let reset = try #require(scoped.resetsAt)
    #expect(abs(reset.timeIntervalSince1970 - 1_795_762_800.403) < 0.01)
}

// MARK: - The refresh

@Test func aCriticalModelLimitRefreshesAtTheCriticalRate() {
    // 2026-11-26: all models 74 (the 45-minute band), Fable 94.
    #expect(PollDecision.interval(weeklyPercent: 74, fiveHourPercent: nil,
                                  scopedWeeklyPercent: 94, projectedPercent: nil,
                                  ceiling: .sixty) == PollDecision.critical)
}

@Test func aModelLimitBelowTheWeeklyFigureChangesNothing() {
    #expect(PollDecision.interval(weeklyPercent: 85, fiveHourPercent: nil,
                                  scopedWeeklyPercent: 10, projectedPercent: nil,
                                  ceiling: .sixty) == PollDecision.elevated)
}

// MARK: - The notification

@Test func aCriticalModelLimitNotifiesOnceWithItsNameAndReset() {
    let snapshot = alarmSnapshot(fable(94, "critical"))
    let first = evaluate(snapshot)
    #expect(first.emissions.map(\.signal) == [.modelWeekly])
    #expect(first.emissions.first?.title == "Fable weekly limit at 94%")
    let reset = NotificationDecision.resetDescription(alarmWindowEnd, timeZone: chicago)
    #expect(first.emissions.first?.body
            == "Anthropic grades it critical. Resets \(reset).")

    let second = evaluate(snapshot, marks: first.marks)
    #expect(second.emissions.isEmpty)
}

@Test func aWarningThenCriticalNotifiesForEachButNotOnTheWayBackDown() {
    let warned = evaluate(alarmSnapshot(fable(81, "warning")))
    #expect(warned.emissions.map(\.signal) == [.modelWeekly])

    let critical = evaluate(alarmSnapshot(fable(93, "critical")), marks: warned.marks)
    #expect(critical.emissions.map(\.signal) == [.modelWeekly])

    // A reading graded lower again (two sources, or a regrading) says nothing
    // new: the critical alert already went out this allowance.
    let back = evaluate(alarmSnapshot(fable(91, "warning")), marks: critical.marks)
    #expect(back.emissions.isEmpty)
}

@Test func aNormalModelLimitNeverNotifies() {
    #expect(evaluate(alarmSnapshot(fable(40, "normal"))).emissions.isEmpty)
}

@Test func theMasterSwitchSilencesTheModelLimitToo() {
    var off = notificationsOn
    off.enabled = false
    #expect(evaluate(alarmSnapshot(fable(94, "critical")), settings: off).emissions.isEmpty)
}

@Test func aModelLimitFromAnotherWindowDoesNotNotify() {
    // A cached block from a week that has ended, or one with no reset: neither
    // can be placed in the window on screen.
    let lastWeek = fable(94, "critical", resetsAt: alarmWindowStart)
    #expect(evaluate(alarmSnapshot(lastWeek)).emissions.isEmpty)
    let undated = fable(94, "critical", resetsAt: nil)
    #expect(evaluate(alarmSnapshot(undated)).emissions.isEmpty)
}

@Test func aModelLimitReportedASecondOffTheWindowEndStillNotifies() {
    // The two figures' `resets_at` differ in the sixth decimal; the
    // all-models one is often a second short of the hour.
    let close = fable(94, "critical", resetsAt: alarmWindowEnd.addingTimeInterval(-0.6))
    #expect(evaluate(alarmSnapshot(close)).emissions.map(\.signal) == [.modelWeekly])
}

@Test func aReGrantReArmsTheModelLimitAlert() {
    let fired = evaluate(alarmSnapshot(fable(94, "critical")))
    let regrant = Snapshot.Regrant(startedAt: alarmNow.addingTimeInterval(-3_600),
                                   startPercent: 1)
    let after = evaluate(alarmSnapshot(fable(95, "critical"), regrant: regrant),
                         marks: fired.marks)
    #expect(after.emissions.map(\.signal) == [.modelWeekly])
}

@Test func marksWrittenBeforeTheModelSignalStillLoad() throws {
    let v2 = #"{"version":2,"weekly":{"resetsAt":1800604800,"threshold":90,"epochStartedAt":1800000000}}"#
    let marks = try JSONDecoder().decode(NotificationMarks.self, from: Data(v2.utf8))
    #expect(marks.isCompatible)
    #expect(marks.weekly?.threshold == 90)
    #expect(marks.modelWeekly == nil)
}
