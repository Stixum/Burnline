import Testing
import Foundation
@testable import BurnlineCore

private let chicago = TimeZone(identifier: "America/Chicago")!

private func settings(anchors: [CalibrationAnchor] = []) -> BurnlineSettings {
    var settings = BurnlineSettings.default
    settings.resetSchedule = ResetSchedule(weekday: 5, hour: 9, timeZone: chicago)
    settings.calibrationAnchors = anchors
    return settings
}

/// Cells hold raw tokens now. An input token on a sonnet model is the identity
/// mapping under `Weights.default` — `input: 1.0` × sonnet `1.0` — so `units`
/// here is still both the fixture and the weighted total it renders to.
private func cache(units: Int, at date: Date) -> ScanCache {
    var cache = ScanCache()
    cache.files["a.jsonl"] = FileState(
        modifiedAt: date, size: 1, offset: 1,
        cells: [String(Bucket.key(for: date)): ["claude-sonnet-5": TokenCounts(input: units)]])
    return cache
}

@Test func uncalibratedSnapshotHasTargetButNoEstimate() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let snapshot = SnapshotBuilder.build(
        cache: cache(units: 5_000, at: window.start.addingTimeInterval(60)),
        settings: settings(), now: now, isScanning: false)

    #expect(snapshot.estimatedPercent == nil)
    #expect(snapshot.projectedPercent == nil)
    #expect(snapshot.deltaPercent == nil)
    #expect(snapshot.targetPercent > 0)
    #expect(snapshot.isPaceOnly)
}

@Test func calibratedSnapshotProducesEstimateAndDelta() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let anchors = [CalibrationAnchor(timestamp: now.addingTimeInterval(-86_400),
                                     observedPercent: 50, unitsInWindow: 5_000)]
    let snapshot = SnapshotBuilder.build(
        cache: cache(units: 4_000, at: window.start.addingTimeInterval(60)),
        settings: settings(anchors: anchors), now: now, isScanning: false)

    // `#require`, not `!`: Calibration's own rejection rules (below 5%, older
    // than 60 days) are live mutation targets, and each one nils this.
    #expect(abs(try #require(snapshot.estimatedPercent) - 40) < 1e-6)
    #expect(snapshot.isPaceOnly == false)
    // delta is target - estimate: positive means under budget
    #expect(abs(try #require(snapshot.deltaPercent) - (snapshot.targetPercent - 40)) < 1e-6)
}

@Test func unitsOutsideTheWindowDoNotCount() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let snapshot = SnapshotBuilder.build(
        cache: cache(units: 9_999, at: window.start.addingTimeInterval(-86_400)),
        settings: settings(), now: now, isScanning: false)
    #expect(snapshot.unitsInWindow == 0)
}

@Test func isUnderBudgetWhenEstimateTrailsTarget() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = WindowMath.window(for: settings().resetSchedule, now: now)
    let anchors = [CalibrationAnchor(timestamp: now, observedPercent: 50, unitsInWindow: 5_000)]
    let low = SnapshotBuilder.build(cache: cache(units: 10, at: window.start.addingTimeInterval(60)),
                                    settings: settings(anchors: anchors), now: now, isScanning: false)
    #expect(low.isUnderBudget == true)
}

@Test func scanningFlagIsCarriedThrough() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = SnapshotBuilder.build(cache: ScanCache(), settings: settings(),
                                         now: now, isScanning: true)
    #expect(snapshot.isScanning)
}

// MARK: - capturedPercent

/// `1_800_000_000` divides by 900, so it is exactly a 15-minute bucket boundary
/// and offsets from it place usage in known buckets.
private let capturedBucketStart = Date(timeIntervalSince1970: 1_800_000_000)

/// Two-entry cache: the baseline the capture already saw, plus whatever landed
/// after it. `cache(units:at:)` above only holds one entry, and a single entry
/// cannot make the extrapolation differ from the capture.
private func cache(_ entries: [(Date, Int)]) -> ScanCache {
    var cells: [String: [String: TokenCounts]] = [:]
    for (date, tokens) in entries {
        cells[String(Bucket.key(for: date)), default: [:]]["claude-sonnet-5", default: .zero]
            += TokenCounts(input: tokens)
    }
    var cache = ScanCache()
    cache.files["a.jsonl"] = FileState(modifiedAt: .distantFuture, size: 1, offset: 1,
                                       cells: cells)
    return cache
}

private func capture(percent: Double, at captured: Date, resetsAt: Date) -> RateLimitCapture {
    RateLimitCapture(version: 1,
                     capturedAt: captured.timeIntervalSince1970,
                     sevenDay: .init(usedPercent: percent,
                                     resetsAt: resetsAt.timeIntervalSince1970),
                     fiveHour: nil)
}

@Test func capturedPercentIsTheCapturedFigureNotTheExtrapolation() throws {
    // estimatedPercent under .live is the captured figure carried FORWARD by
    // local token counts. Archiving that as a week's final percentage would
    // write an estimate into the one artifact that can never be recomputed.
    // Build a snapshot where local usage has accrued since the capture, so the
    // two figures genuinely differ — equal values would prove nothing.
    let now = capturedBucketStart.addingTimeInterval(1_000)     // bucket +1
    let captured = capturedBucketStart.addingTimeInterval(100)  // bucket +0
    let earlier = capturedBucketStart.addingTimeInterval(-3 * 86_400)

    let snapshot = SnapshotBuilder.build(
        cache: cache([(earlier, 9_000), (now, 1_000)]),
        settings: settings(),
        rateLimit: capture(percent: 64, at: captured,
                           resetsAt: now.addingTimeInterval(2 * 86_400)),
        now: now, isScanning: false)

    // 9,000 units bought 64% -> 140.625 units per point; 1,000 more -> +7.11.
    #expect(snapshot.capturedPercent == 64)
    // `#require`, not `!`: mutating the capture-liveness gate drops this to
    // `.paceOnly`, which nils the estimate.
    #expect(abs(try #require(snapshot.estimatedPercent) - 71.111) < 0.01)
    #expect(snapshot.estimatedPercent != snapshot.capturedPercent)
}

@Test func aDeadCaptureYieldsNoCapturedPercent() {
    // windowFromReset rolls a window forward from a capture whose resets_at has
    // passed, so `rateLimit` is non-nil precisely when the capture is dead.
    // Ungated, that dead window's percentage would be archived as the NEW
    // window's final figure.
    let captured = capturedBucketStart
    let resetsAt = capturedBucketStart.addingTimeInterval(60)
    let now = capturedBucketStart.addingTimeInterval(3 * 86_400)

    let snapshot = SnapshotBuilder.build(
        cache: cache([(captured, 9_000)]),
        settings: settings(),
        rateLimit: capture(percent: 64, at: captured, resetsAt: resetsAt),
        now: now, isScanning: false)

    // The capture is outside the rolled-forward window, so it is not live.
    #expect(snapshot.source == .paceOnly)
    #expect(snapshot.capturedPercent == nil)
}

// MARK: - The allowance epoch

// Anthropic re-issues the weekly allowance INSIDE a window without moving
// `resets_at` (observed 2026-09-01: 51% → 0%). `RateLimitHighWater` records that
// as a `Regrant` on the mark; the snapshot is the single immutable value every
// reader gets, so it has to carry the epoch or each reader recomputes it.

/// 🔴 The epoch-seconds → `Date` boundary is here, and every fixture value is
/// deliberately distinct. `Regrant.startedAt`, the capture's `capturedAt` and
/// `window.start` are three same-typed instants; wiring any of the other two
/// compiles silently. `startPercent` is likewise neither 0 (the value a
/// hardcode would produce, and the value the real 2026-09-01 event re-granted
/// to) nor the capture's own percentage.
@Test func theSnapshotCarriesTheOpenAllowanceEpoch() {
    let captured = capturedBucketStart
    let now = capturedBucketStart.addingTimeInterval(1_000)
    let resetsAt = capturedBucketStart.addingTimeInterval(2 * 86_400)
    let startedAt = capturedBucketStart.addingTimeInterval(-3_600)

    let snapshot = SnapshotBuilder.build(
        cache: cache([(captured, 9_000)]),
        settings: settings(),
        rateLimit: capture(percent: 3, at: captured, resetsAt: resetsAt),
        now: now, isScanning: false,
        regrant: .init(startedAt: startedAt.timeIntervalSince1970, startPercent: 4))

    #expect(snapshot.regrant?.startedAt == startedAt)
    #expect(snapshot.regrant?.startPercent == 4)
    #expect(snapshot.regrant?.startedAt != snapshot.window.start)
    #expect(snapshot.regrant?.startedAt != captured)
}

/// The ordinary case: no epoch has ever opened, so nothing is claimed.
@Test func aSnapshotWithNoEpochCarriesNoRegrant() {
    let captured = capturedBucketStart
    let now = capturedBucketStart.addingTimeInterval(1_000)

    let snapshot = SnapshotBuilder.build(
        cache: cache([(captured, 9_000)]),
        settings: settings(),
        rateLimit: capture(percent: 3, at: captured,
                           resetsAt: capturedBucketStart.addingTimeInterval(2 * 86_400)),
        now: now, isScanning: false)

    #expect(snapshot.regrant == nil)
}

/// 🔴 A mark outlives its own window. `reconcile` only clears it when a capture
/// for a DIFFERENT window arrives, and in the gap `CaptureSelection` hands back
/// that dead mark as a stand-in — so an epoch from the previous window is a
/// reachable state, not a hypothetical. Carrying it forward would date the new
/// window's extrapolation (Task 8) from an instant that is not in it.
///
/// Same guard shape as `capturedPercent` above, and for the same reason.
@Test func anEpochFromAWindowThatHasSinceResetIsNotCarried() {
    let captured = capturedBucketStart
    let resetsAt = capturedBucketStart.addingTimeInterval(60)
    let now = capturedBucketStart.addingTimeInterval(3 * 86_400)

    let snapshot = SnapshotBuilder.build(
        cache: cache([(captured, 9_000)]),
        settings: settings(),
        rateLimit: capture(percent: 3, at: captured, resetsAt: resetsAt),
        now: now, isScanning: false,
        regrant: .init(startedAt: captured.addingTimeInterval(-86_400).timeIntervalSince1970,
                       startPercent: 4))

    // `windowFromReset` rolled the window forward past the epoch's start.
    #expect(snapshot.source == .paceOnly)
    #expect(snapshot.regrant == nil)
}

// MARK: - Projection is measured over the epoch, pace over the window

// 🔴 The formula tests in `ProjectionTests` cannot see the call site. An
// implementation that adds `epochStartPercent` correctly and still passes
// `window.elapsedFraction` satisfies every one of them while leaving the
// projection wrong for the whole epoch — mid-week the window denominator is
// ~0.64 and the epoch's is ~0.05, an order of magnitude apart.
//
// ⚠️ Every fixture instant and percentage below is distinct: `window.start`,
// `regrant.startedAt`, the capture instant and `now` are four same-typed
// `Date`s, and `startPercent` (2), the captured figure (7) and the extrapolated
// estimate (9) are three same-typed `Double`s.

/// `now` is 11,400s into an epoch whose run to the reset is 228,000s — exactly
/// 5% — while the window is ~64.2% elapsed.
private let epochWindowEnd = capturedBucketStart.addingTimeInterval(217_600)
private let epochNow = capturedBucketStart.addingTimeInterval(1_000)
private let epochStartedAt = capturedBucketStart.addingTimeInterval(-10_400)
private let epochCaptured = capturedBucketStart.addingTimeInterval(100)
/// Burned under the *previous* allowance: in the window, out of the epoch.
private let beforeTheEpoch = capturedBucketStart.addingTimeInterval(-3 * 86_400)
/// The epoch's own units, before the capture.
private let insideTheEpoch = capturedBucketStart.addingTimeInterval(-1_800)
/// A later bucket than the capture's own, so it is genuine drift since.
private let afterTheCapture = capturedBucketStart.addingTimeInterval(950)

@Test func theBuilderProjectsOverTheEpochNotTheWindow() throws {
    let snapshot = SnapshotBuilder.build(
        cache: cache([(beforeTheEpoch, 16_000), (insideTheEpoch, 1_000),
                      (afterTheCapture, 400)]),
        settings: settings(),
        rateLimit: capture(percent: 7, at: epochCaptured, resetsAt: epochWindowEnd),
        now: epochNow, isScanning: false,
        regrant: .init(startedAt: epochStartedAt.timeIntervalSince1970, startPercent: 2))

    // The epoch bought 5 points with 1,000 units -> 200/point; 400 more -> 9.
    #expect(abs(try #require(snapshot.estimatedPercent) - 9) < 1e-9)

    // `#require`, not `!`: measuring the epoch's age against the seven days
    // rather than its own run to the reset drops the fraction under the noise
    // floor, and a force unwrap turns that failure into a crash that takes the
    // whole suite's reporting with it.
    let projected = try #require(snapshot.projectedPercent)

    // 2 + (9 - 2) / 0.05 = 142. Every wrong wiring lands elsewhere:
    //   window fraction, offset kept:  2 + 7/0.6419  = 12.9
    //   window fraction, naive:            9/0.6419  = 14.0
    //   epoch fraction, start not added back:  7/0.05 = 140
    //   epoch fraction, start not subtracted:  9/0.05 = 180
    #expect(abs(projected - 142) < 1e-9)

    // Said the other way, against the figure the window denominator produces —
    // computed from the snapshot's own window, so it cannot drift out of date.
    let windowFigure = 2 + (9 - 2) / snapshot.window.elapsedFraction
    #expect(abs(projected - windowFigure) > 100,
            "the window denominator is nowhere near the epoch's")

    // The fixture's premise, stated so a later edit cannot quietly void it.
    #expect(abs(snapshot.window.elapsedFraction - 0.6419) < 0.01,
            "deep into the window, and only 5% into the epoch")

    // 🔴 Pace does NOT re-base. Two denominators on one screen, deliberately:
    // the window did not change, so the target is still the clock's.
    #expect(abs(snapshot.targetPercent - snapshot.window.elapsedFraction * 100) < 1e-9)
    #expect(snapshot.targetPercent < 65)
}

/// 🔴 The noise floor lands on the EPOCH's elapsed fraction, not the window's.
/// Right after a re-grant the epoch holds no units, the estimate is Anthropic's
/// captured figure unscaled, and projecting a rate off a minutes-old denominator
/// is exactly what `minimumElapsedFraction` exists to refuse. Guarding the
/// window's fraction instead never fires here: it is 0.64, thirty times the
/// floor.
@Test func aFreshEpochSuppressesTheProjectionThoughTheWindowIsLongPastTheFloor() {
    let justOpened = epochNow.addingTimeInterval(-4_000)   // 4,000 / 220,600 = 0.0181

    let snapshot = SnapshotBuilder.build(
        cache: cache([(beforeTheEpoch, 16_000)]),
        settings: settings(),
        rateLimit: capture(percent: 7, at: epochCaptured, resetsAt: epochWindowEnd),
        now: epochNow, isScanning: false,
        regrant: .init(startedAt: justOpened.timeIntervalSince1970, startPercent: 2))

    // The epoch holds nothing yet, so the capture is reported unscaled — and an
    // estimate exists, so a nil projection is the denominator's doing and not a
    // missing numerator.
    #expect(snapshot.estimatedPercent == 7)
    #expect(snapshot.regrant != nil)
    #expect(snapshot.projectedPercent == nil)

    // Positive control on the guard: the window's fraction would have sailed past.
    #expect(snapshot.window.elapsedFraction > Projection.minimumElapsedFraction * 30)
}

/// 🔴 POSITIVE CONTROL, at the call site rather than in the formula. Nearly
/// every window has no epoch, and for those the denominator must still be the
/// window's — a re-based projection is a correction for a rare event, not a new
/// default. Nothing else in the suite pins this: the epoch tests above pass
/// unchanged if the no-epoch branch returns anything at all, and a fraction of 0
/// would silently blank the projection for every ordinary week.
@Test func theBuilderStillProjectsOverTheWindowWithNoRegrant() throws {
    let snapshot = SnapshotBuilder.build(
        cache: cache([(beforeTheEpoch, 16_000), (insideTheEpoch, 1_000),
                      (afterTheCapture, 400)]),
        settings: settings(),
        rateLimit: capture(percent: 7, at: epochCaptured, resetsAt: epochWindowEnd),
        now: epochNow, isScanning: false)

    let projected = try #require(snapshot.projectedPercent)
    #expect(snapshot.regrant == nil)

    // The whole window bought the whole 7%: 17,000 units -> 2,428.57/point, and
    // 400 more -> 7.165. Over 0.6419 of the window that lands at ~11.16.
    #expect(abs(try #require(snapshot.estimatedPercent) - 7.1647) < 0.001)
    #expect(projected > 11 && projected < 12)

    // Said definitionally, so the claim is about the wiring and not the digits:
    // estimate over the window's own fraction, no offset anywhere.
    let estimate = try #require(snapshot.estimatedPercent)
    #expect(abs(projected - estimate / snapshot.window.elapsedFraction) < 1e-9)
}

// MARK: - The "Limits re-granted" row

// `Sources/Burnline` has no test target, so every string it renders is
// assembled in this module or it is assembled where nothing can check it. The
// row reads `Limits re-granted   Mon 2:14 PM, was 0%`.

/// Mon 2026-08-10 14:14 UTC. A fixed instant and an explicit zone, because
/// `rowValue` itself renders on `.current` and a test that used it would only be
/// asserting that the machine agrees with itself.
private let regrantInstant = Date(timeIntervalSince1970: 1_786_371_240)
private let utc = TimeZone(identifier: "UTC")!

@Test func theRegrantRowNamesTheInstantAndWhereTheAllowanceOpened() {
    let regrant = Snapshot.Regrant(startedAt: regrantInstant, startPercent: 0)

    #expect(regrant.rowValue(in: utc) == "Mon 2:14 PM, was 0%")
}

/// 🔴 The weekday is not decoration. An epoch can have opened days back inside a
/// seven-day window, and `2:14 PM` alone names seven different instants.
@Test func theRegrantRowCarriesTheWeekdayNotJustTheClockTime() {
    let regrant = Snapshot.Regrant(startedAt: regrantInstant.addingTimeInterval(-2 * 86_400),
                                   startPercent: 0)

    #expect(regrant.rowValue(in: utc) == "Sat 2:14 PM, was 0%")
}

/// The zone is honoured rather than ignored — the same instant, read on the
/// clock the user was actually looking at. `chicago` is UTC-5 in August.
@Test func theRegrantRowRendersOnTheGivenClock() {
    let regrant = Snapshot.Regrant(startedAt: regrantInstant, startPercent: 0)

    #expect(regrant.rowValue(in: chicago) == "Mon 9:14 AM, was 0%")
}

/// `was 0%` is the ordinary case — the real 2026-09-01 event re-granted to zero
/// — so a fixture at 0 alone cannot tell `startPercent` from a hardcoded 0.
@Test func theRegrantRowReportsTheEpochsOwnStartPercent() {
    let regrant = Snapshot.Regrant(startedAt: regrantInstant, startPercent: 4)

    #expect(regrant.rowValue(in: utc) == "Mon 2:14 PM, was 4%")
}

/// Through `DisplayValue`, like every other figure: it rounds, and it saturates
/// rather than trapping on a value out of `Int`'s range. Every percentage in
/// this app descends from JSON on disk.
@Test func theRegrantRowRoundsAndSaturatesLikeEveryOtherFigure() {
    #expect(Snapshot.Regrant(startedAt: regrantInstant, startPercent: 51.6)
        .rowValue(in: utc) == "Mon 2:14 PM, was 52%")
    #expect(Snapshot.Regrant(startedAt: regrantInstant, startPercent: 1e20)
        .rowValue(in: utc) == "Mon 2:14 PM, was 999%")
}

// MARK: - The projection row names its denominator

// 🔴 Two rates against two spans sit on one screen once an epoch opens: the pace
// target is measured over the window and the projection over the epoch (see
// `Projection`). That is deliberate, and until now the screen said so nowhere —
// "At this rate" silently meant "at this rate since the re-grant".

@Test func theProjectionRowIsLabelledForTheWindowWithNoEpochOpen() {
    let snapshot = SnapshotBuilder.build(
        cache: cache([(capturedBucketStart, 9_000)]),
        settings: settings(),
        rateLimit: capture(percent: 3, at: capturedBucketStart,
                           resetsAt: capturedBucketStart.addingTimeInterval(2 * 86_400)),
        now: capturedBucketStart.addingTimeInterval(1_000), isScanning: false)

    #expect(snapshot.regrant == nil)
    #expect(snapshot.projectionLabel == "At this rate")
}

/// Built through the real builder rather than by hand: the label follows the
/// epoch the snapshot actually carries, and `openEpoch` is what decides whether
/// there is one.
@Test func theProjectionRowNamesTheRegrantOnceAnEpochIsOpen() {
    let snapshot = SnapshotBuilder.build(
        cache: cache([(capturedBucketStart, 9_000)]),
        settings: settings(),
        rateLimit: capture(percent: 3, at: capturedBucketStart,
                           resetsAt: capturedBucketStart.addingTimeInterval(2 * 86_400)),
        now: capturedBucketStart.addingTimeInterval(1_000), isScanning: false,
        regrant: .init(startedAt: capturedBucketStart.addingTimeInterval(-3_600)
                                                     .timeIntervalSince1970,
                       startPercent: 4))

    #expect(snapshot.regrant != nil)
    #expect(snapshot.projectionLabel == "Rate since re-grant")
}
