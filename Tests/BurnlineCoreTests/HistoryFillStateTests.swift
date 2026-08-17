import Testing
@testable import BurnlineCore

private func progress(_ opened: Int, of total: Int) -> HistoryFill.Progress {
    HistoryFill.Progress(filesOpened: opened, filesTotal: total)
}

// MARK: - Reload phase

/// 🔴 The defect this rule was written for. A first run opens the window, reads
/// an archive that is still empty, and the fill then writes six weeks behind it.
/// Nothing reloads unless the phase the window keys on has changed by the time
/// the fill is done.
@Test func fillingToCompleteChangesTheReloadPhase() {
    #expect(HistoryFillState.filling(progress(2_000, of: 2_405)).reloadPhase == .filling)
    #expect(HistoryFillState.complete.reloadPhase == .finished)
    #expect(HistoryFillState.filling(progress(2_000, of: 2_405)).reloadPhase
            != HistoryFillState.complete.reloadPhase)
}

/// 🔴 The transition that is easy to lose. `.idle` and `.complete` are both "not
/// filling", so folding them into one phase looks like a simplification — and it
/// silently removes the only reload a fill with nothing to read ever produces,
/// because that fill goes idle → complete without publishing progress.
@Test func idleAndCompleteAreDifferentReloadPhases() {
    #expect(HistoryFillState.idle.reloadPhase != HistoryFillState.complete.reloadPhase)
}

/// A failed fill still wrote whatever ranges succeeded, so it reloads like any
/// other ending.
@Test func failureIsAFinishedReloadPhase() {
    #expect(HistoryFillState.failed("boom").reloadPhase == .finished)
}

/// The counterweight: ~100 progress reports cross the main actor during one
/// fill, and re-reading the archive for each would be a hundred disk reads to
/// learn nothing. Only a range's commit changes the files, never a report.
@Test func progressWithinAFillDoesNotChangeTheReloadPhase() {
    #expect(HistoryFillState.filling(progress(25, of: 2_405)).reloadPhase
            == HistoryFillState.filling(progress(2_400, of: 2_405)).reloadPhase)
}

// MARK: - What the window draws

@Test func aRunningFillDrawsItsOwnProgress() {
    let state = HistoryFillState.filling(progress(2_050, of: 2_405))
    #expect(state.display(archiveIsEmpty: true) == .filling(progress(2_050, of: 2_405)))
    #expect(state.display(archiveIsEmpty: nil) == .filling(progress(2_050, of: 2_405)))
}

/// 🔴 The wrong answer that shipped: an empty archive during the fill was
/// reported as "No completed weeks yet", which is a statement about the future
/// and was false while six weeks were being written.
@Test func anEmptyArchiveIsNotCalledEmptyUntilTheFillHasFinished() {
    #expect(HistoryFillState.filling(progress(0, of: 2_405))
        .display(archiveIsEmpty: true) != .empty)
    #expect(HistoryFillState.idle.display(archiveIsEmpty: true) != .empty)
    #expect(HistoryFillState.complete.display(archiveIsEmpty: true) == .empty)
    #expect(HistoryFillState.failed("boom").display(archiveIsEmpty: true) == .empty)
}

/// ⚠️ `.idle` is ambiguous and is resolved deliberately: it means no fill has
/// reported yet, so the window claims neither that one is running nor that there
/// is nothing to show.
@Test func idleRendersAsNeitherFillingNorEmpty() {
    let display = HistoryFillState.idle.display(archiveIsEmpty: true)
    #expect(display == .loading)
    if case .filling = display { Issue.record("idle must never render as a running fill") }
}

/// An archive with weeks in it is drawn whatever the fill is doing — a gap fill
/// on a later launch runs over a populated archive, and hiding it would be the
/// same absence claim in a different costume.
@Test func aPopulatedArchiveIsDrawnEvenWhileFilling() {
    #expect(HistoryFillState.filling(progress(10, of: 100))
        .display(archiveIsEmpty: false) == .content)
    #expect(HistoryFillState.idle.display(archiveIsEmpty: false) == .content)
    #expect(HistoryFillState.complete.display(archiveIsEmpty: false) == .content)
    #expect(HistoryFillState.failed("boom").display(archiveIsEmpty: false) == .content)
}

/// An archive nobody has read yet is a third answer, not an empty one.
@Test func anUnreadArchiveLoadsRatherThanReportingEmpty() {
    #expect(HistoryFillState.complete.display(archiveIsEmpty: nil) == .loading)
    #expect(HistoryFillState.failed("boom").display(archiveIsEmpty: nil) == .loading)
}

// MARK: - The bar itself

@Test func progressFractionDrivesADeterminateBar() {
    #expect(progress(0, of: 2_405).fraction == 0)
    #expect(progress(2_405, of: 2_405).fraction == 1)
    #expect(abs(progress(1_202, of: 2_404).fraction - 0.5) < 0.000_1)
}

/// A range with nothing to read still reports, so the zero denominator is a real
/// case rather than a defensive guard — and `filesOpened` may run one past the
/// total for a file that vanished mid-fill.
@Test func progressFractionSurvivesItsEdges() {
    #expect(progress(0, of: 0).fraction == 0)
    #expect(progress(101, of: 100).fraction == 1)
}
