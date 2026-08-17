import Testing
import Foundation
@testable import BurnlineCore

// Fixed locale and zone, or every expectation below is a statement about the
// machine that ran it. `en_US_POSIX` is the one locale guaranteed not to drift.
private let fixedZone = TimeZone(identifier: "UTC")!
private let fixedLocale = Locale(identifier: "en_US_POSIX")

// Thursday 6 August 2026, 14:00 UTC — the shape of a real window bound.
private let labelWindowStart = Date(timeIntervalSince1970: 1_786_024_800)
private let labelWindowEnd = labelWindowStart.addingTimeInterval(7 * 86_400)

// MARK: - Units

@Test func unitsAreCompactedToTwoSignificantFigures() {
    // A real week is ~8.6 × 10⁹ weighted units. Printed in full that is a
    // twelve-digit number whose every digit past the first two is noise: the
    // absolute scale is meaningless by construction, because calibration
    // divides it out. The only comparison this figure supports is week to week.
    #expect(HistoryLabels.units(8_630_000_000) == "8.6B")
    #expect(HistoryLabels.units(25_944_053_814) == "25.9B")
    #expect(HistoryLabels.units(412_000_000) == "412M")
    #expect(HistoryLabels.units(9_300) == "9.3K")
    #expect(HistoryLabels.units(0) == "0")
}

@Test func unitsFromAHoledWindowAreMarkedAsAFloor() {
    // A window with a hole in its coverage is missing whatever was burned while
    // the app was not running. The archived tokens are real, so the total is a
    // lower bound — and a bare figure would present an unknown week as a
    // measured one, which is the exact confusion the coverage record exists to
    // prevent.
    #expect(HistoryLabels.units(8_630_000_000, isLowerBound: true) == "≥8.6B")
    #expect(HistoryLabels.units(8_630_000_000, isLowerBound: false) == "8.6B")
}

@Test func unitsSurviveAnOverflowedWeight() {
    // Weights come from a Settings text field and multiply token counts, so the
    // product can reach infinity with no attacker involved — the case
    // `DisplayValue` exists for. `String(format:)` would print `inf`.
    #expect(HistoryLabels.units(.infinity) == "—")
    #expect(HistoryLabels.units(.nan) == "—")
}

// MARK: - Window range

@Test func aWindowRangePrintsItsOwnEndDate() {
    // Bounds are half-open everywhere in this codebase: `end` IS the reset, and
    // the reset is the start of the next window. Printing it directly is
    // correct; subtracting a day to "fix" it would report the wrong week.
    let text = HistoryLabels.windowRange(start: labelWindowStart, end: labelWindowEnd,
                                         timeZone: fixedZone, locale: fixedLocale)
    #expect(text == "Aug 6 – Aug 13")
}

// MARK: - Final reading

@Test func aMissingPercentageReadsAsNotRecordedAndNeverAsZero() {
    // 🔴 THE test for this unit, and the state every window in the real archive
    // is in today. Percentages are Anthropic's own figure, recorded from now
    // on; no closed week has one on disk and none can be reconstructed. `0%`
    // would claim a week of no usage.
    let reading = HistoryLabels.finalReading(percent: nil, at: nil,
                                             windowEnd: labelWindowEnd,
                                             timeZone: fixedZone, locale: fixedLocale)

    #expect(!reading.isRecorded)
    #expect(reading.value == "—")
    #expect(reading.note == "not recorded")
    #expect(!reading.value.contains("0"))
}

@Test func aRecordedPercentageCarriesWhenItWasSeen() {
    // 🔴 A week where the laptop closed on Thursday holds Thursday's reading.
    // A bare `61%` claims a final figure the app never saw — the window ran
    // three more days after that number was minted.
    //
    // ⚠️ This branch cannot render on today's archive, so it cannot be caught
    // by looking at the window. The test is the only thing holding it up.
    let seen = labelWindowStart.addingTimeInterval(4 * 86_400)     // Monday, mid-window
    let reading = HistoryLabels.finalReading(percent: 61.4, at: seen,
                                             windowEnd: labelWindowEnd,
                                             timeZone: fixedZone, locale: fixedLocale)

    #expect(reading.isRecorded)
    #expect(reading.value == "61%")
    #expect(reading.note == "last seen Mon, Aug 10")
}

@Test func aReadingTakenAtTheResetIsFinal() {
    // The positive control for the test above: "carries its age" is only
    // meaningful if a genuinely final reading is not also being hedged. One
    // bucket is the archive's own resolution, so a reading inside the window's
    // last bucket is as final as anything here gets.
    let atReset = labelWindowEnd.addingTimeInterval(-60)
    let reading = HistoryLabels.finalReading(percent: 61, at: atReset,
                                             windowEnd: labelWindowEnd,
                                             timeZone: fixedZone, locale: fixedLocale)

    #expect(reading.value == "61%")
    #expect(reading.note == "at the reset")

    // And a bucket further out is not final.
    let earlier = labelWindowEnd.addingTimeInterval(-2 * Bucket.seconds)
    let hedged = HistoryLabels.finalReading(percent: 61, at: earlier,
                                            windowEnd: labelWindowEnd,
                                            timeZone: fixedZone, locale: fixedLocale)
    #expect(hedged.note.hasPrefix("last seen"))
}

@Test func aPercentageWithNoTimestampSaysSo() {
    // `WindowLedger` writes the two together, so this pairing means a
    // hand-edited or partially-decoded row. It must not silently render as a
    // final reading — the whole point of the note is that a figure without its
    // age is not one.
    let reading = HistoryLabels.finalReading(percent: 61, at: nil,
                                             windowEnd: labelWindowEnd,
                                             timeZone: fixedZone, locale: fixedLocale)

    #expect(reading.isRecorded)
    #expect(reading.value == "61%")
    #expect(reading.note == "time unknown")
}
