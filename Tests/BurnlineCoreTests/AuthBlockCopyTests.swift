import Testing
import Foundation
@testable import BurnlineCore

// The words the popover banner and the menu bar's spoken label share, and the
// command the one button in this app is allowed to run.

private let kinds: [AuthBlock.Kind] = [.signedOut, .keychainLocked, .signInExpired]

// MARK: - The command

/// 🔴 **The rule that would do real damage if it regressed.** `claude auth
/// logout` revokes at `/revoke` and deletes the stored credential — machine
/// wide, killing every other session on the Mac, including any agent running at
/// the time. It was considered as a way to force a re-login over an expired
/// credential and rejected: the CLI has no presence check, so plain
/// `auth login` already works there.
@Test func theSignInCommandNeverRevokes() {
    for kind in kinds {
        let command = kind.command(claudeExecutable: "/opt/homebrew/bin/claude")
        #expect(!command.contains("logout"), "\(kind) must never revoke: \(command)")
        #expect(!command.contains("&&"), "\(kind) must be one command, not a chain: \(command)")
    }
}

/// ⚠️ The resolved absolute path, not the bare word. Terminal's login shell may
/// not have Homebrew on `PATH`, and `ClaudeExecutable` already knows the four
/// places Claude Code hides.
@Test func theSignInCommandUsesTheResolvedExecutablePath() {
    let command = AuthBlock.Kind.signedOut.command(claudeExecutable: "/custom/bin/claude")
    #expect(command == "/custom/bin/claude auth login")
}

/// A locked keychain is not a sign-in problem and must not offer a sign-in.
@Test func aLockedKeychainUnlocksRatherThanSigningIn() {
    let command = AuthBlock.Kind.keychainLocked.command(claudeExecutable: "/bin/claude")
    #expect(command == "security unlock-keychain")
    #expect(AuthBlock.Kind.keychainLocked.actionLabel == "Unlock…")
}

// MARK: - The words

@Test func everyKindIsNamedDistinctly() {
    #expect(Set(kinds.map(\.title)).count == kinds.count)
}

/// The platform's promise that this opens something and asks you more — which
/// is exactly what happens.
@Test func everyActionLabelEndsInAnEllipsis() {
    for kind in kinds {
        #expect(kind.actionLabel.hasSuffix("…"), "\(kind): \(kind.actionLabel)")
    }
}

/// ⚠️ Desktop-app sessions write transcripts, so their tokens are still counted
/// — units keep moving while the CLI sits signed out. Telling those users their
/// *usage* stopped is false; what stopped is the anchor.
@Test func theDetailSaysTheFigureStoppedNotThatUsageStopped() {
    for kind in kinds {
        let detail = AuthBlock(kind: kind, detectedAt: Date()).detail(anchorAge: 7_200)
        #expect(detail.contains("Stopped updating"))
        #expect(!detail.lowercased().contains("usage stopped"))
    }
}

/// The banner promises a Terminal window because the ellipsis alone does not —
/// it says "asks you more", not "spawns another app".
@Test func theDetailWarnsThatATerminalWindowOpens() {
    for kind in kinds {
        let detail = AuthBlock(kind: kind, detectedAt: Date()).detail(anchorAge: nil)
        #expect(detail.contains("Terminal window"), "\(kind): \(detail)")
    }
}

/// Pace-only has no anchor to have stopped, and must not claim one did.
@Test func noAnchorIsDescribedAsNoReadingRatherThanAStoppedOne() {
    let detail = AuthBlock(kind: .signedOut, detectedAt: Date()).detail(anchorAge: nil)
    #expect(detail.hasPrefix("No reading yet."))
}
