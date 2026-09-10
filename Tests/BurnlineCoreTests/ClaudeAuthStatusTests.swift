import Testing
import Foundation
@testable import BurnlineCore

// What `claude auth status`'s exit code is allowed to mean, and — more
// importantly — what it is NOT allowed to mean.
//
// This gate decides whether `UsagePoller` may spawn a Claude Code session at
// all. Getting it wrong in one direction freezes the figure for no reason; in
// the other it lets the poll boot a signed-out CLI into its login picker and
// press Enter on it, which opens a browser the user never asked for.

// MARK: - Exit code

/// The healthy answer. Says a credential exists — nothing more — but it is
/// enough to know the CLI will boot to a prompt rather than a login picker.
@Test func exitZeroIsNotABlock() {
    #expect(ClaudeAuthStatus.kind(exitCode: 0, keychainLocked: false) == nil)
}

@Test func exitOneIsSignedOut() {
    #expect(ClaudeAuthStatus.kind(exitCode: 1, keychainLocked: false) == .signedOut)
}

/// The credential reader returns null when the keychain read fails, which lands
/// on the same exit 1 as a genuine sign-out. Offering `/login` there is the
/// wrong remedy — the CLI's own is `security unlock-keychain`.
@Test func exitOneWithALockedKeychainIsNotSignedOut() {
    #expect(ClaudeAuthStatus.kind(exitCode: 1, keychainLocked: true) == .keychainLocked)
}

/// ⚠️ A probe that did not run is not evidence of anything. `nil` covers the
/// spawn failing, the timeout firing, and `claude` not being on disk — none of
/// which say a thing about the user's credentials.
@Test func aProbeThatDidNotRunIsNotABlock() {
    #expect(ClaudeAuthStatus.kind(exitCode: nil, keychainLocked: false) == nil)
    #expect(ClaudeAuthStatus.kind(exitCode: nil, keychainLocked: true) == nil)
}

/// ⚠️ Only exactly 1. The CLI documents 0 and 1; anything else is a crash, a
/// missing binary (127), or a signal — and reading those as "signed out" would
/// gate polling forever on a machine that is perfectly signed in.
@Test func onlyExitOneMeansSignedOut() {
    for code: Int32 in [2, 9, 43, 126, 127, 128, 137, -1] {
        #expect(ClaudeAuthStatus.kind(exitCode: code, keychainLocked: false) == nil,
                "exit \(code) must not be read as a block")
    }
}

// MARK: - What blocks a poll

/// The two states where Claude Code boots to `Select login method:`. Spawning a
/// session here is what starts an unrequested OAuth flow.
@Test func signedOutAndLockedKeychainBothGatePolling() {
    #expect(ClaudeAuthStatus.blocksPolling(.signedOut))
    #expect(ClaudeAuthStatus.blocksPolling(.keychainLocked))
}

/// ⚠️ **This test is inverted from an earlier draft, which asserted
/// `.signInExpired` does NOT gate.** The argument was that an expired-but-present
/// credential boots to a normal prompt rather than a login picker, so polling
/// stays safe — true of a credential nothing has discovered yet, but that state
/// carries no block at all. `AuthReducer` reaches `.signInExpired` only when a
/// probe answers exit 1, by which point the CLI has written its dead-credential
/// marker and a session would boot to the picker like any other. The exemption
/// would have reopened the harm the gate exists to close.
///
/// It was there to keep a recovery path open, and that job belongs elsewhere:
/// `recoveryNeverDependsOnSomethingTheBlockPrevents` in `AuthReducerTests`.
@Test func everyKindOfBlockGatesPolling() {
    for kind in [AuthBlock.Kind.signedOut, .keychainLocked, .signInExpired] {
        #expect(ClaudeAuthStatus.blocksPolling(kind), "\(kind) must gate polling")
    }
}

// MARK: - Three outcomes, not two

@Test func exitZeroIsACredential() {
    #expect(ClaudeAuthStatus.result(exitCode: 0, keychainLocked: false) == .credentialPresent)
}

@Test func exitOneIsABlockedResult() {
    #expect(ClaudeAuthStatus.result(exitCode: 1, keychainLocked: false) == .blocked(.signedOut))
    #expect(ClaudeAuthStatus.result(exitCode: 1, keychainLocked: true) == .blocked(.keychainLocked))
}

/// 🔴 The case that must never collapse into `.credentialPresent`. A probe that
/// did not run, or one that died from a signal, says nothing about credentials —
/// and treating it as healthy would clear a real block on every failed spawn.
@Test func anythingElseIsNoAnswerAndNeverACredential() {
    #expect(ClaudeAuthStatus.result(exitCode: nil, keychainLocked: false) == .noAnswer)
    for code: Int32 in [2, 127, 137, -1] {
        #expect(ClaudeAuthStatus.result(exitCode: code, keychainLocked: false) == .noAnswer,
                "exit \(code) must be no answer")
    }
}

@Test func noBlockNeverGatesPolling() {
    #expect(ClaudeAuthStatus.blocksPolling(nil) == false)
}
