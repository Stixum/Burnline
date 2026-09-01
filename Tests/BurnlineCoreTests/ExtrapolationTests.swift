import Testing
import Foundation
@testable import BurnlineCore

/// `1_800_000_000` is exactly a 15-minute bucket boundary (it divides by 900),
/// so offsets from it place events at known positions inside a bucket.
private let bucketStart = Date(timeIntervalSince1970: 1_800_000_000)

private func settings() -> BurnlineSettings {
    var settings = BurnlineSettings.default
    settings.resetSchedule = ResetSchedule(weekday: 5, hour: 9,
                                           timeZone: TimeZone(identifier: "America/Chicago")!)
    return settings
}

/// The model every fixture below is attributed to. `Weights.default` gives
/// sonnet a multiplier of exactly `1.0`.
private let fixtureModel = "claude-sonnet-5"

/// Cells hold raw tokens now, so a fixture is a token count and the weighted
/// total is derived rather than stated.
///
/// Every fixture is input tokens on a sonnet model, which under `Weights.default`
/// is the identity mapping — `input: 1.0` × sonnet `1.0` — so `n` input tokens
/// render to exactly `n` units. That keeps the unit figures each test's
/// arithmetic reasons about ("9,000 units bought 64%") the same numbers they
/// were, and `extrapolationFixtureTokensRenderOneForOneToUnits` below proves the
/// mapping rather than leaving it assumed.
private func cache(_ entries: [(Date, Int)]) -> ScanCache {
    var cells: [String: [String: TokenCounts]] = [:]
    for (date, tokens) in entries {
        cells[String(Bucket.key(for: date)), default: [:]][fixtureModel, default: .zero]
            += TokenCounts(input: tokens)
    }
    var cache = ScanCache()
    cache.files["a.jsonl"] = FileState(modifiedAt: .distantFuture, size: 1, offset: 1,
                                       cells: cells)
    return cache
}

private func capture(percent: Double, at captured: Date, now: Date) -> RateLimitCapture {
    RateLimitCapture(
        version: 1,
        capturedAt: captured.timeIntervalSince1970,
        sevenDay: .init(usedPercent: percent,
                        resetsAt: now.addingTimeInterval(2 * 86_400).timeIntervalSince1970),
        fiveHour: nil)
}

private func estimate(cache: ScanCache, capture: RateLimitCapture, now: Date) -> Double? {
    SnapshotBuilder.build(cache: cache, settings: settings(), rateLimit: capture,
                          now: now, isScanning: false).estimatedPercent
}

/// Guards the identity mapping every fixture below leans on. If a default weight
/// or the sonnet multiplier ever moves, this fails here rather than silently
/// shifting every expected percentage in this file.
@Test func extrapolationFixtureTokensRenderOneForOneToUnits() {
    let scan = cache([(bucketStart, 9_000)])
    #expect(abs(scan.units(from: bucketStart, to: bucketStart.addingTimeInterval(900),
                           weights: .default) - 9_000) < 1e-9)
}

/// The capture's own 15-minute bucket straddles the capture instant, and the
/// sub-bucket detail was never stored. Counting the whole bucket as "burned
/// since the capture" double-counts usage the captured percentage already
/// includes — it is not extrapolation, it is invention.
@Test func usageInsideTheCapturesOwnBucketIsNotCountedAsDriftSinceTheCapture() {
    let now = bucketStart.addingTimeInterval(300)
    let captured = bucketStart.addingTimeInterval(290)   // same bucket as `now`
    let window = bucketStart.addingTimeInterval(-3 * 86_400)

    let scan = cache([(window, 9_000), (now, 1_000)])

    #expect(estimate(cache: scan, capture: capture(percent: 64, at: captured, now: now),
                     now: now) == 64)
}

/// The symptom as reported: the displayed percentage fell as time passed, with
/// the captured value unchanged the whole time. Usage inside a window is
/// cumulative and can never go backwards.
@Test func theEstimateDoesNotFallWhenTheClockCrossesABucketBoundary() {
    let window = bucketStart.addingTimeInterval(-3 * 86_400)

    // Late in the capture's own bucket, with that bucket carrying usage.
    let lateInBucket = bucketStart.addingTimeInterval(840)
    let scanBefore = cache([(window, 9_000), (lateInBucket, 1_000)])
    let before = estimate(cache: scanBefore,
                          capture: capture(percent: 64,
                                           at: bucketStart.addingTimeInterval(830),
                                           now: lateInBucket),
                          now: lateInBucket)

    // Just into the next bucket, a fresh capture reporting the same percentage
    // and no new usage yet.
    let earlyInNext = bucketStart.addingTimeInterval(960)
    let after = estimate(cache: scanBefore,
                         capture: capture(percent: 64,
                                          at: bucketStart.addingTimeInterval(950),
                                          now: earlyInNext),
                         now: earlyInNext)

    #expect(before != nil && after != nil)
    #expect(after! >= before!)
}

/// The counterweight: extrapolation still has to work. A bucket that closed
/// after the capture's own bucket is genuinely usage the capture never saw.
@Test func usageInLaterBucketsStillExtrapolatesForward() {
    let now = bucketStart.addingTimeInterval(1_000)       // bucket +1
    let captured = bucketStart.addingTimeInterval(100)    // bucket +0
    let window = bucketStart.addingTimeInterval(-3 * 86_400)

    let scan = cache([(window, 9_000), (now, 1_000)])
    let result = estimate(cache: scan, capture: capture(percent: 64, at: captured, now: now),
                          now: now)

    // 9,000 units bought 64% -> 140.625 units per point; 1,000 more -> +7.11.
    #expect(result != nil)
    #expect(abs(result! - 71.111) < 0.01)
}

/// A capture is a floor, never a ceiling: nothing may drag the figure below what
/// Claude Code actually reported.
@Test func theEstimateNeverDropsBelowTheCapturedPercentage() {
    let now = bucketStart.addingTimeInterval(300)
    let captured = bucketStart.addingTimeInterval(290)
    let window = bucketStart.addingTimeInterval(-3 * 86_400)

    let scan = cache([(window, 9_000), (now, 5_000)])
    let result = estimate(cache: scan, capture: capture(percent: 64, at: captured, now: now),
                          now: now)

    #expect(result != nil && result! >= 64)
}

// MARK: - The denominator is the allowance epoch, not the window

// The flagship shape, as observed on 2026-09-01: a window already holding a
// great deal of usage, the weekly allowance re-issued *inside* it, and a little
// usage since. Measured from `window.start` the units-per-percent is inflated by
// the whole pre-re-grant week, so the figure barely moves; measured from the
// epoch it tracks.
//
// ⚠️ `window.start`, the epoch start and the capture instant are three
// same-typed instants, and any of them compiles at either `units(...)` call.
// The fixture keeps all three distinct and puts usage in every gap between
// them, so a wrong one cannot coincide with the right one.
private let epochStart = bucketStart.addingTimeInterval(-3_600)
/// Before the re-grant, inside the window. This is the 16,000 units that must
/// NOT be in the denominator.
private let beforeEpoch = bucketStart.addingTimeInterval(-3 * 86_400)
/// After the re-grant, before the capture: the epoch's own 1,000 units.
private let insideEpoch = bucketStart.addingTimeInterval(-1_800)
private let epochCaptured = bucketStart.addingTimeInterval(100)
/// A later bucket than the capture's own, so it is genuinely drift since.
private let afterCapture = bucketStart.addingTimeInterval(950)
private let epochNow = bucketStart.addingTimeInterval(1_000)

private func estimate(cache: ScanCache, capture: RateLimitCapture, now: Date,
                      regrant: RateLimitHighWater.Regrant?) -> Double? {
    SnapshotBuilder.build(cache: cache, settings: settings(), rateLimit: capture,
                          now: now, isScanning: false, regrant: regrant).estimatedPercent
}

private func regrant(at started: Date, startPercent: Double) -> RateLimitHighWater.Regrant {
    .init(startedAt: started.timeIntervalSince1970, startPercent: startPercent)
}

/// 🔴 The window holds 17,000 units at the capture instant and the epoch holds
/// 1,000 — a 17x gap, so no denominator can be swapped for another and still
/// land on this answer.
///
/// Epoch: 1,000 units bought (5 - 1) = 4 points -> 250 units per point; 500 more
/// units -> 5 + 2 = **7.0**.
///
/// Every wrong denominator lands somewhere else entirely:
/// - both measured from `window.start` (today's code): 17,000/5 -> 5.147
/// - only `unitsAtCapture` re-based: since = 17,500 - 1,000 -> 71.0
/// - only `unitsNow` re-based: since clamps to 0 -> 5.0
/// - `startPercent` not subtracted: 1,000/5 -> 7.5
@Test func extrapolationScalesByTheEpochsUnitsNotTheWindowsUnits() {
    let scan = cache([(beforeEpoch, 16_000), (insideEpoch, 1_000), (afterCapture, 500)])
    let result = estimate(cache: scan,
                          capture: capture(percent: 5, at: epochCaptured, now: epochNow),
                          now: epochNow,
                          regrant: regrant(at: epochStart, startPercent: 1))

    #expect(result != nil)
    #expect(abs(result! - 7.0) < 0.01)
}

/// Constraint C: `unitsInWindow` is labelled "units in window" and is a true
/// fact about the week. Only the extrapolation's internal denominator re-bases.
@Test func theSnapshotStillReportsUnitsForTheWholeWindowAcrossARegrant() {
    let snapshot = SnapshotBuilder.build(
        cache: cache([(beforeEpoch, 16_000), (insideEpoch, 1_000), (afterCapture, 500)]),
        settings: settings(),
        rateLimit: capture(percent: 5, at: epochCaptured, now: epochNow),
        now: epochNow, isScanning: false,
        regrant: regrant(at: epochStart, startPercent: 1))

    #expect(abs(snapshot.unitsInWindow - 17_500) < 1e-9)
}

/// 🔴 An epoch RE-BASES; it does not merely open once. The real second-re-grant
/// shape is 51 -> 0, a climb to 20, then 20 -> 0, and `RateLimitHighWater`
/// replaces the `Regrant` wholesale when that happens. So the epoch start has to
/// be read from `regrant.startedAt` every time — an implementation that latched
/// it when the epoch first appeared is stale by the whole first epoch's
/// consumption, which is this same bug one level down.
///
/// Second epoch: 1,000 units / 4 points -> 7.0. First epoch would see 5,000
/// units -> 5.4; the window would see 21,000 -> 5.095.
@Test func extrapolationRebasesOntoASecondRegrantsEpoch() {
    let firstEpoch = bucketStart.addingTimeInterval(-7_200)
    let insideFirstEpoch = bucketStart.addingTimeInterval(-5_400)

    let scan = cache([(beforeEpoch, 16_000), (insideFirstEpoch, 4_000),
                      (insideEpoch, 1_000), (afterCapture, 500)])
    let result = estimate(cache: scan,
                          capture: capture(percent: 5, at: epochCaptured, now: epochNow),
                          now: epochNow,
                          regrant: regrant(at: epochStart, startPercent: 1))

    #expect(result != nil)
    #expect(abs(result! - 7.0) < 0.01, "the SECOND epoch's units, not the first's")
    #expect(firstEpoch < epochStart, "the fixture's two epochs really are distinct")
}

/// The same claim end to end: the `Regrant` a second material drop actually
/// produces is the one the extrapolation divides by. The builder test above
/// takes the epoch as given, so it cannot see a `reconcile` that swallowed the
/// second drop.
@Test func theEpochFromASecondMaterialDropIsTheOneExtrapolatedFrom() {
    let resetsAt = epochNow.addingTimeInterval(2 * 86_400).timeIntervalSince1970
    let firstEpoch = bucketStart.addingTimeInterval(-7_200)
    let insideFirstEpoch = bucketStart.addingTimeInterval(-5_400)

    func proven(_ percent: Double, at captured: Date, provenAt: Date) -> RateLimitCapture {
        var capture = RateLimitCapture(version: 1, capturedAt: captured.timeIntervalSince1970,
                                       sevenDay: .init(usedPercent: percent, resetsAt: resetsAt),
                                       fiveHour: nil)
        capture.provenAt = provenAt.timeIntervalSince1970
        return capture
    }

    // 51% -> 20% opens the first epoch, 20% -> 1% re-bases onto the second, and
    // a later 5% climbs inside it.
    let opening = bucketStart.addingTimeInterval(-9_000)
    let (_, at51) = RateLimitHighWater.reconcile(proven(51, at: opening, provenAt: opening),
                                                 against: .empty)
    let (_, first) = RateLimitHighWater.reconcile(proven(20, at: firstEpoch, provenAt: firstEpoch),
                                                  against: at51)
    let (_, second) = RateLimitHighWater.reconcile(proven(1, at: epochStart, provenAt: epochStart),
                                                   against: first)
    let (trusted, mark) = RateLimitHighWater.reconcile(
        proven(5, at: epochCaptured, provenAt: epochCaptured), against: second)

    #expect(mark.sevenDay?.regrant?.startedAt == epochStart.timeIntervalSince1970,
            "the pipeline re-based onto the second drop")

    let scan = cache([(beforeEpoch, 16_000), (insideFirstEpoch, 4_000),
                      (insideEpoch, 1_000), (afterCapture, 500)])
    let result = estimate(cache: scan, capture: trusted, now: epochNow,
                          regrant: mark.sevenDay?.regrant)

    #expect(result != nil)
    #expect(abs(result! - 7.0) < 0.01)
}

/// The noise guard applies to the epoch's own progress, not to the raw
/// percentage. 1.5% against an epoch that opened at 1% is half a point of
/// signal — dividing by it is the same near-zero denominator the guard exists
/// to refuse, even though 1.5 clears the threshold on its own.
///
/// Guarding on `observed` instead extrapolates: 1,000/0.5 -> 1.75, or 1,000/1.5
/// -> 2.25 if the divisor was left unchanged too.
@Test func theExtrapolationGuardMeasuresProgressInsideTheEpoch() {
    let scan = cache([(beforeEpoch, 16_000), (insideEpoch, 1_000), (afterCapture, 500)])
    let result = estimate(cache: scan,
                          capture: capture(percent: 1.5, at: epochCaptured, now: epochNow),
                          now: epochNow,
                          regrant: regrant(at: epochStart, startPercent: 1))

    #expect(result == 1.5, "reported exactly, never scaled by half a point")
}

/// Immediately after a re-grant the epoch holds no local units at all, and there
/// is nothing to derive a rate from — so the capture is reported unchanged. The
/// window's 16,000 units are not a substitute: they bought the *previous*
/// allowance's percentage.
@Test func anEpochWithNoUnitsYetReportsTheCaptureUnscaled() {
    let scan = cache([(beforeEpoch, 16_000), (afterCapture, 500)])
    let result = estimate(cache: scan,
                          capture: capture(percent: 5, at: epochCaptured, now: epochNow),
                          now: epochNow,
                          regrant: regrant(at: epochStart, startPercent: 1))

    #expect(result == 5, "window units would have produced 5.125")
}

/// The window-membership gate, exercised with a LIVE capture — the case the
/// pace-only test above cannot reach. An epoch that started before this window
/// is not this window's epoch, and re-basing on it would measure the
/// denominator from an instant outside the period being measured.
@Test func anEpochStartingBeforeTheWindowDoesNotRebaseALiveExtrapolation() {
    let scan = cache([(beforeEpoch, 16_000), (insideEpoch, 1_000), (afterCapture, 500)])
    let live = capture(percent: 5, at: epochCaptured, now: epochNow)

    let base = SnapshotBuilder.build(cache: scan, settings: settings(), rateLimit: live,
                                     now: epochNow, isScanning: false)
    let outside = base.window.start.addingTimeInterval(-3_600)
    let snapshot = SnapshotBuilder.build(cache: scan, settings: settings(), rateLimit: live,
                                         now: epochNow, isScanning: false,
                                         regrant: regrant(at: outside, startPercent: 1))

    #expect(snapshot.regrant == nil)
    #expect(snapshot.estimatedPercent == base.estimatedPercent)
    // Positive control: this fixture DOES move when a valid epoch is applied, so
    // the equality above is a refusal rather than a fixture that never differs.
    #expect(abs(base.estimatedPercent! - 5.147) < 0.01)
}

/// 🔴 A re-grant implies a live capture, structurally: the epoch is scoped
/// inside the `.live` branch, exactly like `capturedPercent`. Nothing outside
/// that branch is measured against the epoch — a calibrated estimate counts from
/// `window.start` — so carrying one there would offer every later reader
/// (projection, notifications, the popover row) an epoch that nothing in the
/// figure it decorates was measured from.
@Test func anEpochIsNotCarriedWithoutALiveCapture() {
    let now = epochNow
    let window = WindowMath.window(for: settings().resetSchedule, now: now)

    let snapshot = SnapshotBuilder.build(
        cache: cache([(beforeEpoch, 16_000)]), settings: settings(), rateLimit: nil,
        now: now, isScanning: false,
        regrant: regrant(at: window.start.addingTimeInterval(3_600), startPercent: 1))

    #expect(snapshot.source == .paceOnly)
    #expect(snapshot.regrant == nil)
}

/// The `.calibrated` counterpart, and it needs a real anchor to exist: with no
/// anchors the build falls through to `.paceOnly` and the calibrated branch is
/// never entered, so the sibling test above cannot speak for it. Asserting the
/// source is what proves the branch under test actually ran.
///
/// A calibrated estimate is `unitsInWindow` over a fitted units-per-percent,
/// counted from `window.start`. An epoch handed out beside it would tell
/// `Projection` — which may assume a re-grant implies a live capture — to
/// re-base a figure that was never measured from the epoch.
@Test func anEpochIsNotCarriedBesideACalibratedEstimate() {
    let now = epochNow
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    var calibrated = settings()
    calibrated.calibrationAnchors = [
        CalibrationAnchor(timestamp: now.addingTimeInterval(-86_400),
                          observedPercent: 20, unitsInWindow: 4_000)
    ]

    let snapshot = SnapshotBuilder.build(
        cache: cache([(window.start.addingTimeInterval(3_600), 16_000)]),
        settings: calibrated, rateLimit: nil, now: now, isScanning: false,
        regrant: regrant(at: window.start.addingTimeInterval(7_200), startPercent: 1))

    #expect(snapshot.source == .calibrated, "the branch under test really ran")
    #expect(snapshot.estimatedPercent != nil, "16,000 units over a fitted 200/point")
    #expect(snapshot.regrant == nil)
}

/// The window gate is a half-open interval, matching the capture guard beside
/// it and `Window` itself. Both boundaries are pinned because both comparisons
/// flip silently: `>` at the start refuses an epoch that opened exactly at the
/// reset — reachable, since a re-grant landing on the boundary is precisely
/// when the two events coincide — and `<=` at the end admits one dated at an
/// instant this window does not contain.
@Test func theEpochWindowGateIncludesTheStartInstantAndExcludesTheEnd() {
    let scan = cache([(beforeEpoch, 16_000), (insideEpoch, 1_000), (afterCapture, 500)])
    let live = capture(percent: 5, at: epochCaptured, now: epochNow)
    let base = SnapshotBuilder.build(cache: scan, settings: settings(), rateLimit: live,
                                     now: epochNow, isScanning: false)

    func snapshot(epochAt started: Date) -> Snapshot {
        SnapshotBuilder.build(cache: scan, settings: settings(), rateLimit: live,
                              now: epochNow, isScanning: false,
                              regrant: regrant(at: started, startPercent: 1))
    }

    #expect(snapshot(epochAt: base.window.start).regrant?.startedAt == base.window.start,
            "an epoch opening exactly at the reset is this window's")
    #expect(snapshot(epochAt: base.window.end).regrant == nil,
            "the end instant belongs to the next window")
}
