import Testing
import Foundation
@testable import BurnlineCore

// Which weeks the History window overlays, and — the part that had no home
// before this — which ramp position each one holds.
//
// 🔴 The rule was written twice inside `HistoryLoader`, once per chart, in a
// target with no tests. Both copies assigned colour by position in their own
// DRAWN array, and the two arrays are filtered independently: a week can hold
// transcript cells and no capture readings, or readings and no cells. These
// pin the property that makes the toggle honest — a week is the same colour on
// both faces, and dropping one never renumbers the rest.

private let fixedZone = TimeZone(identifier: "UTC")!
private let fixedLocale = Locale(identifier: "en_US_POSIX")

private let sevenDays: TimeInterval = 7 * 86_400
// Thursday 27 August 2026, 14:00 UTC — the live window's start.
private let liveStart = Date(timeIntervalSince1970: 1_787_839_200)
private let liveEnd = liveStart.addingTimeInterval(sevenDays)

private func window(startingWeeksBack weeks: Int) -> WindowRow {
    let start = liveStart.addingTimeInterval(-Double(weeks) * sevenDays)
    return WindowRow(start: start, end: start.addingTimeInterval(sevenDays), counts: .zero,
                     finalPercent: nil, finalPercentAt: nil, finalPercentSource: nil,
                     boundsSource: .schedule, observedResetsAt: nil)
}

private func slots(_ windows: [WindowRow]) -> [HistoryOverlay.Slot] {
    HistoryOverlay.slots(currentStart: liveStart, currentEnd: liveEnd, windows: windows,
                         timeZone: fixedZone, locale: fixedLocale)
}

// MARK: - The ramp position is recency

@Test func theLiveWindowAlwaysHoldsTheNewestRampPosition() {
    // Slot 0 is the live window whether or not either chart has anything to
    // draw for it. Reserving the position is the whole mechanism: violet means
    // *now*, and nothing else may inherit it.
    let overlay = slots([window(startingWeeksBack: 1), window(startingWeeksBack: 2)])
    #expect(overlay.count == 3)
    #expect(overlay[0].rampIndex == 0)
    #expect(overlay[0].isCurrent)
    #expect(overlay[0].label == HistoryOverlay.currentWeekLabel)
    #expect(overlay.dropFirst().allSatisfy { !$0.isCurrent })
}

@Test func aRampPositionIsAPositionInTheFullListNotInAnythingDrawn() {
    // The contract, stated. Every consumer filters, and every consumer must
    // carry this through rather than re-deriving it.
    let overlay = slots([window(startingWeeksBack: 1), window(startingWeeksBack: 2)])
    #expect(overlay.enumerated().allSatisfy { $0.offset == $0.element.rampIndex })
}

@Test func droppingTheLiveWeekNeverPromotesAPriorToViolet() {
    // 🔴 The defect this refactor exists for, and it is reachable every week.
    // `HistoryLoader.curves` omits the live window while it has one point or
    // fewer — the first quarter-hour after a reset, and any time before the
    // first scan lands. Under array-position colouring the first prior then
    // takes index 0 and the ramp paints it violet: "this is now" about a week
    // that ended.
    //
    // The positive control is the mutation: implement `rampIndex` as the offset
    // within the drawn array and the first expectation below reads 0.
    let overlay = slots([window(startingWeeksBack: 1), window(startingWeeksBack: 2)])
    let drawn = overlay.filter { !$0.isCurrent }          // the live week had nothing

    #expect(drawn.map(\.rampIndex) == [1, 2])
    #expect(!drawn.contains { $0.rampIndex == 0 })
}

@Test func droppingAMiddleWeekDoesNotSlideTheOldestForward() {
    // The same rule from the other side: a prior with no readings leaves a HOLE
    // in the ramp rather than closing it up. The oldest week keeps the dimmest
    // grey it earned, so its colour still means "two weeks ago".
    let overlay = slots([window(startingWeeksBack: 1), window(startingWeeksBack: 2)])
    let drawn = overlay.filter { $0.rampIndex != 1 }
    #expect(drawn.map(\.rampIndex) == [0, 2])
}

@Test func bothChartsAgreeOnEveryWeekTheyBothDraw() {
    // The toggle's premise: the same weeks, the same labels, the same colours on
    // both faces. Two charts filtering the ONE list differently — units keeps
    // the live week and loses a prior, percent the reverse — must still agree
    // about every week they have in common.
    let overlay = slots([window(startingWeeksBack: 1), window(startingWeeksBack: 2)])
    let unitsDrawn = overlay.filter { $0.rampIndex != 1 }
    let percentDrawn = overlay.filter { !$0.isCurrent }

    let shared = Set(unitsDrawn.map(\.label)).intersection(percentDrawn.map(\.label))
    #expect(!shared.isEmpty)
    for label in shared {
        let fromUnits = unitsDrawn.first { $0.label == label }
        let fromPercent = percentDrawn.first { $0.label == label }
        #expect(fromUnits == fromPercent)
        #expect(fromUnits?.rampIndex == fromPercent?.rampIndex)
    }
}

// MARK: - Which weeks

@Test func atMostThreeWeeksAreEverOverlaid() {
    // ⚠️ Two priors, not three, and the cap is a CONTRAST decision rather than a
    // layout one: the next step down `Theme.curveRamp` measures 2.94:1 against
    // the window background, under the 3:1 floor a graphical mark has to clear.
    // A fourth series needs a different encoding, not a fourth grey.
    let overlay = slots((1...6).map { window(startingWeeksBack: $0) })
    #expect(overlay.count == HistoryOverlay.capacity)
    #expect(HistoryOverlay.capacity == 3)
    #expect(overlay.map(\.rampIndex) == [0, 1, 2])
}

@Test func priorsAreNewestFirstWhateverOrderTheArchiveHeldThem() {
    // `loadWindows` keeps any line that decodes out of an append-only file, so
    // archive order is not a guarantee. Trusting it hands "second newest" to
    // whichever week happened to be written first — and recency is the entire
    // meaning of the colour.
    let ordered = slots([window(startingWeeksBack: 1), window(startingWeeksBack: 2),
                         window(startingWeeksBack: 3)])
    let jumbled = slots([window(startingWeeksBack: 3), window(startingWeeksBack: 1),
                         window(startingWeeksBack: 2)])
    #expect(ordered == jumbled)
    #expect(ordered[1].start > ordered[2].start)
}

@Test func aRowForTheWindowInProgressIsNotDrawnBesideItself() {
    // The flush can land a row either side of a reset, so a row whose start is
    // the live window's own is reachable. Admitted, it draws this week twice —
    // once violet as "This week" and once grey under a date range.
    let overlay = slots([WindowRow(start: liveStart, end: liveEnd, counts: .zero,
                                   finalPercent: nil, finalPercentAt: nil,
                                   finalPercentSource: nil, boundsSource: .schedule,
                                   observedResetsAt: nil),
                         window(startingWeeksBack: 1)])
    #expect(overlay.count == 2)
    #expect(overlay[0].isCurrent)
    #expect(overlay[1].start == liveStart.addingTimeInterval(-sevenDays))
}

@Test func twoRowsClaimingOneStartCostNoRealPriorItsPlace() {
    // Duplicate starts are a corrupt archive, not two weeks. Drawn as-is they
    // are one week in two colours, and — because the overlay is capped at three
    // — the second copy silently evicts a genuine prior.
    let duplicated = [window(startingWeeksBack: 1), window(startingWeeksBack: 1),
                      window(startingWeeksBack: 2)]
    let overlay = slots(duplicated)
    #expect(overlay.count == 3)
    #expect(Set(overlay.map(\.start)).count == 3)
    #expect(overlay[2].start == liveStart.addingTimeInterval(-2 * sevenDays))
}

@Test func theLiveWindowIsOfferedEvenWithAnEmptyArchive() {
    // The common first-run state: no window has closed, so there is no row to
    // read, and the live week is still the one a reader came for.
    let overlay = slots([])
    #expect(overlay.count == 1)
    #expect(overlay[0].isCurrent)
    #expect(overlay[0].start == liveStart)
    #expect(overlay[0].end == liveEnd)
}

@Test func aPriorCarriesItsDateRangeAndTheLiveWeekNeverDoes() {
    // Identity is carried in text on both charts, so the label is the same
    // string in the legend, in the direct end label and in the scoreboard — and
    // the live window has no `WindowRow` to name it from.
    let overlay = slots([window(startingWeeksBack: 1)])
    #expect(overlay[0].label == "This week")
    #expect(overlay[1].label == HistoryLabels.windowRange(
        start: liveStart.addingTimeInterval(-sevenDays), end: liveStart,
        timeZone: fixedZone, locale: fixedLocale))
    #expect(overlay[1].label.contains("Aug"))
}
