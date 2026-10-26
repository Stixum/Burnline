import Testing
import Foundation
@testable import BurnlineCore

private let begins = Date(timeIntervalSince1970: 1_790_000_000)

/// 🔴 During a fill the header named the oldest week read *so far* as if it
/// were the horizon: "Archived from Aug 22" for about 55 seconds, then Aug 5.
@Test func duringAFillTheCoverageLineSaysItIsStillReading() {
    let line = HistoryFillState.filling(.init(filesOpened: 3, filesTotal: 10))
        .coverageLine(begins: begins)

    #expect(line == "Archived from \(HistoryLabels.day(begins)) so far. "
            + "Still reading older transcripts.")
}

/// Once the fill is done the date is the horizon, and says why.
@Test func afterTheFillTheCoverageLineNamesTheHorizon() {
    let finished = "Archived from \(HistoryLabels.day(begins)). Earlier weeks are gone: "
        + "Claude Code deletes transcripts after 30 days."

    #expect(HistoryFillState.complete.coverageLine(begins: begins) == finished)
    #expect(HistoryFillState.failed("x").coverageLine(begins: begins) == finished)
    #expect(HistoryFillState.idle.coverageLine(begins: begins) == finished)
}

/// No date, no line: the empty state below owns "nothing archived".
@Test func withNoCoverageThereIsNoLine() {
    #expect(HistoryFillState.filling(.init(filesOpened: 0, filesTotal: 1))
                .coverageLine(begins: nil) == nil)
    #expect(HistoryFillState.complete.coverageLine(begins: nil) == nil)
}
