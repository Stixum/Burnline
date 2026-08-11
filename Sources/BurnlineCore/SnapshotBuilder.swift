import Foundation

/// Pure: cache + settings + now → one immutable `Snapshot`.
public enum SnapshotBuilder {
    public static func build(cache: ScanCache, settings: BurnlineSettings,
                             now: Date, isScanning: Bool) -> Snapshot {
        let window = WindowMath.window(for: settings.resetSchedule, now: now)
        let units = cache.units(from: window.start, to: window.end)

        let estimated = Calibration.estimatedPercent(
            unitsInWindow: units, anchors: settings.calibrationAnchors, now: now)
        let projected = Projection.projectedPercent(
            estimatedPercent: estimated, elapsedFraction: window.elapsedFraction)

        return Snapshot(
            window: window,
            targetPercent: window.targetPercent,
            estimatedPercent: estimated,
            projectedPercent: projected,
            unitsInWindow: units,
            calibrationAge: Calibration.age(of: settings.calibrationAnchors, now: now),
            isScanning: isScanning
        )
    }
}
