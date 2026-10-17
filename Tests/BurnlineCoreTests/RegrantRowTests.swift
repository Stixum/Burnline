import Testing
import AppKit
@testable import BurnlineCore

// The popover's re-grant row, measured rather than eyeballed. Geometry lives
// in `RowWidth`, shared with the extra-usage row.
private let rowBudget = RowWidth.symbolRowBudget

private func width(_ text: String, _ font: RowWidth.Font) -> Double {
    RowWidth.width(text, font)
}

/// Wednesday 12:59 PM in Chicago: 2026-09-02T17:59:00Z, the widest weekday and
/// clock combination `rowValue` can print.
private let widestInstant = Date(timeIntervalSince1970: 1_788_371_940)
private let chicago = TimeZone(identifier: "America/Chicago")!

@Test func theReGrantRowLabelIsOneWord() {
    #expect(Snapshot.Regrant.rowLabel == "Re-granted")
}

/// The label and the widest plausible value fit the popover row together.
///
/// Shipped as `Limits re-granted`, the row rendered `Fri 3:06 PM, opened at…`
/// on the real 2026-09-04 re-grant — the truncated half being the one that
/// makes the drop legible. Invisible in the source, obvious in a screenshot.
@Test func theReGrantRowFitsThePopoverAtItsWidestPlausibleValue() {
    let regrant = Snapshot.Regrant(startedAt: widestInstant, startPercent: 99)
    let value = regrant.rowValue(in: chicago)
    #expect(value == "Wed 12:59 PM, opened at 99%")
    #expect(width(Snapshot.Regrant.rowLabel, .label) + width(value, .digits) <= rowBudget)
}

/// Positive control: the budget rejects the pair that actually truncated. A
/// budget loose enough to admit it would make the test above prove nothing.
@Test func theRowBudgetRejectsThePairThatTruncated() {
    #expect(width("Limits re-granted", .label)
            + width("Fri 3:06 PM, opened at 0%", .digits) > rowBudget)
}
