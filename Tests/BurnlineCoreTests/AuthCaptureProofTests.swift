import Testing
import Foundation
@testable import BurnlineCore

// Where the proof that clears an auth block is allowed to come from.
//
// A block gates polling, so recovery cannot depend on a poll. Two things can
// reopen it: a probe finding a credential, and a capture proven minted after the
// block was observed. This file is about the second, and specifically about the
// field it must be read from — which is not the obvious one.

private let windowReset: TimeInterval = 1_786_690_800

private func capture(_ percent: Double, at captured: TimeInterval,
                     provenAt: TimeInterval? = nil) -> RateLimitCapture {
    var result = RateLimitCapture(version: RateLimitCapture.currentVersion, capturedAt: captured,
                                  sevenDay: .init(usedPercent: percent, resetsAt: windowReset),
                                  fiveHour: nil)
    result.provenAt = provenAt
    return result
}

// MARK: - Reading the proof

@Test func noCandidatesCarryingProofYieldsNoEvidence() {
    #expect(AuthEvidence.fromCaptures([]) == nil)
    #expect(AuthEvidence.fromCaptures([capture(40, at: 1_000)]) == nil)
}

/// The newest proof across all candidates, not the newest candidate's proof.
@Test func theNewestProofAcrossCandidatesWins() {
    let candidates = [capture(40, at: 1_000, provenAt: 1_000),
                      capture(41, at: 5_000, provenAt: 9_000),
                      capture(42, at: 8_000)]
    #expect(AuthEvidence.fromCaptures(candidates)
            == .captureProven(at: Date(timeIntervalSince1970: 9_000)))
}

/// ⚠️ An API success is proof the CLI reached Anthropic whether or not that
/// particular reading went on to win selection — so the proof is taken across
/// every candidate, including ones that will be discarded.
@Test func proofCountsEvenFromACandidateThatWillLoseSelection() {
    let loser = capture(10, at: 1_000, provenAt: 9_000)
    let winner = capture(90, at: 8_000)
    #expect(AuthEvidence.fromCaptures([loser, winner])
            == .captureProven(at: Date(timeIntervalSince1970: 9_000)))
}

// MARK: - Why not the obvious source

/// 🔴 **The positive control for the whole rule.** Reading `provenAt` off the
/// capture the store ends up holding is the natural implementation, it compiles,
/// and it never works: `RateLimitHighWater.reconcile` rebuilds the trusted
/// capture from `version`, `capturedAt`, `sevenDay` and `fiveHour`, and
/// `provenAt` is not among them.
///
/// If this test ever fails because `trusted.provenAt` became non-nil, that is
/// good news — but `AuthEvidence.fromCaptures` should still read the candidates,
/// and this test should be rewritten rather than deleted, because the maximum
/// across candidates is right for its own reasons (see the test above).
@Test func theTrustedCaptureDoesNotCarryProofWhichIsWhyCandidatesAreRead() {
    let proven = capture(40, at: 1_000, provenAt: 1_000)
    let resolution = CaptureSelection.resolve([proven], against: RateLimitHighWater())

    #expect(resolution.trusted?.provenAt == nil,
            "if this changes, re-read AuthEvidence.fromCaptures before trusting it")
    #expect(AuthEvidence.fromCaptures([proven]) != nil,
            "the candidates still carry the proof the trusted capture lost")
}
