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
    #expect(p.cost?.totalCostUsd == nil)
}

@Test func toleratesUnknownKeys() throws {
    let p = try decode(#"{"future_field":{"nested":true},"model":{"display_name":"Haiku","extra":1}}"#)
    #expect(p.model?.displayName == "Haiku")
}

@Test func buildsACaptureFromAFullPayload() throws {
    let p = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":64,"resets_at":1786000000},"five_hour":{"used_percentage":3,"resets_at":1785000000}}}"#)
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
