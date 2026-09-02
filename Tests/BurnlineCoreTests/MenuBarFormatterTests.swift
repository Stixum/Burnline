import Testing
import Foundation
@testable import BurnlineCore

private func snapshot(estimated: Double?, target: Double, scanning: Bool = false,
                      source: UsageSource = .paceOnly) -> Snapshot {
    let start = Date(timeIntervalSince1970: 0)
    let window = Window(start: start, end: start.addingTimeInterval(7 * 86_400),
                        now: start.addingTimeInterval(7 * 86_400 * target / 100))
    return Snapshot(window: window, targetPercent: target, estimatedPercent: estimated,
                    projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                    source: source, isScanning: scanning)
}

@Test func showsActualOverTargetWhenCalibrated() {
    #expect(MenuBarFormatter.text(for: snapshot(estimated: 40.4, target: 71.4)) == "40/71")
}

@Test func showsTargetAloneWhenUncalibrated() {
    #expect(MenuBarFormatter.text(for: snapshot(estimated: nil, target: 71.4)) == "71")
}

@Test func showsEllipsisWhileFirstScanRuns() {
    #expect(MenuBarFormatter.text(for: snapshot(estimated: nil, target: 0, scanning: true)) == "…")
}

@Test func roundsToWholePercent() {
    #expect(MenuBarFormatter.text(for: snapshot(estimated: 39.6, target: 71.5)) == "40/72")
}

@Test func clampsOutlandishEstimates() {
    #expect(MenuBarFormatter.text(for: snapshot(estimated: 4_000, target: 50)) == "999/50")
}

@Test func accessibilityLabelSpellsBothNumbersOut() {
    let label = MenuBarFormatter.accessibilityLabel(for: snapshot(estimated: 40, target: 71))
    #expect(label.contains("40"))
    #expect(label.contains("71"))
    #expect(label.lowercased().contains("ahead of pace"))
}

@Test func accessibilityLabelSaysOverBudgetWhenOver() {
    let label = MenuBarFormatter.accessibilityLabel(for: snapshot(estimated: 90, target: 71))
    #expect(label.lowercased().contains("behind pace"))
}

// MARK: - Staleness, without colour

// The menu bar is the surface actually watched, and it had no staleness signal
// at all: on 2026-08-12 it showed a confident `75` for 2h18m while the real
// figure had moved to 76. The popover said so; nobody had the popover open.
//
// It cannot be colour — macOS tints menu bar content against a light or dark
// bar depending on wallpaper, so a hardcoded colour is unreadable on one of
// them. A tilde carries it instead: universally "approximately", one character.

private func staleSnapshot(_ estimated: Double, capturedAgo: TimeInterval) -> Snapshot {
    snapshot(estimated: estimated, target: 80,
             source: .live(capturedAt: Date().addingTimeInterval(-capturedAgo)))
}

@Test func aStaleCaptureMarksTheMenuBarFigureAsApproximate() {
    let stale = staleSnapshot(75, capturedAgo: 2 * 3_600)
    #expect(MenuBarFormatter.text(for: stale, display: .usedOverTarget).hasPrefix("~"))
    #expect(MenuBarFormatter.text(for: stale, display: .used).hasPrefix("~"))
}

@Test func aFreshCaptureLeavesTheMenuBarUnmarked() {
    let fresh = staleSnapshot(75, capturedAgo: 60)
    #expect(MenuBarFormatter.text(for: fresh, display: .usedOverTarget).hasPrefix("~") == false)
    #expect(MenuBarFormatter.text(for: fresh, display: .usedOverTarget) == "75/80")
}

/// Pace-only has no usage figure to be stale about — the clock target is exact.
/// Marking it would say the arithmetic is uncertain, which it never is.
@Test func paceOnlyIsNeverMarkedApproximate() {
    let paceOnly = snapshot(estimated: nil, target: 80, source: .paceOnly)
    #expect(MenuBarFormatter.text(for: paceOnly, display: .usedOverTarget).hasPrefix("~") == false)
}

/// A tilde is invisible to a screen reader, so the spoken label must say it.
@Test func theStalenessMarkerIsSpokenNotJustDrawn() {
    let stale = staleSnapshot(75, capturedAgo: 2 * 3_600)
    let label = MenuBarFormatter.accessibilityLabel(for: stale).lowercased()
    #expect(label.contains("carried forward") || label.contains("estimated"))
}
