import Testing
import Foundation
@testable import BurnlineCore

private func decode(_ json: String) throws -> StatuslinePayload {
    try JSONDecoder().decode(StatuslinePayload.self, from: Data(json.utf8))
}

@Test func decodesAFullPayload() throws {
    let p = try decode("""
    {"model":{"display_name":"Opus 5"},
     "workspace":{"current_dir":"/Users/x/Projects/Burnline"},
     "context_window":{"used_percentage":42.7},
     "cost":{"total_cost_usd":1.2345},
     "rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000},
                    "five_hour":{"used_percentage":3,"resets_at":1785000000}}}
    """)
    #expect(p.model?.displayName == "Opus 5")
    #expect(p.workspace?.currentDir == "/Users/x/Projects/Burnline")
    #expect(p.contextWindow?.usedPercentage == 42.7)
    #expect(p.cost?.totalCostUsd == 1.2345)
    #expect(p.rateLimits?.sevenDay?.usedPercentage == 64)
    #expect(p.rateLimits?.fiveHour?.resetsAt == 1785000000)
}

@Test func decodesAnEmptyObject() throws {
    let p = try decode("{}")
    #expect(p.model == nil)
    #expect(p.rateLimits == nil)
}

@Test func decodesWithRateLimitsAbsent() throws {
    let p = try decode(#"{"model":{"display_name":"Sonnet 5"}}"#)
    #expect(p.model?.displayName == "Sonnet 5")
    #expect(p.rateLimits == nil)
}

@Test func decodesPayloadWithFiveHourAbsent() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}"#)
    #expect(p.rateLimits?.sevenDay?.usedPercentage == 64)
    #expect(p.rateLimits?.fiveHour == nil)
}

@Test func decodesWithExplicitNulls() throws {
    let p = try decode(#"{"model":null,"cost":{"total_cost_usd":null}}"#)
    #expect(p.model == nil)
    #expect(p.cost != nil)
    #expect(p.cost?.totalCostUsd == nil)
}

@Test func toleratesUnknownKeys() throws {
    let p = try decode(#"{"future_field":{"nested":true},"model":{"display_name":"Haiku","extra":1}}"#)
    #expect(p.model?.displayName == "Haiku")
}

/// The five-hour reset sits *after* `capturedAt`, as it must in a genuinely
/// fresh payload — a five-hour window that had already expired would date the
/// payload as a replay and pull `capturedAt` back. See
/// `theHelperDatesARepublishedPayloadHonestlyInsteadOfStampingItNow`.
@Test func buildsACaptureFromAFullPayload() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000},"five_hour":{"used_percentage":3,"resets_at":1785910000}}}"#)
    let capture = try #require(p.capture(capturedAt: 1_785_900_000))
    #expect(capture.version == RateLimitCapture.currentVersion)
    #expect(capture.capturedAt == 1_785_900_000)
    #expect(capture.sevenDay.usedPercent == 64)
    #expect(capture.sevenDay.resetsAt == 1_786_000_000)
    #expect(capture.fiveHour?.usedPercent == 3)
}

@Test func noCaptureWithoutRateLimits() throws {
    #expect(try decode("{}").capture(capturedAt: 1) == nil)
}

@Test func noCaptureWhenSevenDayResetsAtIsMissing() throws {
    // A percentage with no window boundary cannot be evaluated for validity
    // later, so it is worse than no capture at all.
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64}}}"#)
    #expect(p.capture(capturedAt: 1) == nil)
}

@Test func fiveHourWithoutResetsAtIsDroppedNotFatal() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000},"five_hour":{"used_percentage":3}}}"#)
    let capture = try #require(p.capture(capturedAt: 1))
    #expect(capture.sevenDay.usedPercent == 64)
    #expect(capture.fiveHour == nil)
}

// MARK: - A malformed cosmetic field must cost only itself (Fix 2)

@Test func numericModelDisplayNameStillYieldsACaptureAndRendersRateLimits() throws {
    let p = try decode(#"{"model":{"display_name":123},"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786690800}}}"#)
    #expect(p.model?.displayName == nil)
    let capture = try #require(p.capture(capturedAt: 1))
    #expect(capture.sevenDay.usedPercent == 64)
    #expect(StatusLineRenderer.render(p) == "week 64%")
}

@Test func malformedFiveHourStillYieldsTheSevenDayCapture() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000},"five_hour":"nope"}}"#)
    #expect(p.rateLimits?.fiveHour == nil)
    let capture = try #require(p.capture(capturedAt: 1))
    #expect(capture.sevenDay.usedPercent == 64)
    #expect(capture.fiveHour == nil)
}

@Test func stringSevenDayUsedPercentageYieldsNoCaptureWithoutThrowing() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":"lots","resets_at":1786000000}}}"#)
    #expect(p.rateLimits?.sevenDay?.usedPercentage == nil)
    #expect(p.capture(capturedAt: 1) == nil)
}

@Test func topLevelArrayStillThrows() {
    #expect(throws: (any Error).self) {
        try decode("[1,2,3]")
    }
}

@Test func decodesTheSessionIdAndTranscriptPath() throws {
    let p = try decode(#"{"session_id":"abc-123","transcript_path":"/tmp/abc-123.jsonl"}"#)
    #expect(p.sessionId == "abc-123")
    #expect(p.transcriptPath == "/tmp/abc-123.jsonl")
}

/// Per-property decoding, like every other field: a wrong-typed session_id must
/// not cost us rate_limits.
@Test func aNumericSessionIdDoesNotCostTheRateLimits() throws {
    let p = try decode(#"{"session_id":123,"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}"#)
    #expect(p.sessionId == nil)
    #expect(p.rateLimits?.sevenDay?.usedPercentage == 64)
}

@Test func theCaptureCarriesTheSessionThatProducedIt() throws {
    let p = try decode(#"{"session_id":"abc","transcript_path":"/tmp/abc.jsonl","rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}"#)
    let capture = try #require(p.capture(capturedAt: 1_785_900_000))
    #expect(capture.sessionId == "abc")
    #expect(capture.transcriptPath == "/tmp/abc.jsonl")
}

/// The documented fields have never been observed at runtime. Their absence
/// must cost the mint time and nothing else.
@Test func aPayloadWithoutSessionFieldsStillProducesACapture() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000}}}"#)
    let capture = try #require(p.capture(capturedAt: 1_785_900_000))
    #expect(capture.sessionId == nil)
    #expect(capture.transcriptPath == nil)
}
