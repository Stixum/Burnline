import Testing
import Foundation
@testable import BurnlineCore

// Whether a launch should stand down because another copy is already up.
//
// Observed 2026-09-11: `/Applications/Burnline.app` and the `build/Burnline.app`
// staging bundle `build.sh` leaves behind ran simultaneously, 14 seconds apart
// at login. They carry the same `CFBundleIdentifier`, so `ApplicationSupport`
// resolved to the same folder for both and neither knew the other existed —
// two writers on `rate-limit-highwater.json`, `scan-cache.json`, `settings.json`
// and the history archive, plus two pollers and two notification evaluators.

@Test func aLoneInstanceRuns() {
    #expect(SingleInstance.verdict(bundleIdentifier: "com.stixum.burnline",
                                   otherInstances: 0) == .run)
}

@Test func aSecondInstanceStandsDown() {
    #expect(SingleInstance.verdict(bundleIdentifier: "com.stixum.burnline",
                                   otherInstances: 1) == .standDown)
}

/// Two already up is the same answer, not a different one — the incumbent wins
/// however many there are.
@Test func moreThanOneIncumbentStillStandsDown() {
    #expect(SingleInstance.verdict(bundleIdentifier: "com.stixum.burnline",
                                   otherInstances: 4) == .standDown)
}

/// 🔴 **The rule that protects every future test on this project.** The debug
/// binary runs outside a bundle, so it has no `Info.plist` and no bundle
/// identifier — and `NSRunningApplication` cannot find peers without one, so the
/// count it reports is meaningless rather than zero. A guard that exited here
/// would kill the screenshot harness, the poll harness, and every manual run
/// from a terminal, and it would do it silently.
///
/// Same shape as the `Bundle.main.bundleIdentifier != nil` guards `Notifier` and
/// `Updater.startAtLaunch()` already carry.
@Test func aBinaryWithNoBundleIdentifierAlwaysRuns() {
    #expect(SingleInstance.verdict(bundleIdentifier: nil, otherInstances: 0) == .run)
    #expect(SingleInstance.verdict(bundleIdentifier: nil, otherInstances: 3) == .run,
            "the harness must run even when the installed app is up — it usually is")
}

/// An empty string is not a bundle identifier. Treated as absent rather than as
/// a name that could match something.
@Test func anEmptyBundleIdentifierIsTreatedAsAbsent() {
    #expect(SingleInstance.verdict(bundleIdentifier: "", otherInstances: 2) == .run)
}

/// ⚠️ A negative count means the caller failed to exclude itself, or miscounted.
/// Standing down on a bad count would be the worst possible failure — the app
/// would refuse to start with no other copy running and nothing on screen.
@Test func anImpossibleCountFailsOpen() {
    #expect(SingleInstance.verdict(bundleIdentifier: "com.stixum.burnline",
                                   otherInstances: -1) == .run)
}

// MARK: - The tie-break

private let app = "com.stixum.burnline"
private func copy(_ startedAt: TimeInterval?, _ pid: Int32) -> SingleInstance.Instance {
    .init(startedAt: startedAt, pid: pid)
}

/// The race the count rule loses: two copies launched together each see the
/// other. Exactly one of the two verdicts must be `.run`.
@Test func ofTwoCopiesLaunchedTogetherExactlyOneRuns() {
    let first = copy(1_000.0, 500), second = copy(1_000.4, 501)
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: first, others: [second]) == .run)
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: second, others: [first]) == .standDown)
}

@Test func copiesStartedInTheSameInstantAreSeparatedByPid() {
    let low = copy(1_000, 500), high = copy(1_000, 501)
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: low, others: [high]) == .run)
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: high, others: [low]) == .standDown)
}

/// The ordinary case: a copy already running for days, whatever its pid.
@Test func aLaterCopyStandsDownForALongRunningOneEvenWithALowerPid() {
    let incumbent = copy(1_000, 90_000), newcomer = copy(500_000, 312)
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: newcomer, others: [incumbent]) == .standDown)
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: incumbent, others: [newcomer]) == .run)
}

/// Two writers on the archive is worse than no copy running, so an ordering
/// that cannot be established is not trusted.
@Test func anUnknownStartTimeFallsBackToStandingDown() {
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: copy(nil, 500),
                                   others: [copy(2_000, 501)]) == .standDown)
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: copy(1_000, 500),
                                   others: [copy(nil, 501)]) == .standDown)
}

@Test func theOldestOfThreeIsTheOnlyOneThatRuns() {
    let a = copy(1, 10), b = copy(2, 11), c = copy(3, 12)
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: a, others: [b, c]) == .run)
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: b, others: [a, c]) == .standDown)
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: c, others: [a, b]) == .standDown)
}

@Test func theTieBreakStillNeverFiresWithoutABundleIdentifier() {
    #expect(SingleInstance.verdict(bundleIdentifier: nil, mine: copy(nil, 500),
                                   others: [copy(1, 2)]) == .run)
    #expect(SingleInstance.verdict(bundleIdentifier: app, mine: copy(nil, 500), others: []) == .run)
}
