import Testing
import AppKit
@testable import BurnlineCore

// The popover's re-grant row, measured rather than eyeballed.
//
// `Sources/Burnline` has no test target, so the row's geometry is mirrored
// here from `PopoverView.regrantRow` and `Theme.popoverWidth`: a 300pt panel
// with 14pt padding each side, a 9pt symbol, three 5pt stack gaps, and a
// `Spacer` whose minimum length is the 8pt system default. What is left is the
// room the label and the value share.
private let rowBudget: Double = 300 - 2 * 14 - 9 - 3 * 5 - 8

// Built per call: `NSFont` is not `Sendable`, so a file-scope constant is
// refused under Swift 6.
private enum Font { case label, digits }

private func width(_ text: String, _ font: Font) -> Double {
    let resolved: NSFont = switch font {
    case .label: .systemFont(ofSize: 11.5)
    case .digits: .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    }
    return (text as NSString).size(withAttributes: [.font: resolved]).width
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
