import Testing
import Foundation

// Source-text pins for the per-model limit's app wiring, in the style of
// `HistoryReloadWiringTests`: `Sources/Burnline` has no test target, the
// decisions are in Core (`ScopedLimit.rowStyle`, `PollDecision.interval`,
// `NotificationDecision`), and these only check that the app calls them.
// Whitespace is collapsed before matching, so they pin call sites, not
// formatting.

private func appFile(_ name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BurnlineCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
    let text = try String(contentsOf: root.appendingPathComponent("Sources/Burnline/\(name)"),
                          encoding: .utf8)
    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@Test func theRefreshBandsOnTheModelLimitToo() throws {
    let store = try appFile("UsageStore.swift")
    #expect(store.contains("scopedWeeklyPercent: snapshot.scopedWeekly?.percent,"))
}

@Test func thePopoverDrawsTheModelLimitByItsGrade() throws {
    let popover = try appFile("PopoverView.swift")
    #expect(popover.contains("if let scoped = snapshot.scopedWeekly { scopedRow(scoped) }"))
    #expect(popover.contains("switch scoped.rowStyle {"))
    #expect(popover.contains("case .warning: symbolRow(\"exclamationmark.triangle.fill\", scoped.rowLabel, scoped.rowValue, tint: Theme.warning)"))
    #expect(popover.contains("case .critical: symbolRow(\"exclamationmark.octagon.fill\", scoped.rowLabel, scoped.rowValue, tint: Theme.danger)"))
    #expect(popover.contains(".help(scoped.rowHelp)"))
}
