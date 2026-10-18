import Testing
@testable import BurnlineCore

// The History window lists completed weeks under the chart, newest first, and
// folds all but the most recent few behind a toggle. Which rows show is a rule,
// and `Sources/Burnline` has no test target, so it lives in Core.

private typealias Disclosure = HistoryScoreboardDisclosure

@Test func aCollapsedScoreboardShowsTheNewestWeeksAndOffersTheRest() {
    let layout = Disclosure.layout(rowCount: 12, selectedIndex: 0, isExpanded: false)
    #expect(layout.visibleIndices == [0, 1, 2, 3])
    #expect(layout.toggleTitle == "Show all 12 weeks")
}

@Test func anExpandedScoreboardShowsEveryWeekAndOffersToFold() {
    let layout = Disclosure.layout(rowCount: 12, selectedIndex: 0, isExpanded: true)
    #expect(layout.visibleIndices == Array(0..<12))
    #expect(layout.toggleTitle == "Show fewer weeks")
}

@Test func aToggleThatWouldHideOneWeekIsNotOffered() {
    // The toggle is a row tall, so folding a single week saves nothing and
    // costs a click. Five rows show whole; six fold — the positive control that
    // the threshold is the one stated and not "never fold".
    let five = Disclosure.layout(rowCount: 5, selectedIndex: nil, isExpanded: false)
    #expect(five.visibleIndices == Array(0..<5))
    #expect(five.toggleTitle == nil)

    let six = Disclosure.layout(rowCount: 6, selectedIndex: nil, isExpanded: false)
    #expect(six.visibleIndices == [0, 1, 2, 3])
    #expect(six.toggleTitle == "Show all 6 weeks")
}

@Test func theWeekInTheBreakdownStaysVisibleWhenFolded() {
    // 🔴 The breakdown's range menu can pick any week. Folded away, the row
    // marked "In breakdown" would vanish and the bars would reconcile with no
    // number on screen.
    let layout = Disclosure.layout(rowCount: 12, selectedIndex: 9, isExpanded: false)
    #expect(layout.visibleIndices == [0, 1, 2, 3, 9])
    #expect(layout.toggleTitle == "Show all 12 weeks")
}

@Test func aSelectedRecentWeekIsNotListedTwice() {
    let layout = Disclosure.layout(rowCount: 12, selectedIndex: 2, isExpanded: false)
    #expect(layout.visibleIndices == [0, 1, 2, 3])
}

@Test func anEmptyScoreboardHasNoRowsAndNoToggle() {
    let layout = Disclosure.layout(rowCount: 0, selectedIndex: nil, isExpanded: false)
    #expect(layout.visibleIndices.isEmpty)
    #expect(layout.toggleTitle == nil)
}
