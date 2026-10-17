import Testing
import Foundation
@testable import BurnlineCore

// The popover row, resolved in Core because `Sources/Burnline` has no tests.
// Ages are relative to `now`, never literal instants: a literal date plus any
// age rule is a test that fails by itself later.

private let now = Date()
private let chicago = TimeZone(identifier: "America/Chicago")!

private func row(_ state: UsageUtilization.ExtraUsage.State = .active,
                 used: Int = 1_240, limit: Int = 3_500, currency: String = "USD",
                 limitReached: Bool = false, severityRaised: Bool = false,
                 age: TimeInterval = 60) -> Snapshot.ExtraUsageRow? {
    let usage = UsageUtilization.ExtraUsage(
        state: state, usedMinor: used, limitMinor: limit, exponent: 2, currency: currency,
        isLimitReached: limitReached, isSeverityRaised: severityRaised,
        fetchedAt: now.addingTimeInterval(-age))
    return Snapshot.ExtraUsageRow(usage, now: now, timeZone: chicago)
}

@Test func anActiveExtraUsageRowReadsUsedOfLimit() {
    #expect(row()?.value == "$12.40 of $35")
    #expect(row()?.style == .plain)
    #expect(row(used: 0)?.value == "$0 of $35")
    #expect(row(currency: "EUR")?.value == "EUR 12.40 of 35")
    #expect(Snapshot.ExtraUsageRow.label == "Extra usage")
}

/// Strictly past the threshold, matching `CaptureAge.isStale`, and in
/// `CaptureAge.description`'s words — `6d ago`, never `144h ago`.
@Test func aStaleExtraUsageRowSaysHowOld() {
    #expect(row(age: 3_600)?.value == "$12.40 of $35")
    #expect(row(age: 3_601)?.value == "$12.40 of $35 · 1h ago")
    #expect(row(age: 6 * 86_400)?.value == "$12.40 of $35 · 6d ago")
}

@Test func anExtraUsageRowOlderThanAMonthlyCycleIsNotBuilt() {
    #expect(row(age: 31 * 86_400) != nil)
    #expect(row(age: 31 * 86_400 + 1) == nil)
}

@Test func anExtraUsageRowAtLimitNamesTheCap() {
    #expect(row(used: 3_500, limitReached: true)?.value == "$35 · limit reached")
    #expect(row(used: 3_500, limitReached: true)?.style == .warning)
}

/// A raised severity colours the row and claims nothing.
@Test func aRaisedSeverityExtraUsageRowIsAWarningWithoutAClaim() {
    let raised = row(severityRaised: true, age: 7_200)
    #expect(raised?.value == "$12.40 of $35")   // no suffix on a symbol row
    #expect(raised?.style == .warning)
}

@Test func aPausedExtraUsageRowIsMutedAndSaysWhy() {
    #expect(row(.paused(reason: "out of credits"))?.value == "paused · out of credits")
    #expect(row(.paused(reason: nil))?.value == "paused")
    #expect(row(.paused(reason: "out of credits"))?.style == .paused)
    #expect(row(.paused(reason: "out of credits"), age: 7_200)?.value == "paused · out of credits")
}

/// Precedence: paused, then at limit, then raised severity, then plain.
@Test func aPausedExtraUsageRowWinsOverAtLimit() {
    let both = row(.paused(reason: "out of credits"), used: 3_500, limitReached: true,
                   severityRaised: true)
    #expect(both?.style == .paused)
    #expect(both?.value == "paused · out of credits")
}

@Test func theExtraUsageTooltipSaysWhenAndWhatItIs() {
    // 2026-09-02T17:59:00Z, a Wednesday at 12:59 PM in Chicago.
    let usage = UsageUtilization.ExtraUsage(
        state: .active, usedMinor: 0, limitMinor: 3_500, exponent: 2, currency: "USD",
        isLimitReached: false, isSeverityRaised: false,
        fetchedAt: Date(timeIntervalSince1970: 1_788_371_940))
    let tip = Snapshot.ExtraUsageRow(usage, now: usage.fetchedAt.addingTimeInterval(60),
                                     timeZone: chicago)?.tooltip
    #expect(tip == "As of Wed 12:59 PM. Extra usage pays after you hit a plan limit; "
                 + "it doesn't change the weekly figure.")

    let paused = row(.paused(reason: "out of credits"))?.tooltip ?? ""
    #expect(paused.hasSuffix(" Turned off by Anthropic; you left it on."))
}

// MARK: - Width

/// The widest plausible values fit. `$9,999` at exponent 2 is the plausible
/// bound for a personal spend limit — the same convention as `RegrantRowTests`'
/// widest instant. The 99_999_999 ceiling exists to prevent a trap, not as a
/// width bound.
@Test func theWidestExtraUsageRowsFitThePopover() throws {
    let label = Snapshot.ExtraUsageRow.label
    let plain23h = try #require(row(used: 999_999, limit: 999_900, currency: "EUR", age: 23 * 3_600 + 60))
    #expect(plain23h.value == "EUR 9,999.99 of 9,999 · 23h ago")
    #expect(RowWidth.pair(label, plain23h.value) <= RowWidth.plainRowBudget)

    let plain31d = try #require(row(used: 999_999, limit: 999_900, currency: "EUR", age: 31 * 86_400))
    #expect(plain31d.value == "EUR 9,999.99 of 9,999 · 31d ago")
    #expect(RowWidth.pair(label, plain31d.value) <= RowWidth.plainRowBudget)

    let atLimit = try #require(row(used: 999_900, limit: 999_900, currency: "EUR", limitReached: true))
    #expect(atLimit.value == "EUR 9,999 · limit reached")
    #expect(RowWidth.pair(label, atLimit.value) <= RowWidth.symbolRowBudget)

    let raised = try #require(row(used: 999_999, limit: 999_900, currency: "EUR", severityRaised: true))
    #expect(RowWidth.pair(label, raised.value) <= RowWidth.symbolRowBudget)

    let paused = try #require(row(.paused(reason: "out of credits")))
    #expect(RowWidth.pair(label, paused.value) <= RowWidth.symbolRowBudget)
}

/// Positive controls: the budgets reject the two layouts this design avoided —
/// an age on a symbol row, and an uncapped age.
@Test func theExtraUsageRowBudgetsRejectTheLayoutsTheDesignAvoided() {
    let label = Snapshot.ExtraUsageRow.label
    #expect(RowWidth.pair(label, "paused · out of credits · 23h ago") > RowWidth.symbolRowBudget)
    #expect(RowWidth.pair(label, "EUR 9,999.99 of 9,999 · 999d ago") > RowWidth.plainRowBudget)
}
