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
                             isScanning: Bool) -> Snapshot {

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

        let units = cache.units(from: window.start, to: window.end)

        let estimated: Double?
        let source: UsageSource

        // The capture's percentage is only meaningful inside the window it was
        // taken in. Once that window resets, the number is about a period that
        // no longer exists.
        if let capture = rateLimit,
           capture.capturedDate >= window.start,
           capture.capturedDate < window.end {
            estimated = extrapolate(capture: capture, cache: cache, window: window)
            source = .live(capturedAt: capture.capturedDate)
        } else if let calibrated = Calibration.estimatedPercent(
            unitsInWindow: units, anchors: settings.calibrationAnchors, now: now) {
            estimated = calibrated
            source = .calibrated
        } else {
            estimated = nil
            source = .paceOnly
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
            dayTimeZoneIdentifier: settings.resetSchedule.timeZoneIdentifier
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
                                    window: Window) -> Double {
        let observed = capture.sevenDay.usedPercent
        let unitsAtCapture = cache.units(from: window.start, to: capture.capturedDate)
        let unitsNow = cache.units(from: window.start, to: window.end)

        guard observed >= minimumExtrapolationPercent, unitsAtCapture > 0 else {
            // Nothing trustworthy to scale by — report what Claude Code said.
            return observed
        }

        let unitsPerPercent = unitsAtCapture / observed
        let since = max(0, unitsNow - unitsAtCapture)
        return observed + since / unitsPerPercent
    }
}
