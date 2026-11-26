import Testing
import Foundation
@testable import BurnlineCore

// `~/.claude.json` carries a `cachedUsageUtilization` block: subscription usage
// in a plain local file, with an EXPLICIT fetch timestamp. Every dating
// heuristic in this project exists only because the statusline payload has no
// timestamp; this source needs none of them.
//
// It is a peer, never a replacement. It is an undocumented internal field that
// can change shape without notice, and it does not self-refresh — measured
// frozen for 5+ minutes during continuous desktop-session use.

/// Shaped from the real block observed 2026-08-12, null siblings and all.
private let realUtilization = """
{"fetchedAtMs":1786542556418,"accountUuid":"7d48fca5-1303-41f3-b219-eb0ad1170511",
 "utilization":{
   "five_hour":{"utilization":3,"resets_at":"2026-08-12T16:10:00.818605+00:00"},
   "seven_day":{"utilization":75,"resets_at":"2026-08-14T07:00:00.818653+00:00"},
   "seven_day_opus":null,"tangelo":null,
   "nimbus_quill":{"utilization":0,"resets_at":null},
   "limits":[
     {"kind":"session","group":"session","percent":3,"severity":"normal",
      "resets_at":"2026-08-12T16:10:00.818605+00:00","scope":null,"is_active":false},
     {"kind":"weekly_all","group":"weekly","percent":75,"severity":"warning",
      "resets_at":"2026-08-14T07:00:00.818653+00:00","scope":null,"is_active":true},
     {"kind":"weekly_scoped","group":"weekly","percent":2,"severity":"normal",
      "resets_at":"2026-08-14T06:59:59.818908+00:00",
      "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}}
"""

private func decodeUtilization(_ json: String) throws -> UsageUtilization {
    try JSONDecoder().decode(UsageUtilization.self, from: Data(json.utf8))
}

@Test func decodesTheRealUtilizationBlock() throws {
    let u = try decodeUtilization(realUtilization)
    #expect(u.sevenDay?.percent == 75)
    #expect(u.fiveHour?.percent == 3)
    #expect(u.fetchedAt == 1_786_542_556.418)
    #expect(u.accountUuid == "7d48fca5-1303-41f3-b219-eb0ad1170511")
}

/// The trap. `resets_at` carries SIX fractional digits, which only parses with
/// `.withFractionalSeconds`; a bare `Z` form only parses without it. One
/// formatter alone yields nil and the whole source goes dark with no error.
@Test func parsesSixDigitFractionalSecondsAndAlsoTheBarePlainForm() throws {
    #expect(try decodeUtilization(realUtilization).sevenDay?.resetsAt != nil)

    let plain = try decodeUtilization("""
    {"fetchedAtMs":1000,"utilization":{"seven_day":{"utilization":5,"resets_at":"2026-08-14T07:00:00Z"}}}
    """)
    #expect(plain.sevenDay?.resetsAt != nil)
}

/// `nimbus_quill` really is shaped like this today. A percentage with no window
/// boundary can never be judged valid, so it is dropped — the same rule
/// `StatuslinePayload` applies to a seven-day reading without `resets_at`.
@Test func aReadingWithNoResetInstantIsDropped() throws {
    let u = try decodeUtilization("""
    {"fetchedAtMs":1000,"utilization":{"seven_day":{"utilization":5,"resets_at":null}}}
    """)
    #expect(u.sevenDay == nil)
}

/// Most sibling keys are null today and are presumably populated on other
/// plans. One unknown shape must never cost the readings that did decode.
@Test func nullSiblingsAndUnknownKeysDoNotCostTheRealReadings() throws {
    let u = try decodeUtilization("""
    {"fetchedAtMs":1000,"utilization":{"seven_day_opus":null,"future_bucket":{"nope":1},
     "seven_day":{"utilization":50,"resets_at":"2026-08-14T07:00:00Z"}}}
    """)
    #expect(u.sevenDay?.percent == 50)
}

@Test func anAbsentUtilizationBlockDecodesToNothingRatherThanThrowing() throws {
    let u = try decodeUtilization(#"{"fetchedAtMs":1000}"#)
    #expect(u.sevenDay == nil)
    #expect(u.scopedWeekly == nil)
}

/// The per-model weekly figure the backlog had recorded as unobtainable. It was
/// missing from the statusline payload, not from the machine.
@Test func exposesTheScopedWeeklyLimitWithItsModelName() throws {
    let scoped = try #require(try decodeUtilization(realUtilization).scopedWeekly)
    #expect(scoped.percent == 2)
    #expect(scoped.modelName == "Fable")
    #expect(scoped.severity == "normal")
}

/// Converting into the existing capture shape is what lets this source flow
/// through selection and high-water with no changes to either.
@Test func convertsToACaptureDatedByItsOwnFetchTimestamp() throws {
    let capture = try #require(try decodeUtilization(realUtilization).asCapture())
    #expect(capture.sevenDay.usedPercent == 75)
    #expect(capture.capturedAt == 1_786_542_556.418)
    #expect(capture.fiveHour?.usedPercent == 3)
    // No session produced this reading, so nothing may try to date it from a
    // transcript — its own timestamp is already exact.
    #expect(capture.sessionId == nil)
    #expect(capture.transcriptPath == nil)
}

/// fetchedAtMs is the one honest timestamp in this system — every other
/// dating rule in the project is a heuristic that exists because the
/// statusline payload carries none.
@Test func theUtilizationSourceCarriesAProvenDate() throws {
    let utilization = try decodeUtilization(realUtilization)
    #expect(utilization.asCapture()?.provenAt == utilization.fetchedAt)
}

@Test func aBlockWithNoSevenDayYieldsNoCapture() throws {
    #expect(try decodeUtilization(#"{"fetchedAtMs":1000}"#).asCapture() == nil)
}

// MARK: - Competing with the statusline

private func statuslineCapture(_ percent: Double, at capturedAt: TimeInterval) -> RateLimitCapture {
    RateLimitCapture(version: RateLimitCapture.currentVersion, capturedAt: capturedAt,
                     sevenDay: .init(usedPercent: percent, resetsAt: 9_000_000_000),
                     fiveHour: nil, sessionId: "s", transcriptPath: nil)
}

private func utilizationCapture(_ percent: Double, fetchedAt: TimeInterval) throws
-> RateLimitCapture {
    try #require(try decodeUtilization("""
    {"fetchedAtMs":\(Int(fetchedAt * 1000)),
     "utilization":{"seven_day":{"utilization":\(percent),"resets_at":"2255-06-05T23:20:00Z"}}}
    """).asCapture())
}

/// The whole design: two sources, no precedence, age decides. Utilization knows
/// its own age exactly; a statusline capture's is derived.
@Test func utilizationWinsWhenItIsFresherThanTheStatuslineCapture() throws {
    let stale = statuslineCapture(70, at: 1_000)
    let fresh = try utilizationCapture(75, fetchedAt: 8_000)

    #expect(CaptureDirectory.freshest(of: [stale, fresh])?.sevenDay.usedPercent == 75)
}

/// And the converse, which matters because the utilization cache does NOT
/// self-refresh — it was measured frozen for 5+ minutes of continuous use.
@Test func theStatuslineCaptureWinsWhenTheUtilizationCacheIsStale() throws {
    let frozen = try utilizationCapture(70, fetchedAt: 1_000)
    let fresh = statuslineCapture(75, at: 8_000)

    #expect(CaptureDirectory.freshest(of: [frozen, fresh])?.sevenDay.usedPercent == 75)
}

// MARK: - Reaching the popover

/// The per-model weekly bar the backlog recorded as 🔴 impossible: "the only
/// faithful figure isn't obtainable". It was missing from the statusline
/// payload, not from the machine.
@Test func theSnapshotCarriesTheScopedWeeklyLimit() throws {
    let scoped = try #require(try decodeUtilization(realUtilization).scopedWeekly)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: .default,
                                         rateLimit: nil, now: Date(), isScanning: false,
                                         scopedWeekly: scoped)

    #expect(snapshot.scopedWeekly?.modelName == "Fable")
    #expect(snapshot.scopedWeekly?.rowValue == "2%")
}

/// 🔴 The row's label was the bare model name, in a column whose other labels
/// all name a period — `Day`, `Resets`, `Time left`, `5-hour`. `Fable` sitting
/// among those reads as a heading, and says nothing about which limit or over
/// what span. The period is the missing word, and it is assembled here because
/// no view body in this codebase formats.
@Test func theScopedRowNamesThePeriodAsWellAsTheModel() throws {
    let scoped = try #require(try decodeUtilization(realUtilization).scopedWeekly)

    #expect(scoped.rowLabel == "Fable weekly")
}

/// The label is derived from the reported name, never from a table of models
/// this app would then have to keep current.
@Test func theScopedRowLabelFollowsWhateverModelWasReported() {
    let limit = UsageUtilization.ScopedLimit(percent: 12, severity: "normal",
                                             modelName: "Opus", resetsAt: nil)

    #expect(limit.rowLabel == "Opus weekly")
}

/// Absent on plans that don't report one, so the row must simply not render.
@Test func noScopedLimitMeansNoRow() {
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: .default,
                                         rateLimit: nil, now: Date(), isScanning: false)
    #expect(snapshot.scopedWeekly == nil)
}

// MARK: - The `limits` fallback

// The block carries the weekly figure twice: `seven_day`, and a `limits` entry
// of kind `weekly_all`. About thirty of `seven_day`'s siblings were already
// null on 2026-11-21 while `limits` kept growing, so `seven_day` going the
// same way is the likely shape change — and with only `seven_day` read, every
// user would drop to pace-only with no error.

/// Shaped from the real block observed 2026-11-21, with `seven_day` nulled.
private let utilizationWithOnlyLimits = """
{"fetchedAtMs":1795289746321,
 "utilization":{
   "five_hour":null,"seven_day":null,"seven_day_opus":null,
   "limits":[
     {"kind":"weekly_all","group":"weekly","percent":25,"severity":"normal",
      "resets_at":"2026-11-27T07:00:00.258694+00:00","scope":null,"is_active":true}]}}
"""

@Test func theWeeklyFigureFallsBackToTheLimitsEntryWhenSevenDayIsNull() throws {
    let u = try decodeUtilization(utilizationWithOnlyLimits)
    #expect(u.sevenDay?.percent == 25)
    // To the millisecond: the ISO8601 parser keeps three fractional digits.
    let resetsAt = try #require(u.sevenDay?.resetsAt).timeIntervalSince1970
    #expect(abs(resetsAt - 1_795_762_800.258694) < 0.001)

    // And it reaches the pipeline as a proven capture, like `seven_day` does.
    let capture = try #require(u.asCapture())
    #expect(capture.sevenDay.usedPercent == 25)
    #expect(capture.provenAt == 1_795_289_746.321)
}

/// `seven_day` is the field with three months of history behind it. While it
/// is present it is the figure; the fallback never overrides it.
@Test func sevenDayWinsOverADisagreeingLimitsEntry() throws {
    let u = try decodeUtilization("""
    {"fetchedAtMs":1000,"utilization":{
      "seven_day":{"utilization":40,"resets_at":"2026-11-27T07:00:00Z"},
      "limits":[{"kind":"weekly_all","percent":99,"resets_at":"2026-12-04T07:00:00Z"}]}}
    """)
    #expect(u.sevenDay?.percent == 40)
    #expect(u.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_795_762_800))
}

/// The same rule as a `seven_day` with no boundary: a percentage that cannot
/// be placed in a window is dropped, not guessed at.
@Test func aWeeklyLimitsEntryWithNoResetInstantIsNotAFallback() throws {
    let u = try decodeUtilization("""
    {"fetchedAtMs":1000,"utilization":{"seven_day":null,
      "limits":[{"kind":"weekly_all","percent":25,"resets_at":null}]}}
    """)
    #expect(u.sevenDay == nil)
    #expect(u.asCapture() == nil)
}

/// The control: only `weekly_all` is the account-wide weekly figure. A session
/// limit or a per-model one must never stand in for it.
@Test func onlyTheWeeklyAllEntryCanStandInForSevenDay() throws {
    let u = try decodeUtilization("""
    {"fetchedAtMs":1000,"utilization":{"seven_day":null,
      "limits":[
        {"kind":"session","percent":3,"resets_at":"2026-11-21T20:00:00Z"},
        {"kind":"weekly_scoped","percent":8,"resets_at":"2026-11-27T07:00:00Z",
         "scope":{"model":{"display_name":"Fable"}}}]}}
    """)
    #expect(u.sevenDay == nil)
    #expect(u.scopedWeekly?.percent == 8)
}
