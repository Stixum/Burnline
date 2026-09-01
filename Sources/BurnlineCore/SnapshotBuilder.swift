import Foundation

/// Pure: cache + settings + an optional live capture + now → one `Snapshot`.
public enum SnapshotBuilder {

    /// Below this the derived units-per-percent is dominated by noise, so the
    /// exact figure is reported without extrapolating past it.
    private static let minimumExtrapolationPercent: Double = 1

    public static func build(cache: ScanCache,
                             settings: BurnlineSettings,
                             rateLimit: RateLimitCapture? = nil,
                             now: Date,
                             isScanning: Bool,
                             rejected: RateLimitHighWater.RejectedReading? = nil,
                             scopedWeekly: UsageUtilization.ScopedLimit? = nil,
                             regrant: RateLimitHighWater.Regrant? = nil) -> Snapshot {

        // A capture pins the window exactly: its resets_at IS the boundary, so
        // no user-configured schedule is involved.
        let window: Window
        let scheduleIsAutomatic: Bool
        if let capture = rateLimit {
            window = windowFromReset(capture.sevenDay.resetsDate, now: now)
            scheduleIsAutomatic = true
        } else {
            window = WindowMath.window(for: settings.resetSchedule, now: now)
            scheduleIsAutomatic = false
        }

        let units = cache.units(from: window.start, to: window.end, weights: settings.weights)

        let estimated: Double?
        // Anthropic's own figure, without the extrapolation `estimated` carries.
        // It rides the *same* guard deliberately: `windowFromReset` rolls a
        // window forward from a capture whose reset has already passed, so
        // `rateLimit` is non-nil precisely when the capture is dead. A second,
        // looser condition would hand a dead window's percentage to the archive
        // keyed to the current window — permanently wrong, and silently.
        let capturedPercent: Double?
        let source: UsageSource
        // 🔴 Scoped to the live branch on purpose, the same as `capturedPercent`
        // — so "a re-grant implies a live capture" is a fact about the code
        // rather than a rule a test has to remember.
        //
        // An epoch re-bases a figure that was measured from it. Under `.live`
        // that is exactly what `estimated` is. Under `.calibrated` it is not:
        // that estimate comes from `unitsInWindow` and the user's anchors,
        // counted from `window.start`, and offering an epoch alongside it hands
        // every later reader — the projection, the notification identity, the
        // popover row — an epoch that nothing in the figure it decorates was
        // measured from. Under `.paceOnly` there is no usage figure at all.
        let epoch: Snapshot.Regrant?

        // The capture's percentage is only meaningful inside the window it was
        // taken in. Once that window resets, the number is about a period that
        // no longer exists.
        if let capture = rateLimit,
           capture.capturedDate >= window.start,
           capture.capturedDate < window.end {
            epoch = openEpoch(regrant, in: window)
            estimated = extrapolate(capture: capture, cache: cache, window: window,
                                    epoch: epoch, weights: settings.weights)
            capturedPercent = capture.sevenDay.usedPercent
            source = .live(capturedAt: capture.capturedDate)
        } else if let calibrated = Calibration.estimatedPercent(
            unitsInWindow: units, anchors: settings.calibrationAnchors, now: now) {
            estimated = calibrated
            capturedPercent = nil
            epoch = nil
            source = .calibrated
        } else {
            estimated = nil
            capturedPercent = nil
            epoch = nil
            source = .paceOnly
        }

        // The 5-hour reading stands on its own reset instant, so it survives or
        // dies independently of the weekly window.
        let fiveHour = rateLimit?.fiveHour.flatMap { reading -> FiveHourStatus? in
            let remaining = reading.resetsDate.timeIntervalSince(now)
            guard remaining > 0 else { return nil }
            return FiveHourStatus(usedPercent: reading.usedPercent,
                                  resetsAt: reading.resetsDate,
                                  timeRemaining: remaining)
        }

        return Snapshot(
            window: window,
            targetPercent: window.targetPercent,
            estimatedPercent: estimated,
            capturedPercent: capturedPercent,
            // 🔴 The epoch's fraction, never the window's — and note this sits
            // one line below `targetPercent`, which stays the window's. Two
            // denominators on one screen, deliberately: see `Projection`.
            projectedPercent: Projection.projectedPercent(
                estimatedPercent: estimated,
                elapsedFraction: epochElapsedFraction(epoch, in: window),
                epochStartPercent: epoch?.startPercent ?? 0),
            unitsInWindow: units,
            calibrationAge: Calibration.age(of: settings.calibrationAnchors, now: now),
            source: source,
            isScheduleAutomatic: scheduleIsAutomatic,
            isScanning: isScanning,
            dayBoundary: settings.dayBoundary,
            dayTimeZoneIdentifier: settings.resetSchedule.timeZoneIdentifier,
            fiveHour: fiveHour,
            rejectedReading: rejected,
            scopedWeekly: scopedWeekly,
            regrant: epoch
        )
    }

    /// The open allowance epoch, in `Date` terms, when one belongs to `window`.
    ///
    /// An epoch belongs to the window it opened in. A mark outlives its own
    /// window — `reconcile` clears it only once a capture for a *different*
    /// window arrives, and in the gap `CaptureSelection` hands back that dead
    /// mark as a stand-in — so a `Regrant` from the previous window is a
    /// reachable state, not a hypothetical.
    ///
    /// Same shape as the `capturedPercent` guard, and for the same reason:
    /// `windowFromReset` rolls a window forward from a dead capture, and
    /// anything keyed to the old one is then silently wrong about the new one.
    /// Here that would measure the extrapolation's denominator from an instant
    /// that is not in the window being measured.
    private static func openEpoch(_ regrant: RateLimitHighWater.Regrant?,
                                  in window: Window) -> Snapshot.Regrant? {
        guard let regrant else { return nil }
        let startedAt = Date(timeIntervalSince1970: regrant.startedAt)
        guard startedAt >= window.start, startedAt < window.end else { return nil }
        return Snapshot.Regrant(startedAt: startedAt, startPercent: regrant.startPercent)
    }

    /// How far through the **allowance epoch** `now` is: the epoch's own start
    /// to the window's end.
    ///
    /// A re-grant re-issues the allowance without moving `resets_at`, so an
    /// epoch is a shorter run to the same finish line and its fraction is
    /// measured against that shorter span — not against the seven days, of
    /// which most may already be gone. With no epoch open this is
    /// `window.elapsedFraction`, unchanged.
    ///
    /// 🔴 `Projection.minimumElapsedFraction` then lands on *this* fraction,
    /// which is the whole point of computing it here rather than in the view:
    /// mid-week the window is thirty times past the noise floor while a
    /// minutes-old epoch sits right on it, and the epoch is what the rate is
    /// being measured over. Read from `epoch` on every call, like
    /// `extrapolate` — a second re-grant re-bases the epoch wholesale.
    private static func epochElapsedFraction(_ epoch: Snapshot.Regrant?,
                                             in window: Window) -> Double {
        guard let epoch else { return window.elapsedFraction }
        let span = window.end.timeIntervalSince(epoch.startedAt)
        guard span > 0 else { return 0 }
        return min(max(window.now.timeIntervalSince(epoch.startedAt) / span, 0), 1)
    }

    /// The window ending at `reset`, rolled forward in 7-day steps if that
    /// instant has already passed — a capture can outlive its own window.
    private static func windowFromReset(_ reset: Date, now: Date) -> Window {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        var end = reset
        // Calendar arithmetic, not seconds: a DST week is 167 or 169 hours.
        while end <= now {
            end = calendar.date(byAdding: .day, value: 7, to: end) ?? end.addingTimeInterval(7 * 86_400)
        }
        let start = calendar.date(byAdding: .day, value: -7, to: end)
            ?? end.addingTimeInterval(-7 * 86_400)
        return Window(start: start, end: end, now: now)
    }

    /// The exact percentage at capture time, carried forward by whatever has
    /// been burned since.
    ///
    /// The capture supplies both halves of the calibration by itself: the true
    /// percentage, and — paired with the local token count at that instant —
    /// the units-per-percent needed to project past it. No stored anchors, no
    /// user input.
    ///
    /// 🔴 **Everything is measured from the allowance epoch, which is the window
    /// only while no re-grant is open.** `observed` counts from whenever the
    /// current allowance began, so the units it was bought with have to be
    /// counted from the same instant. Post-re-grant that instant is
    /// `regrant.startedAt`: `observed` is the new small percentage while
    /// `window.start` still drags in every token burned under the *previous*
    /// allowance, which inflated units-per-percent ~17x on the observed
    /// 2026-09-01 data and left the figure barely moving between captures.
    ///
    /// **Both cumulative measurements move together, and that is not
    /// cosmetic.** `since` is their difference, so the pre-epoch units cancel
    /// and the answer is the same either way — *provided* both move. Re-base
    /// only `unitsAtCapture` and `since` becomes "everything since the window
    /// started minus the epoch's own units", which on this data reads 71%
    /// instead of 7%. Re-base only `unitsNow` and `since` clamps to zero and
    /// the figure freezes at the capture. `Snapshot.unitsInWindow` is a
    /// different quantity and deliberately does not move: it is a true fact
    /// about the week, not a denominator.
    private static func extrapolate(capture: RateLimitCapture,
                                    cache: ScanCache,
                                    window: Window,
                                    epoch: Snapshot.Regrant?,
                                    weights: Weights) -> Double {
        let observed = capture.sevenDay.usedPercent

        // 🔴 Read from the epoch on EVERY call, never latched on "an epoch
        // exists". A second material drop inside an open epoch re-bases the
        // `Regrant` wholesale (`RateLimitHighWater.best`), which is the real
        // 51 -> 0 -> 20 -> 0 shape; anything that remembered the first epoch is
        // stale by the whole of it — this same error, one level down.
        let epochStart = epoch?.startedAt ?? window.start
        let epochStartPercent = epoch?.startPercent ?? 0

        // The capture's own 15-minute bucket straddles the capture instant, and
        // the sub-bucket detail was never stored — its units can't be split into
        // before and after. Attribute the whole bucket to *before*.
        //
        // Measuring to `capturedDate` instead looks right but isn't: `units` sums
        // whole buckets and excludes the one containing its upper bound, so every
        // token in the capture's own bucket got counted as "burned since the
        // capture" — including the ones already inside the captured percentage.
        // That phantom drift grew across each bucket and collapsed at every
        // boundary, so the figure visibly fell as time passed. Erring the other
        // way costs at most one bucket of genuine drift, and captures land every
        // 30s, so it is corrected almost immediately.
        let captureBucketEnd = Bucket.start(ofKey: Bucket.key(for: capture.capturedDate) + 1)
        let unitsAtCapture = cache.units(from: epochStart, to: captureBucketEnd,
                                         weights: weights)
        let unitsNow = cache.units(from: epochStart, to: window.end, weights: weights)

        // The progress the epoch's units actually bought. Without a re-grant
        // this is `observed` unchanged, so every ordinary window is untouched.
        // The noise guard belongs on this difference, not on `observed`: 1.5%
        // against an epoch that opened at 1% is half a point of signal, and
        // dividing by it is the near-zero denominator the guard exists to
        // refuse — however comfortably 1.5 clears the threshold on its own.
        let observedInEpoch = observed - epochStartPercent

        guard observedInEpoch >= minimumExtrapolationPercent, unitsAtCapture > 0 else {
            // Nothing trustworthy to scale by — report what Claude Code said.
            // Right after a re-grant `unitsAtCapture` is legitimately zero; the
            // window's units are not a stand-in for it, because they bought the
            // percentage of an allowance that no longer applies.
            return observed
        }

        let unitsPerPercent = unitsAtCapture / observedInEpoch
        let since = max(0, unitsNow - unitsAtCapture)
        return observed + since / unitsPerPercent
    }
}
