import Testing
import Foundation
@testable import BurnlineCore

// Whether Burnline believes Claude Code can still reach Anthropic, and — the
// part that actually bites — how that belief is ever revised back.
//
// An earlier draft of this design gated polling on the block, hid the manual
// refresh, and cleared the block only on a poll. That is a closed loop: the one
// thing that could clear it was the one thing the block prevented. These tests
// exist so it cannot close again.

private let now = Date(timeIntervalSince1970: 1_000_000)
private let earlier = now.addingTimeInterval(-3_600)
private let later = now.addingTimeInterval(3_600)

private func block(_ kind: AuthBlock.Kind, at date: Date = earlier) -> AuthBlock {
    AuthBlock(kind: kind, detectedAt: date)
}

// MARK: - Setting a block

@Test func aProbeThatFindsNoCredentialSetsABlock() {
    let result = AuthReducer.reduce(nil, .probe(.blocked(.signedOut), discoveredByPoll: false), now: now)
    #expect(result == AuthBlock(kind: .signedOut, detectedAt: now))
}

/// The one thing separating a lapse from a sign-out: the CLI reports both as
/// exit 1, so the sequence is the only evidence.
@Test func aBlockDiscoveredByAPollIsAnExpiry() {
    let result = AuthReducer.reduce(nil, .probe(.blocked(.signedOut), discoveredByPoll: true), now: now)
    #expect(result?.kind == .signInExpired)
}

/// A locked keychain is not an expiry, however it came to light.
@Test func aLockedKeychainIsNeverReclassifiedAsAnExpiry() {
    let result = AuthReducer.reduce(nil, .probe(.blocked(.keychainLocked), discoveredByPoll: true), now: now)
    #expect(result?.kind == .keychainLocked)
}

/// 🔴 The date must stay put while the block stands. It is re-derived on a
/// timer, so advancing it each cycle would push it permanently ahead of any
/// capture's `provenAt` — and `captureProven` could then never clear anything.
@Test func detectedAtDoesNotAdvanceWhileTheSameBlockStands() {
    let standing = block(.signedOut, at: earlier)
    let result = AuthReducer.reduce(standing, .probe(.blocked(.signedOut), discoveredByPoll: false),
                                    now: now)
    #expect(result?.detectedAt == earlier)
}

/// A different finding is new information, and gets its own date.
@Test func aDifferentKindReplacesTheBlockAndItsDate() {
    let standing = block(.signedOut, at: earlier)
    let result = AuthReducer.reduce(standing, .probe(.blocked(.keychainLocked), discoveredByPoll: false),
                                    now: now)
    #expect(result == AuthBlock(kind: .keychainLocked, detectedAt: now))
}

// MARK: - Clearing a block

/// A presence finding refutes an absence finding. This is the recovery path for
/// a user whose sessions never publish a capture — the desktop-app case — and
/// without it the block has no exit at all.
@Test func aProbeFindingACredentialRefutesEveryKindOfBlock() {
    for kind in [AuthBlock.Kind.signedOut, .keychainLocked, .signInExpired] {
        let result = AuthReducer.reduce(block(kind), .probe(.credentialPresent, discoveredByPoll: false),
                                        now: now)
        #expect(result == nil, "\(kind) must be refutable by a credential")
    }
}

/// Proof the API call succeeded, which outranks every local signal.
@Test func aPollThatRefreshedTheCacheClearsAnyBlock() {
    #expect(AuthReducer.reduce(block(.signInExpired), .pollRefreshedCache, now: now) == nil)
}

/// ⚠️ And it can never *set* one — there is no path from an API success to a
/// blocked state, whatever else was gathered in the same cycle.
@Test func aRefreshedCacheNeverSetsABlock() {
    #expect(AuthReducer.reduce(nil, .pollRefreshedCache, now: now) == nil)
}

/// A capture proven minted after the block was observed is proof the CLI reached
/// Anthropic since.
@Test func aCaptureProvenAfterTheBlockClearsIt() {
    #expect(AuthReducer.reduce(block(.signedOut, at: earlier), .captureProven(at: now), now: now) == nil)
}

/// ⚠️ The other direction, which is the whole reason the instant is compared at
/// all: a capture minted *before* the block describes a period the block already
/// accounts for, and must leave it standing.
@Test func aCaptureProvenBeforeTheBlockLeavesItStanding() {
    let standing = block(.signedOut, at: now)
    #expect(AuthReducer.reduce(standing, .captureProven(at: earlier), now: later) == standing)
}

// MARK: - Absence of evidence

/// 🔴 A probe that could not run — spawn failed, timed out, `claude` moved — is
/// not evidence in either direction. Reading it as healthy would clear a real
/// block; reading it as blocked would gate polling on a machine whose only
/// problem is an unusual install path.
@Test func aProbeWithNoAnswerChangesNothing() {
    let standing = block(.signedOut, at: earlier)
    #expect(AuthReducer.reduce(standing, .probe(.noAnswer, discoveredByPoll: false), now: now) == standing)
    #expect(AuthReducer.reduce(nil, .probe(.noAnswer, discoveredByPoll: true), now: now) == nil)
}

// MARK: - Sequences

/// The four-row detection table, walked end to end.
@Test func theDetectionTableHoldsAcrossAWholeCycle() {
    // Row 2: healthy probe, poll refreshed → nothing.
    var state = AuthReducer.reduce(nil, .probe(.credentialPresent, discoveredByPoll: false), now: now)
    state = AuthReducer.reduce(state, .pollRefreshedCache, now: now)
    #expect(state == nil)

    // Row 4: healthy probe, poll unmoved, re-probe still healthy → still
    // nothing. Throttling and a network blip both land here, and both must.
    state = AuthReducer.reduce(state, .probe(.credentialPresent, discoveredByPoll: true), now: now)
    #expect(state == nil)

    // Row 3: healthy probe, poll unmoved, re-probe finds no credential → the
    // poll discovered a lapse.
    state = AuthReducer.reduce(state, .probe(.blocked(.signedOut), discoveredByPoll: true), now: now)
    #expect(state?.kind == .signInExpired)

    // Recovery: the user signs in, a terminal turn publishes a proven capture.
    state = AuthReducer.reduce(state, .captureProven(at: later), now: later)
    #expect(state == nil)
}

/// 🔴 The closed loop, asserted directly: a block gates polling, so recovery
/// must not depend on a poll. A probe alone has to be able to open it.
@Test func recoveryNeverDependsOnSomethingTheBlockPrevents() {
    let standing = block(.signedOut, at: earlier)
    #expect(ClaudeAuthStatus.blocksPolling(standing.kind), "the premise: this state gates polling")
    let reopened = AuthReducer.reduce(standing, .probe(.credentialPresent, discoveredByPoll: false),
                                      now: now)
    #expect(reopened == nil, "a probe alone must be able to clear it")
}
