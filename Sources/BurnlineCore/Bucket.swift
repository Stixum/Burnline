import Foundation

/// Usage is accumulated into fixed 15-minute buckets.
///
/// Buckets must be per-file so a truncated file's contribution can be dropped
/// wholesale, and a window total sums whole buckets — so a bucket straddling
/// the window boundary is counted all-in or all-out. At 15 minutes that error
/// is at most 0.15% of a 7-day window, and it disappears entirely when the
/// reset lands on a quarter hour.
public enum Bucket {
    public static let seconds: TimeInterval = 900

    /// Beyond ±30,000 years from 1970 a timestamp is nonsense, and the bare
    /// `Int(Double)` below would **trap** on anything larger — including the
    /// infinities a crafted `rate-limits.json` or `scan-cache.json` can produce.
    /// This is the arithmetic path, not a display path, so it clamps here rather
    /// than going through `DisplayValue`.
    private static let epochBound: Double = 1e12

    public static func key(for date: Date) -> Int {
        let epoch = date.timeIntervalSince1970
        guard !epoch.isNaN else { return 0 }
        return Int((min(max(epoch, -epochBound), epochBound) / seconds).rounded(.down))
    }

    public static func start(ofKey key: Int) -> Date {
        Date(timeIntervalSince1970: Double(key) * seconds)
    }
}
