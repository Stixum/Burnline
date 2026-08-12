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

/// Absent on plans that don't report one, so the row must simply not render.
@Test func noScopedLimitMeansNoRow() {
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: .default,
                                         rateLimit: nil, now: Date(), isScanning: false)
    #expect(snapshot.scopedWeekly == nil)
}
