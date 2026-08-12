import Testing
import Foundation
@testable import BurnlineCore

// MARK: - Staleness

/// A capture is exact when it lands and extrapolated from local tokens after.
/// Past an hour that extrapolation has had real time to drift — and it is blind
/// to any usage off this Mac — so the UI must stop styling it as authoritative.
@Test func aRecentCaptureIsFresh() {
    #expect(CaptureAge.isStale(30) == false)
    #expect(CaptureAge.isStale(59 * 60) == false)
}

@Test func aCaptureOlderThanAnHourIsStale() {
    #expect(CaptureAge.isStale(3_601))
    #expect(CaptureAge.isStale(8 * 3_600))
}

/// Exactly on the threshold is still fresh — staleness needs to be past it.
@Test func theStalenessThresholdItselfIsNotStale() {
    #expect(CaptureAge.isStale(CaptureAge.stalenessThreshold) == false)
}

/// No live capture at all is a different state, handled by `.calibrated` and
/// `.paceOnly`. It must not be reported as a stale capture.
@Test func noCaptureIsNotStale() {
    #expect(CaptureAge.isStale(nil) == false)
}

// MARK: - Description

@Test func aVeryRecentCaptureReadsAsJustNow() {
    #expect(CaptureAge.description(30) == "just now")
    #expect(CaptureAge.description(89) == "just now")
}

@Test func captureAgeReadsInMinutesUnderAnHour() {
    #expect(CaptureAge.description(90) == "1m ago")
    #expect(CaptureAge.description(45 * 60) == "45m ago")
}

@Test func captureAgeReadsInHoursUnderADay() {
    #expect(CaptureAge.description(3_600) == "1h ago")
    #expect(CaptureAge.description(23 * 3_600) == "23h ago")
}

@Test func captureAgeReadsInDaysBeyondThat() {
    #expect(CaptureAge.description(25 * 3_600) == "1d ago")
    #expect(CaptureAge.description(3 * 86_400) == "3d ago")
}

@Test func anAbsentCaptureAgeReadsAsNow() {
    #expect(CaptureAge.description(nil) == "now")
}

// MARK: - Why the figure stopped moving

/// Exceptions-only: nothing to explain while captures are landing.
@Test func aFreshCaptureNeedsNoExplanation() {
    #expect(CaptureAge.scarcityExplanation(60) == nil)
    #expect(CaptureAge.scarcityExplanation(nil) == nil)
}

/// The copy has to name the cause, not just the symptom. "3h ago" alone is what
/// made this read as a broken app rather than an idle one.
@Test func aStaleCaptureExplainsWhyAndWhatToDo() throws {
    let text = try #require(CaptureAge.scarcityExplanation(3 * 3_600))
    #expect(text.contains("3h"))
    #expect(text.lowercased().contains("terminal"))
    // The symptom phrasing must not leak the "ago" suffix mid-sentence.
    #expect(text.contains("ago") == false)
}

@Test func theScarcityThresholdMatchesTheStalenessThreshold() {
    #expect(CaptureAge.scarcityExplanation(CaptureAge.stalenessThreshold) == nil)
    #expect(CaptureAge.scarcityExplanation(CaptureAge.stalenessThreshold + 1) != nil)
}
