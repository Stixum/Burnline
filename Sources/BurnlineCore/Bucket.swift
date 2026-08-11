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

    public static func key(for date: Date) -> Int {
        Int((date.timeIntervalSince1970 / seconds).rounded(.down))
    }

    public static func start(ofKey key: Int) -> Date {
        Date(timeIntervalSince1970: Double(key) * seconds)
    }
}
