import Testing
import Foundation
@testable import BurnlineCore

// `cachedUsageUtilization.seven_day_breakdown.window_started_at` is Anthropic's
// own statement of when the weekly window began. Observed 2026-11-24 it was
// exactly `resets_at − 604800 s`, to the microsecond, which is the 168-hour
// rule the app already derives. Reading it makes the start exact when the two
// agree and makes a disagreement visible when they do not.
//
// Every instant below was computed outside the code under test
// (`datetime.fromisoformat(…).timestamp()` in Python):
//   2026-12-04T07:00:00Z → 1796367600   (the reset)
//   2026-11-27T07:00:00Z → 1795762800   (168 hours earlier)
//   2026-11-27T06:00:00Z → 1795759200   (169 hours earlier)
//   2026-11-27T07:00:30Z → 1795762830   (30 seconds after the 168-hour start)

private let reset: TimeInterval = 1_796_367_600
private let ruleStart: TimeInterval = 1_795_762_800

/// Shaped from the real block observed 2026-11-24 (generic figures).
private func block(breakdown: String) -> String {
    """
    {"fetchedAtMs":1796000000000,
     "utilization":{
       "five_hour":null,
       "seven_day":{"utilization":22,"resets_at":"2026-12-04T07:00:00.305060+00:00"},
       "seven_day_breakdown":\(breakdown),
       "limits":[]}}
    """
}

private func decode(_ json: String) throws -> UsageUtilization {
    try JSONDecoder().decode(UsageUtilization.self, from: Data(json.utf8))
}

// MARK: - Decoding

@Test func theWindowStartIsReadFromTheBreakdownBesideItsReset() throws {
    let u = try decode(block(breakdown: """
        {"as_of":"2026-11-30T17:34:47.327407+00:00",
         "window_started_at":"2026-11-27T07:00:00.305060+00:00",
         "rows":[{"key":"claude_code","display_name":"Claude Code","percent":100,"percent_of_limit":22}]}
        """))
    let reported = try #require(u.weeklyWindowStart)
    // To the millisecond: the ISO8601 parser keeps three fractional digits.
    #expect(abs(reported.startedAt.timeIntervalSince1970 - (ruleStart + 0.305060)) < 0.001)
    #expect(abs(reported.resetsAt.timeIntervalSince1970 - (reset + 0.305060)) < 0.001)
    // And nothing else moved.
    #expect(u.sevenDay?.percent == 22)
}

@Test func anAbsentBreakdownReportsNoWindowStartAndCostsNothingElse() throws {
    let u = try decode("""
        {"fetchedAtMs":1796000000000,
         "utilization":{"seven_day":{"utilization":22,"resets_at":"2026-12-04T07:00:00Z"}}}
        """)
    #expect(u.weeklyWindowStart == nil)
    #expect(u.sevenDay?.percent == 22)
}

@Test(arguments: [
    #"null"#,
    #""2026-11-27T07:00:00Z""#,
    #"{"window_started_at":null}"#,
    #"{"window_started_at":1795762800}"#,
    #"{"window_started_at":"last Friday"}"#,
    #"{"window_started_at":"2026-11-27"}"#,
    #"{"rows":"nope"}"#,
])
func aMalformedBreakdownIsIgnoredAndTheReadingStillDecodes(breakdown: String) throws {
    let u = try decode(block(breakdown: breakdown))
    #expect(u.weeklyWindowStart == nil)
    #expect(u.sevenDay?.percent == 22)
}

/// A start has to be paired with the reset it was reported beside, or it
/// cannot be checked against anything. No weekly reading, no pairing.
@Test func aWindowStartWithNoWeeklyReadingIsNotReported() throws {
    let u = try decode("""
        {"fetchedAtMs":1796000000000,
         "utilization":{"seven_day":null,
           "seven_day_breakdown":{"window_started_at":"2026-11-27T07:00:00Z"}}}
        """)
    #expect(u.weeklyWindowStart == nil)
}

// MARK: - The check against the 168-hour rule

private func capture(resetsAt: TimeInterval, capturedAt: TimeInterval) -> RateLimitCapture {
    RateLimitCapture(version: RateLimitCapture.currentVersion, capturedAt: capturedAt,
                     sevenDay: .init(usedPercent: 22, resetsAt: resetsAt), fiveHour: nil)
}

private func reported(start: TimeInterval, resetsAt: TimeInterval = reset + 0.305)
    -> UsageUtilization.ReportedWindowStart {
    .init(startedAt: Date(timeIntervalSince1970: start),
          resetsAt: Date(timeIntervalSince1970: resetsAt))
}

private let now = Date(timeIntervalSince1970: reset - 3 * 86_400)

private func build(_ reported: UsageUtilization.ReportedWindowStart?,
                   capture: RateLimitCapture = capture(resetsAt: reset,
                                                       capturedAt: reset - 3 * 86_400 - 60))
    -> Snapshot {
    SnapshotBuilder.build(cache: ScanCache(), settings: .default, rateLimit: capture,
                          now: now, isScanning: false, reportedWindowStart: reported)
}

/// Agreement within the same minute the two sources already tolerate on a
/// reset: Anthropic's instant is the start, to the second it gives.
@Test func anAgreeingReportedStartIsTheWindowStart() {
    let snapshot = build(reported(start: 1_795_762_830))
    #expect(snapshot.window.start == Date(timeIntervalSince1970: 1_795_762_830))
    #expect(snapshot.window.end == Date(timeIntervalSince1970: reset))
    #expect(snapshot.windowStartCheck
            == .agrees(reportedStart: Date(timeIntervalSince1970: 1_795_762_830)))
}

/// The decision when they disagree: the 168-hour rule stands, and the
/// disagreement is carried on the snapshot for the probe to print. One reading
/// of a field nobody documents does not outweigh three months of archived
/// windows, all 168 hours; and the archive grid, the high-water mark and the
/// notification marks are all keyed to that rule.
@Test func aDisagreeingReportedStartIsRecordedAndThe168HourRuleStands() {
    let snapshot = build(reported(start: 1_795_759_200))
    #expect(snapshot.window.start == Date(timeIntervalSince1970: ruleStart))
    #expect(snapshot.window.end == Date(timeIntervalSince1970: reset))
    #expect(snapshot.windowStartCheck
            == .disagrees(reportedStart: Date(timeIntervalSince1970: 1_795_759_200),
                          ruleStart: Date(timeIntervalSince1970: ruleStart)))
}

/// A start reported beside a different reset describes a different window.
/// Here the capture is a dead one rolled forward a week, and the block still
/// describes the week that ended.
@Test func aReportedStartForAnotherWindowIsNotApplied() {
    let deadReset = reset - SnapshotBuilder.weekSeconds
    let snapshot = build(reported(start: ruleStart - SnapshotBuilder.weekSeconds + 30,
                                  resetsAt: deadReset),
                         capture: capture(resetsAt: deadReset, capturedAt: deadReset - 60))
    #expect(snapshot.window.start == Date(timeIntervalSince1970: ruleStart))
    #expect(snapshot.windowStartCheck == .notReported)
}

/// An absent field must change nothing: the whole snapshot is the one the
/// builder made before this field was read.
@Test func noReportedStartBuildsTheSameSnapshotAsBefore() {
    let without = SnapshotBuilder.build(cache: ScanCache(), settings: .default,
                                        rateLimit: capture(resetsAt: reset,
                                                           capturedAt: reset - 3 * 86_400 - 60),
                                        now: now, isScanning: false)
    let withNil = build(nil)
    #expect(withNil == without)
    #expect(withNil.window.start == Date(timeIntervalSince1970: ruleStart))
    #expect(withNil.windowStartCheck == .notReported)
}

/// Under the typed schedule there is no reset to pair a start with.
@Test func theTypedScheduleIgnoresAReportedStart() {
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: .default, rateLimit: nil,
                                         now: now, isScanning: false,
                                         reportedWindowStart: reported(start: 1_795_762_830))
    #expect(snapshot.windowStartCheck == .notReported)
    #expect(snapshot.isScheduleAutomatic == false)
}

/// The notification marks key on the window start (`NotificationDecision`'s
/// weekly epoch). An agreeing start may move it by up to the agreement
/// tolerance, so that tolerance must sit inside the one the marks compare
/// with, or one rebuild with the field and the next without it re-fires an
/// alert the user already had.
@Test func theAgreementToleranceSitsInsideTheNotificationEpochTolerance() {
    #expect(SnapshotBuilder.windowStartTolerance <= WindowLedger.sameResetTolerance)
}
