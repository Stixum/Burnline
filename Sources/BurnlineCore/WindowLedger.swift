import Foundation

/// Decides which completed weekly windows are ready to be written as rows, and
/// with what bounds, totals and provenance.
///
/// Pure: it reads inputs and returns rows. The caller does every byte of I/O.
///
/// 🔴 **Bounds roll back from an observed reset, never from the stored
/// schedule.** `BurnlineSettings.resetSchedule` documents its Thursday 09:00
/// default as a placeholder "replaced by the real reset as soon as a live
/// capture lands" — and nothing ever writes it back; `SnapshotBuilder` simply
/// bypasses it when a capture exists. So on any machine where captures work
/// that setting stays a placeholder forever. A closed window's own capture is
/// dead by definition, so a naive "capture when live, schedule otherwise" rule
/// would use the placeholder for essentially every row, putting every
/// historical boundary on Thursday 09:00 and attributing every token total to
/// the wrong seven-day slice. Rows are written once, so that is wrong forever.
/// The schedule applies only when no reset has *ever* been observed here.
public struct WindowLedger: Sendable {
    /// ⚠️ The tolerance that decides whether two instants are the SAME reset.
    ///
    /// Sub-second disagreement about one reset is the norm here, from two
    /// independent directions:
    ///
    /// - The two capture sources report it to different precision — statusline
    ///   `1786690800`, utilization `…06:59:59.424563Z`, a measured 0.58s apart.
    ///   Under exact equality `.observed` would be dead code no real data could
    ///   reach.
    /// - `HistoryStore` pins `.iso8601`, which encodes WHOLE seconds, so any
    ///   instant that has been through the archive comes back up to a second
    ///   *earlier* than the in-memory one it was written from. Real resets carry
    ///   a fraction: the high-water mark measured on this machine held
    ///   `resetsAt: 1787295600.181`.
    ///
    /// 60s, matching `RateLimitHighWater.sameResetTolerance`, and it can never
    /// merge two windows that are genuinely distinct: **weekly windows are seven
    /// days apart**, so anything within a minute is the same boundary described
    /// twice.
    public static let sameResetTolerance: TimeInterval = 60

    /// A reset actually observed on this machine. Every window bound is a whole
    /// number of calendar weeks from it, in both directions.
    public let anchor: Date?
    public let schedule: ResetSchedule
    /// True when a reset has been seen here at some point, even though the
    /// anchor is presently unknown. That combination means "defer", not
    /// "fall back to the schedule".
    public let hasEverObservedAReset: Bool

    /// A century of weeks. Purely a stop against an absurd `coverage` lower
    /// bound or a calendar that refuses to advance; a real grid is a handful.
    private static let maximumSteps = 5_200

    public init(anchor: Date?, schedule: ResetSchedule, hasEverObservedAReset: Bool = false) {
        self.anchor = anchor
        self.schedule = schedule
        self.hasEverObservedAReset = hasEverObservedAReset
    }

    /// Completed windows whose cells are fully archived and which have not been
    /// written yet, oldest first.
    ///
    /// A window qualifies when it is closed (`end <= now`), starts after
    /// `lastWritten`, and every bucket it owns is covered. An uncovered window
    /// is skipped rather than stopping the walk — a hole in one week does not
    /// make the next week unknowable.
    public func writableRows(coverage: Coverage, lastWritten: Date?,
                             cells: [HistoryRow], tracking: [TrackingEntry],
                             now: Date) -> [WindowRow] {
        // Rule 1. Deferring a row costs nothing; a row written with placeholder
        // bounds is wrong forever.
        if anchor == nil && hasEverObservedAReset { return [] }

        // Nothing is archived, so nothing can be complete.
        guard let earliestCovered = coverage.ranges.first?.lowerBound else { return [] }
        let earliest = Date(timeIntervalSince1970: Double(earliestCovered))

        // With no anchor and no observation ever, the schedule is all there is;
        // its current window start is as good a grid origin as the anchor.
        let origin = anchor ?? WindowMath.window(for: schedule, now: now).start
        let base: BoundsSource = anchor == nil ? .schedule : .extrapolated

        var bounds = Self.grid(origin: origin, earliest: earliest, now: now,
                               timeZone: schedule.timeZone)
        guard bounds.count >= 2 else { return [] }

        // Newest first, so `first(where:)` on a window yields its FINAL reading.
        let newestFirst = tracking.sorted { $0.at > $1.at }
        var rows: [WindowRow] = []

        // `bounds` is mutated in place below but never resized, so the range is
        // stable for the whole walk.
        for cursor in 1..<bounds.count {
            let start = bounds[cursor - 1]
            var end = bounds[cursor]

            // Rule 3. An entry belongs to the window whose [start, end)
            // CONTAINS `at`. Windows are seven days and non-overlapping, so
            // containment is exact and needs no tolerance — unlike comparing
            // two derived boundaries, which can differ by days.
            let entry = newestFirst.first { $0.at >= start && $0.at < end }

            var boundsSource = base
            var observedResetsAt: Date?

            if let entry {
                if abs(entry.resetsAt.timeIntervalSince(end)) <= Self.sameResetTolerance {
                    boundsSource = .observed
                    observedResetsAt = entry.resetsAt
                } else if entry.resetsAt > entry.at,
                          cursor + 1 >= bounds.count || entry.resetsAt < bounds[cursor + 1] {
                    // The observation wins: the grid is an inference, and this
                    // is a reset someone actually saw. Writing it back into
                    // `bounds` moves the NEXT window's start with it, so the
                    // grid stays contiguous and non-overlapping.
                    end = entry.resetsAt
                    bounds[cursor] = end
                    boundsSource = .observed
                    observedResetsAt = entry.resetsAt
                }
            }

            // Rule 2. Closed, unwritten, and every bucket in hand.
            guard end <= now else { continue }

            // 🔴 Within tolerance, not exact. `lastWritten` came back through
            // `.iso8601`, which encodes whole seconds, while `start` came off
            // the in-memory grid with the anchor's fraction still on it — so
            // exact `<=` compares `…00.181` against `…00.000`, never fires, and
            // the same window is appended on every 60s flush forever. That
            // shipped, and the archive it produced held five identical rows.
            // Window starts are seven days apart, so a minute cannot reach the
            // neighbouring one.
            if let lastWritten,
               start.timeIntervalSince(lastWritten) <= Self.sameResetTolerance { continue }

            let firstBucket = Self.firstBucketStart(atOrAfter: start)
            let lastBucket = Self.lastBucketStart(before: end)
            guard firstBucket <= lastBucket else { continue }
            guard coverage.covers(from: firstBucket, through: lastBucket) else { continue }

            // Rule 4. Anthropic's own figure or nothing — never an estimate,
            // never a calibration. `entry` is still contained after any end
            // substitution above, which required `resetsAt > at`.
            rows.append(WindowRow(
                start: start,
                end: end,
                counts: Self.total(of: cells, from: firstBucket, through: lastBucket),
                finalPercent: entry?.percent,
                finalPercentAt: entry?.at,
                finalPercentSource: entry == nil ? nil : "live",
                boundsSource: boundsSource,
                observedResetsAt: observedResetsAt
            ))
        }

        return rows
    }

    /// Newest `observedResetsAt` across written rows — the anchor's recovery
    /// source when the manifest is lost.
    public static func recoverAnchor(from rows: [WindowRow]) -> Date? {
        rows.compactMap(\.observedResetsAt).max()
    }

    // MARK: - Grid

    /// Window boundaries as whole calendar weeks either side of `origin`.
    ///
    /// 🔴 BOTH directions. The anchor is a reset observed before a quit; come
    /// back a fortnight later and the closed windows end at anchor+7d and
    /// anchor+14d, which stepping backward never produces. Their coverage
    /// completes and no row is ever written — silently, which is the absence
    /// this whole feature exists for.
    ///
    /// ⚠️ Always `Calendar.date(byAdding: .day, value: ±7)`, never `±604_800`.
    /// A DST week is 167 or 169 hours and the reset must hold its wall-clock
    /// time across the transition.
    static func grid(origin: Date, earliest: Date, now: Date, timeZone: TimeZone) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var forward: [Date] = []
        var cursor = origin
        var steps = 0
        while cursor <= now, steps < maximumSteps,
              let next = calendar.date(byAdding: .day, value: 7, to: cursor) {
            forward.append(next)
            cursor = next
            steps += 1
        }

        var backward: [Date] = []
        cursor = origin
        steps = 0
        while cursor > earliest, steps < maximumSteps,
              let previous = calendar.date(byAdding: .day, value: -7, to: cursor) {
            backward.append(previous)
            cursor = previous
            steps += 1
        }

        return backward.reversed() + [origin] + forward
    }

    // MARK: - Buckets

    // A window owns the buckets whose START falls in [start, end). Coverage and
    // totals both use exactly this set, so a straddling bucket is counted
    // all-in or all-out consistently in both — at 15 minutes, at most 0.15% of
    // a week. Summing partial buckets is not an option: the sub-bucket detail
    // was never stored.

    static func firstBucketStart(atOrAfter date: Date) -> Int {
        let key = Bucket.key(for: date)
        let start = Bucket.start(ofKey: key)
        let aligned = start < date ? Bucket.start(ofKey: key + 1) : start
        return Int(aligned.timeIntervalSince1970)
    }

    static func lastBucketStart(before date: Date) -> Int {
        let key = Bucket.key(for: date)
        let start = Bucket.start(ofKey: key)
        let aligned = start < date ? start : Bucket.start(ofKey: key - 1)
        return Int(aligned.timeIntervalSince1970)
    }

    private static func total(of cells: [HistoryRow], from: Int, through: Int) -> TokenCounts {
        var counts = TokenCounts.zero
        for cell in cells where cell.bucket >= from && cell.bucket <= through {
            counts += cell.counts
        }
        return counts
    }
}
