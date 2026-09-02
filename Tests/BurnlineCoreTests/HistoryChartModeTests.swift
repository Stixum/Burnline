import Testing
import Foundation
@testable import BurnlineCore

// The History window's chart area is a TOGGLE, and every rule that keeps a
// reader from misreading one mode as the other lives in `HistoryChartMode` so
// that these can watch it. `Sources/Burnline` has no test target: a subtitle
// written inline in a view body is a rule nothing can hold upright.

private let seriesStart = Date(timeIntervalSince1970: 1_786_024_800)
private let seriesEnd = seriesStart.addingTimeInterval(7 * 86_400)

/// A percent series at the given readings, evenly spread through one window.
private func series(_ percentages: [Double]) -> HistoryQuery.PercentSeries {
    let entries = percentages.enumerated().map { index, percent in
        TrackingEntry(percent: percent,
                      at: seriesStart.addingTimeInterval(Double(index + 1) * 3_600),
                      resetsAt: seriesEnd)
    }
    return HistoryQuery.percentCurve(tracking: entries, start: seriesStart, end: seriesEnd)
}

// MARK: - The unit is the tell

@Test func eachModeNamesItsOwnUnitOnTheAxis() {
    // 🔴 The mode indicator. `4.0B` versus `50%` is what tells a reader which
    // series is on screen when the two shapes happen to resemble each other,
    // and both charts route their y axis through this one function.
    #expect(HistoryChartMode.units.axisLabel(4_000_000_000) == "4.0B")
    #expect(HistoryChartMode.percent.axisLabel(50) == "50%")

    // The units mode is exactly the existing label rule, not a second copy of
    // it that can drift from the scoreboard printed above the chart.
    #expect(HistoryChartMode.units.axisLabel(8_630_000_000)
            == HistoryLabels.units(8_630_000_000))
}

@Test func thePercentAxisNeverDropsItsSignAndNeverMatchesTheUnitsAxis() {
    // 🔴 The mode indicator, stated as the property that actually holds.
    //
    // "Never a bare number" is not literally true of the units axis — the
    // compaction prints `0` at the origin — so the rule that protects a reader
    // is the sharper one: `%` is UNCONDITIONAL on the percent axis, which makes
    // a bare tick unambiguously units, and the two modes never render one value
    // the same way. Delete the `%` and every case below fails; point the units
    // mode at the percent label and the last one does.
    let bare = CharacterSet(charactersIn: "0123456789.,-−+ ")
    for value in [0.0, 1, 42, 50, 100, 999, 4_000_000_000] {
        let percent = HistoryChartMode.percent.axisLabel(value)
        #expect(percent.hasSuffix("%"), "the percent axis rendered \(value) as \(percent)")
        #expect(percent.unicodeScalars.contains { !bare.contains($0) })
        #expect(HistoryChartMode.units.axisLabel(value) != percent)
    }
}

@Test func aUnitsTickGoesBareOnlySixOrdersOfMagnitudeBelowARealWeek() {
    // The one place the "never a bare number" wording does not hold, pinned so
    // that a change to the compaction thresholds has to come past it rather
    // than quietly widening the gap. A real week is ~8.6 × 10⁹ weighted units
    // and the scale suffix starts at 10³, so every tick on a chart of any real
    // week carries one — the axis of an empty chart is the whole exposure.
    #expect(HistoryChartMode.units.axisLabel(1_000) == "1.0K")
    #expect(HistoryChartMode.units.axisLabel(999) == "999")
    #expect(HistoryChartMode.units.axisLabel(0) == "0")
    // And a bare tick is still unambiguous, because the other mode has no way
    // to produce one.
    #expect(HistoryChartMode.percent.axisLabel(999) == "999%")
}

@Test func anAxisTickSurvivesANonFiniteValue() {
    // Same class of defect `DisplayValue` exists for: `Int(Double)` traps
    // outside Int's range and `String(format:)` prints `inf`. An axis value is
    // handed in by Charts, so it is not ours to bound.
    #expect(HistoryChartMode.percent.axisLabel(.nan) == "—")
    #expect(HistoryChartMode.percent.axisLabel(.infinity) == "—")
    #expect(HistoryChartMode.units.axisLabel(.infinity) == "—")
}

@Test func aPercentageIsNotAShareAndTheHundredIsTheDifference() {
    // ⚠️ `share` takes a 0…1 fraction; `percent` takes Anthropic's own figure,
    // which already reads 51 for fifty-one percent. Feeding one to the other is
    // a hundred-fold error that renders as a perfectly plausible chart, which is
    // why they are two named functions rather than one with a flag.
    #expect(HistoryLabels.percent(51) == "51%")
    #expect(HistoryLabels.share(0.51) == "51%")
    #expect(HistoryLabels.percent(0.51) == "1%")

    // And no `<1%` guard: unlike a breakdown row, which exists only because it
    // consumed something, 0% is a real and common state at the start of a
    // window. Dressing it up would invent usage nobody reported.
    #expect(HistoryLabels.percent(0) == "0%")
    #expect(HistoryLabels.percent(100) == "100%")
}

@Test func aWindowsFinalReadingIsFormattedByTheOnePercentRule() {
    // `finalReading` hand-rolled `"\(DisplayValue.whole(percent))%"` — a third
    // copy of what `percent(_:)` owns, and the classic way a column ends up
    // disagreeing with the chart beside it.
    let end = Date(timeIntervalSince1970: 1_786_024_800)
    #expect(HistoryLabels.finalReading(percent: 61, at: end, windowEnd: end).value
            == HistoryLabels.percent(61))

    // Routing it there also buys the non-finite guard, which is a behaviour
    // change and a deliberate one: `DisplayValue.whole` alone rendered a NaN
    // reading as `0%`, and a figure nobody can compute is not a week of no
    // usage. Unreachable from disk — `HistoryStore.JSON.decoder` keeps the
    // default `.throw` strategy — so this pins the public entry point.
    #expect(HistoryLabels.finalReading(percent: .nan, at: end, windowEnd: end).value == "—")
    #expect(HistoryLabels.finalReading(percent: .nan, at: end, windowEnd: end).isRecorded)
}

// MARK: - The subtitle is the other tell

@Test func theTwoModesNeverDescribeThemselvesTheSameWay() {
    // 🔴 A required mitigation, not a caption. The toggle's cost is a mode you
    // can occupy without noticing, and the subtitle is the sentence that
    // changes when the mode does. A copy-pasted string here would leave the
    // percent trend describing itself as cumulative units — and it would look
    // completely fine in a screenshot.
    let modes = HistoryChartMode.allCases
    #expect(Set(modes.map(\.title)).count == modes.count)
    #expect(Set(modes.map(\.subtitle)).count == modes.count)
    #expect(Set(modes.map(\.caveat)).count == modes.count)
    #expect(Set(modes.map(\.emptyMessage)).count == modes.count)
    for mode in modes {
        #expect(!mode.title.isEmpty)
        #expect(!mode.subtitle.isEmpty)
        #expect(!mode.caveat.isEmpty)
        #expect(!mode.emptyMessage.isEmpty)
    }
}

/// ⚠️ **Reworded 2026-09-01, and its stated intent retired with it.** It used to
/// be `theUnitsSubtitleIsTheOneTheWindowAlreadyPrinted`, pinning "cumulative
/// units against how far through the window you were" on the grounds that
/// "switching to units must change nothing a reader had already learned to rely
/// on — the toggle is an addition, not a rewording of what was there".
///
/// That was a promise about a transition, not a property of the type, and the
/// transition is over: the toggle has shipped and nobody is carrying an
/// expectation across it any more. What replaces it is a property that does not
/// expire — each subtitle names the quantity AND the axis of its own series, in
/// the History window's vocabulary (a **week**) and the app's one word for what
/// Anthropic caps (a **limit**). A subtitle that named neither would leave the
/// two series describable by one caption, which is the misread this whole type
/// exists to prevent.
@Test func eachSubtitleNamesItsOwnQuantityAndItsOwnAxis() {
    #expect(HistoryChartMode.units.subtitle == "cumulative units by fraction of the week elapsed")
    #expect(HistoryChartMode.percent.subtitle
            == "Anthropic's percentage of the weekly limit, as captured")

    // Neither line may be true of the other series.
    #expect(!HistoryChartMode.units.subtitle.contains("percent"))
    #expect(!HistoryChartMode.percent.subtitle.contains("units"))
}

@Test func neitherEmptyMessageReadsAsAWeekOfNoUsage() {
    // 🔴 Empty means NOT RECORDED. Most archived weeks predate the retention
    // fix and have no readings at all, and the percent copy has to say the
    // absence is permanent — a reader who thinks the data is still coming waits
    // for something that cannot arrive.
    for mode in HistoryChartMode.allCases {
        #expect(!mode.emptyMessage.contains("0%"))
    }
    #expect(HistoryChartMode.percent.emptyMessage.contains("cannot"))
}

// MARK: - The y domain

@Test func theUnitsModeDeclaresThatItHasNoCeilingRatherThanStayingSilent() {
    // 🔴 The reason `yDomain` is a member returning an OPTIONAL. The test the
    // type has to pass is "would someone adding a third mode know what to fill
    // in?", and a nil case is the compiler asking them. Parked on
    // `PercentSeries` instead, this answer would exist nowhere at all — the
    // units chart would simply omit `.chartYScale` and a reader would have to
    // infer that the omission was deliberate.
    //
    // Auto-fit is right here for a reason, not by default: the unit scale is
    // arbitrary by construction — `Weights` documents that calibration divides
    // it out — so there is no meaningful fixed ceiling to name.
    #expect(HistoryChartMode.units.yDomain(for: []) == nil)
    #expect(HistoryChartMode.units.yDomain(for: [series([2, 7, 12])]) == nil)
    #expect(HistoryChartMode.units.yDomain(for: [series([40, 104])]) == nil)

    // And the percent mode never answers nil, so its chart's `if let` always
    // takes the domain branch.
    #expect(HistoryChartMode.percent.yDomain(for: []) != nil)
    #expect(HistoryChartMode.percent.yDomain(for: [series([2, 7, 12])]) != nil)
}

@Test func everyModeAnswersTheAxisQuestionOneWayOrTheOther() {
    // The enumeration is the point: a mode added without deciding its ceiling
    // cannot compile, and this walks `allCases` so the walk grows with the type
    // rather than naming the two that exist today.
    for mode in HistoryChartMode.allCases {
        let domain = mode.yDomain(for: [series([12, 40])])
        if let domain {
            #expect(domain.lowerBound.isFinite && domain.upperBound.isFinite)
            #expect(domain.lowerBound < domain.upperBound)
        }
        // A nil is a real answer — "fit the data" — and needs no assertion
        // beyond having been reachable at all.
    }
}

// MARK: - The percent domain

@Test func thePercentDomainIsTheWholeAllowanceNotJustWhatWasObserved() {
    // 🔴 The decision. A quiet week that reached 12% must not render identically
    // to one that reached 95%, and the pace diagonal is only the plot area's
    // diagonal while the ceiling is the whole allowance — fit the domain to the
    // data and "above the line" stops meaning "ahead of pace".
    #expect(HistoryChartMode.percent.yDomain(for: [series([2, 7, 12])]) == 0...100)
    #expect(HistoryChartMode.percent.yDomain(for: [series([61, 74, 88])]) == 0...100)
    #expect(HistoryChartMode.percent.yDomain(for: [series([100])]) == 0...100)
}

@Test func aReGrantedWeekIsDrawnAtTheSameScaleAsAnyOther() {
    // The live 2026-09-01 event: 51% replaced by 3%. Under an auto-fitted domain
    // the same event would look bigger or smaller depending on what else was
    // overlaid that day, so the one figure this chart exists to show would have
    // no fixed size.
    let regranted = series([18, 34, 51, 3, 9])
    #expect(regranted.regrants.count == 1)
    #expect(HistoryChartMode.percent.yDomain(for: [regranted]) == 0...100)
}

@Test func anEmptyChartStillShowsTheWholeAllowance() {
    // Nothing recorded is not a week at 0%, and a domain collapsed to 0...0
    // would divide the axis by nothing.
    #expect(HistoryChartMode.percent.yDomain(for: []) == 0...100)
    #expect(HistoryChartMode.percent.yDomain(for: [series([])]) == 0...100)
}

@Test func aReadingPastTheAllowanceIsNeverClippedOutOfThePlot() {
    // `used_percentage` is Anthropic's number, not ours, and a ceiling that
    // silently declined to draw a reading would be the chart choosing not to
    // report a measurement it had. Headroom above it, so the top stroke is not
    // half-clipped by the frame either.
    #expect(HistoryChartMode.percent.yDomain(for: [series([40, 104])]) == 0...110)
    #expect(HistoryChartMode.percent.yDomain(for: [series([110])]) == 0...120)
    #expect(HistoryChartMode.percent.yDomain(for: [series([100.5])]) == 0...110)
}

@Test func theDomainIsTakenAcrossEveryOverlaidWeekNotJustTheFirst() {
    // Three weeks share one scale — that is what makes the overlay a
    // comparison. A domain read off one series would clip the others.
    let quiet = series([3, 9])
    let over = series([40, 104])
    #expect(HistoryChartMode.percent.yDomain(for: [quiet, over]) == 0...110)
    #expect(HistoryChartMode.percent.yDomain(for: [over, quiet]) == 0...110)
}

@Test func aNonFiniteReadingCannotBlowUpTheDomain() {
    // Filtered rather than clamped: NaN propagates through `max` in a way that
    // depends on argument order, so one bad reading could produce a domain of
    // 0...nan and take the whole chart with it.
    let poisoned = HistoryQuery.PercentSeries(
        points: [
            HistoryQuery.PercentPoint(elapsedFraction: 0.1, percent: 12,
                                      at: seriesStart, allowance: 0, followsRegrant: false),
            HistoryQuery.PercentPoint(elapsedFraction: 0.2, percent: .nan,
                                      at: seriesStart, allowance: 0, followsRegrant: false),
            HistoryQuery.PercentPoint(elapsedFraction: 0.3, percent: .infinity,
                                      at: seriesStart, allowance: 0, followsRegrant: false),
        ],
        regrants: [])
    let domain = HistoryChartMode.percent.yDomain(for: [poisoned])
    #expect(domain == 0...100)
    #expect(domain?.upperBound.isFinite == true)
}

@Test func thePaceDiagonalEndsAtTheSameCeilingTheAxisDoes() {
    // The diagonal runs (0, 0) → (1, fullAllowance), and the axis' ordinary
    // ceiling is the same constant. Spelled twice they can drift, and a pace
    // line that stops short of the corner reads as a target you cannot reach.
    #expect(HistoryChartMode.fullAllowance == 100)
    #expect(HistoryChartMode.percent.yDomain(for: [])?.upperBound
            == HistoryChartMode.fullAllowance)
}
