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
                             scopedWeekly: UsageUtilization.ScopedLimit? = nil) -> Snapshot {

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
        let source: UsageSource

        // The capture's percentage is only meaningful inside the window it was
        // taken in. Once that window resets, the number is about a period that
        // no longer exists.
        if let capture = rateLimit,
           capture.capturedDate >= window.start,
           capture.capturedDate < window.end {
            estimated = extrapolate(capture: capture, cache: cache, window: window,
                                    weights: settings.weights)
            source = .live(capturedAt: capture.capturedDate)
        } else if let calibrated = Calibration.estimatedPercent(
            unitsInWindow: units, anchors: settings.calibrationAnchors, now: now) {
            estimated = calibrated
            source = .calibrated
        } else {
            estimated = nil
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
            projectedPercent: Projection.projectedPercent(
                estimatedPercent: estimated, elapsedFraction: window.elapsedFraction),
            unitsInWindow: units,
            calibrationAge: Calibration.age(of: settings.calibrationAnchors, now: now),
            source: source,
            isScheduleAutomatic: scheduleIsAutomatic,
            isScanning: isScanning,
            dayBoundary: settings.dayBoundary,
            dayTimeZoneIdentifier: settings.resetSchedule.timeZoneIdentifier,
            fiveHour: fiveHour,
            rejectedReading: rejected,
            scopedWeekly: scopedWeekly
        )
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
    private static func extrapolate(capture: RateLimitCapture,
                                    cache: ScanCache,
                                    window: Window,
                                    weights: Weights) -> Double {
        let observed = capture.sevenDay.usedPercent

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
        let unitsAtCapture = cache.units(from: window.start, to: captureBucketEnd,
                                         weights: weights)
        let unitsNow = cache.units(from: window.start, to: window.end, weights: weights)

        guard observed >= minimumExtrapolationPercent, unitsAtCapture > 0 else {
            // Nothing trustworthy to scale by — report what Claude Code said.
            return observed
        }

        let unitsPerPercent = unitsAtCapture / observed
        let since = max(0, unitsNow - unitsAtCapture)
        return observed + since / unitsPerPercent
    }
}
