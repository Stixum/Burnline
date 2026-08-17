import Foundation

/// What has been archived, as merged bucket ranges.
///
/// A scalar watermark cannot represent an interior hole, and the design
/// requires one in three places: a week with no data because the app was not
/// running must never look like a week with no usage.
///
/// Held in memory and rebuilt from `coverage.jsonl` at load — deliberately not
/// persisted as a cache. A cache that must be re-derived and validated on every
/// load is already paid for by the re-derivation.
public struct Coverage: Equatable, Sendable {
    /// 🔴 Range algebra runs in BUCKET INDEX space, never epoch seconds.
    ///
    /// Records persist bucket-start epoch seconds (readable in a spreadsheet),
    /// but two contiguous buckets are 900 seconds apart — so `upperBound + 1`
    /// adjacency in second-space never merges them. Converting at the boundary
    /// makes `+1` mean "the next bucket", which is what the merge intends.
    private let indexRanges: [ClosedRange<Int>]
    public let records: [CoverageRecord]

    private static var step: Int { Int(Bucket.seconds) }
    private static func index(_ seconds: Int) -> Int {
        Int((Double(seconds) / Double(step)).rounded(.down))
    }
    private static func seconds(_ index: Int) -> Int { index * step }

    public init(records: [CoverageRecord]) {
        self.records = records
        // Skip inverted records rather than trusting the file.
        self.indexRanges = Coverage.merge(
            records.compactMap { record in
                let lo = Coverage.index(record.from), hi = Coverage.index(record.through)
                return lo <= hi ? lo...hi : nil
            }
        )
    }

    /// Covered ranges, back in epoch seconds for callers and display.
    public var ranges: [ClosedRange<Int>] {
        indexRanges.map { Coverage.seconds($0.lowerBound)...Coverage.seconds($0.upperBound) }
    }

    static func merge(_ input: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        let sorted = input.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    public func contains(_ bucketStart: Int) -> Bool {
        let i = Coverage.index(bucketStart)
        return indexRanges.contains { $0.contains(i) }
    }

    /// The complement of coverage inside `[from, through]`, in epoch seconds,
    /// snapped to whole buckets.
    public func uncovered(from: Int, through: Int) -> [ClosedRange<Int>] {
        let lo = Coverage.index(from), hi = Coverage.index(through)
        guard lo <= hi else { return [] }
        var result: [ClosedRange<Int>] = []
        var cursor = lo
        for range in indexRanges where range.upperBound >= lo && range.lowerBound <= hi {
            if range.lowerBound > cursor {
                result.append(Coverage.seconds(cursor)...Coverage.seconds(range.lowerBound - 1))
            }
            cursor = max(cursor, range.upperBound + 1)
            if cursor > hi { return result }
        }
        if cursor <= hi { result.append(Coverage.seconds(cursor)...Coverage.seconds(hi)) }
        return result
    }

    /// Uncovered stretches *between* covered ranges — permanent holes, as
    /// distinct from "not reached yet".
    public func gaps(in bounds: ClosedRange<Int>) -> [ClosedRange<Int>] {
        guard let first = indexRanges.first, let last = indexRanges.last else { return [] }
        let lo = max(Coverage.index(bounds.lowerBound), first.lowerBound)
        let hi = min(Coverage.index(bounds.upperBound), last.upperBound)
        guard lo <= hi else { return [] }
        return uncovered(from: Coverage.seconds(lo), through: Coverage.seconds(hi))
    }

    /// True when every bucket in `[from, through]` is covered — the test
    /// `WindowLedger` uses to decide a window is writable.
    public func covers(from: Int, through: Int) -> Bool {
        uncovered(from: from, through: through).isEmpty
    }

    public func adding(_ record: CoverageRecord) -> Coverage {
        Coverage(records: records + [record])
    }
}
