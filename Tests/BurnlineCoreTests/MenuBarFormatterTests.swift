import Testing
import Foundation
@testable import BurnlineCore

private func snapshot(estimated: Double?, target: Double, scanning: Bool = false,
                      source: UsageSource = .paceOnly,
                      authBlock: AuthBlock? = nil) -> Snapshot {
    let start = Date(timeIntervalSince1970: 0)
    let window = Window(start: start, end: start.addingTimeInterval(7 * 86_400),
                        now: start.addingTimeInterval(7 * 86_400 * target / 100))
    return Snapshot(window: window, targetPercent: target, estimatedPercent: estimated,
                    projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                    source: source, isScanning: scanning, authBlock: authBlock)
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

// MARK: - A figure that has stopped updating for an auth reason

// `~` says the figure is being carried forward and will be corrected by the
// next capture. `!` says there will be no next capture: Claude Code cannot
// reach Anthropic, so nothing on this bar will move until the user signs in,
// unlocks the keychain, or signs in again.
//
// Same constraint as the tilde — it cannot be colour, because macOS tints menu
// bar content against a light or dark bar depending on wallpaper — and the same
// budget: one character.

private func blockedSnapshot(estimated: Double?, target: Double = 65,
                             kind: AuthBlock.Kind = .signedOut,
                             source: UsageSource = .paceOnly) -> Snapshot {
    snapshot(estimated: estimated, target: target, source: source,
             authBlock: AuthBlock(kind: kind, detectedAt: Date()))
}

/// A capture older than `CaptureAge.stalenessThreshold`. Below it,
/// `visibleAuthBlock` suppresses the block entirely — see the fresh-capture test.
private func staleLive(_ agoHours: Double = 2) -> UsageSource {
    .live(capturedAt: Date().addingTimeInterval(-agoHours * 3_600))
}

@Test func aBlockedFigureIsMarkedAtEveryMenuBarMode() {
    let blocked = blockedSnapshot(estimated: 64, source: staleLive())
    for mode in MenuBarMode.allCases {
        #expect(MenuBarFormatter.text(for: blocked, display: mode).hasPrefix("!"),
                "\(mode) lost the block mark")
    }
    #expect(MenuBarFormatter.text(for: blocked, display: .usedOverTarget) == "!64/65")
    #expect(MenuBarFormatter.text(for: blocked, display: .used) == "!64%")
    // `—` is what the mode renders with nothing to say; the mark still applies,
    // because the em dash is also not going to change.
    #expect(MenuBarFormatter.text(for: blocked, display: .projection) == "!—")
    #expect(MenuBarFormatter.text(for: blocked, display: .fiveHour) == "!—")
}

/// 🔴 The rule `!` exists for. `~` is gated on `estimatedPercent != nil` because
/// only a usage figure can be stale — but pace-only is the longest-lived blocked
/// state there is: `SnapshotBuilder` drops to `.paceOnly` once the dead capture's
/// window passes and stays there. Inheriting the tilde's gating would leave the
/// bar reading a confident bare `65` for the rest of the week.
@Test func theBlockMarkAppliesToABarePaceTargetToo() {
    let paceOnly = blockedSnapshot(estimated: nil)
    #expect(MenuBarFormatter.text(for: paceOnly, display: .usedOverTarget) == "!65")
    #expect(MenuBarFormatter.text(for: paceOnly, display: .used) == "!—")
    #expect(MenuBarFormatter.text(for: paceOnly, display: .delta) == "!—")
    for mode in MenuBarMode.allCases {
        #expect(MenuBarFormatter.text(for: paceOnly, display: mode).hasPrefix("!"),
                "\(mode) lost the block mark with no usage figure")
    }
}

/// `!` replaces `~`, never both. An extrapolation that can never be corrected is
/// the stronger statement, and `~!64/65` is noise at six characters.
@Test func theBlockMarkReplacesTheTildeRatherThanJoiningIt() {
    let staleAndBlocked = blockedSnapshot(estimated: 64, source: staleLive())
    // Precondition: without the block this snapshot is exactly the one that
    // earns a tilde, so the absence below is a replacement and not a coincidence.
    #expect(MenuBarFormatter.text(for: snapshot(estimated: 64, target: 65,
                                               source: staleLive())) == "~64/65")
    for mode in MenuBarMode.allCases {
        let text = MenuBarFormatter.text(for: staleAndBlocked, display: mode)
        #expect(text.contains("~") == false, "\(mode) drew both marks: \(text)")
        #expect(text.hasPrefix("!"), "\(mode) drew the wrong mark first: \(text)")
    }
}

/// The scanning ellipsis outranks everything, block included — it is returned
/// before any mark and must stay that way. Mid-first-scan there is no figure for
/// a mark to qualify.
@Test func theScanningEllipsisOutranksTheBlockMark() {
    let scanning = snapshot(estimated: nil, target: 0, scanning: true,
                            authBlock: AuthBlock(kind: .signedOut, detectedAt: Date()))
    #expect(MenuBarFormatter.text(for: scanning) == "…")
}

/// Drives off `visibleAuthBlock`, not `authBlock`: a block set seconds after a
/// capture landed explains nothing, and the bar must suppress it exactly as the
/// popover's banner does or the two contradict each other on screen.
@Test func aFreshCaptureSuppressesTheBlockMarkAsThePopoverSuppressesTheBanner() {
    let fresh = blockedSnapshot(estimated: 75, target: 80,
                                source: .live(capturedAt: Date().addingTimeInterval(-60)))
    #expect(MenuBarFormatter.text(for: fresh, display: .usedOverTarget) == "75/80")
    #expect(fresh.authBlock != nil)
    #expect(fresh.visibleAuthBlock == nil)
}

/// An exclamation mark is invisible to a screen reader twice over — most voices
/// don't announce punctuation at all — so the spoken label carries it in words.
@Test func theBlockMarkIsSpokenNotJustDrawn() {
    let label = MenuBarFormatter.accessibilityLabel(for: blockedSnapshot(estimated: 64,
                                                                        source: staleLive()))
    #expect(label.lowercased().contains("not updating"))
    #expect(label.lowercased().contains("signed out"))
}

/// Three kinds, three remedies — sign in, unlock the keychain, sign in again. A
/// listener told only that "something is wrong" has learned nothing the frozen
/// figure hadn't already told them.
@Test func eachBlockKindIsSpokenDistinctly() {
    // Listed rather than iterated: `AuthBlock.Kind` is deliberately not
    // `CaseIterable`, and adding the conformance for a test's convenience would
    // put a public API on a type for a reason nothing outside this file has.
    let kinds: [AuthBlock.Kind] = [.signedOut, .keychainLocked, .signInExpired]
    let spoken = kinds.map { kind in
        MenuBarFormatter.accessibilityLabel(for: blockedSnapshot(estimated: 64, kind: kind))
    }
    #expect(Set(spoken).count == spoken.count)
    #expect(spoken[0].lowercased().contains("signed out"))
    #expect(spoken[1].lowercased().contains("keychain"))
    #expect(spoken[2].lowercased().contains("expired"))
}

/// The pace-only phrasing gains the reason too, or "no usage figure yet" sounds
/// like a wait rather than something the user has to go and fix.
@Test func thePaceOnlySpokenLabelSaysWhyThereIsNoFigure() {
    let label = MenuBarFormatter.accessibilityLabel(for: blockedSnapshot(estimated: nil,
                                                                        kind: .keychainLocked))
    #expect(label.contains("no usage figure yet"))
    #expect(label.lowercased().contains("keychain"))
}

/// The spoken label mirrors the drawn one: `!` replaces `~` there, so a listener
/// must not hear "carried forward for 2h" — the lesser half of a problem where
/// the figure is not going to be corrected at all.
@Test func theSpokenBlockReasonReplacesTheCarriedForwardPhrase() {
    let staleAndBlocked = blockedSnapshot(estimated: 64, source: staleLive())
    let label = MenuBarFormatter.accessibilityLabel(for: staleAndBlocked).lowercased()
    #expect(label.contains("carried forward") == false)
    #expect(label.contains("not updating"))
    // Precondition: the same snapshot without a block does say it.
    let unblocked = MenuBarFormatter.accessibilityLabel(
        for: snapshot(estimated: 64, target: 65, source: staleLive())).lowercased()
    #expect(unblocked.contains("carried forward"))
}
