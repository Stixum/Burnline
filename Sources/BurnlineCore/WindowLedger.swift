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
    /// A window qualifies when it is closed (`end <= now`), no row in `written`
    /// already describes it, and every bucket it owns is covered. An uncovered
    /// window is skipped rather than stopping the walk — a hole in one week does
    /// not make the next week unknowable.
    ///
    /// 🔴 `written` is every row the archive holds, NOT a high-water mark.
    /// Coverage grows BACKWARDS on a first launch: the 60s flush commits within
    /// a second of start-up with only what `ScanCache` retains and a row goes
    /// out for it, then the launch fill lands ~20 seconds later with the weeks
    /// behind it. Compare against the newest start alone and every one of those
    /// older weeks is ruled out for being older — 31 days of gapless coverage
    /// produced ONE row, which is the day-one view of this whole feature.
    public func writableRows(coverage: Coverage, written: [WindowRow],
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

            if Self.isAlreadyWritten(start: start, end: end, in: written) { continue }

            let firstBucket = Self.firstBucketStart(atOrAfter: start)
            let lastBucket = Self.lastBucketStart(before: end)
            guard firstBucket <= lastBucket else { continue }
            guard coverage.covers(from: firstBucket, through: lastBucket) else { continue }

            // The re-grant annotation, derived from the entries THIS ROW's
            // bounds contain — after any substitution above, so an instant it
            // names always lies inside the window it describes.
            //
            // 🔴 Per window, never across the series. The last reading of one
            // window and the first of the next are 87% and 4% on an ordinary
            // week: that is the reset, and a walk over the whole series would
            // annotate almost every week as re-granted.
            //
            // A window whose FIRST contained reading is already post-re-grant
            // shows no drop and goes unannotated. That is deliberate — an
            // omitted annotation costs a row a note, a guessed one is wrong
            // forever.
            let contained = Array(newestFirst.filter { $0.at >= start && $0.at < end }.reversed())
            let regrants = Self.regrantObservations(in: contained)

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
                observedResetsAt: observedResetsAt,
                // The LAST re-grant: `finalPercent` is the climb since that
                // one, so only the last pairs with it to describe one stretch
                // of the week. The count keeps the row from claiming there was
                // exactly one.
                regrantedAt: regrants.last?.at,
                percentAtRegrant: regrants.last?.percent,
                regrantsObserved: regrants.isEmpty ? nil : regrants.count
            ))
        }

        return rows
    }

    /// The observations that FOLLOW a material drop, oldest first — one per
    /// re-grant seen in `entries`, which must be one window's own captures in
    /// chronological order.
    ///
    /// 🔴 The threshold is `RateLimitHighWater.materialDropPoints` and is read
    /// from there, never restated. The archive and the live path must agree on
    /// what counts as a re-grant, or a week is annotated as re-granted while no
    /// epoch ever opened, or the reverse — and a 51 → 50 flicker is far likelier
    /// two sources rounding the same figure than a re-issued allowance.
    ///
    /// ⚠️ Materiality is on the ADJACENT drop, not the distance from the epoch
    /// that opened. Settled in the live path, and it is why a second re-grant
    /// inside an open epoch re-bases it rather than being absorbed.
    ///
    /// The returned entry is the one AFTER the drop: the reading before it is
    /// the last of the allowance that ended.
    ///
    /// 🔴 The entries' own `resetsAt` is NEVER compared. A re-grant is a drop
    /// with the reset unmoved, but "unmoved" is established by both readings
    /// being contained in ONE window — not by equality between two `resetsAt`
    /// values. On the live 2026-09-01 event those two values are
    /// `06:59:59Z` and `07:00:00Z`, because the readings came from the two
    /// sources, which report the same instant to different precision. An
    /// equality test there would have missed the only re-grant on record.
    static func regrantObservations(in entries: [TrackingEntry]) -> [TrackingEntry] {
        guard entries.count >= 2 else { return [] }
        return (1..<entries.count).compactMap { index in
            let drop = entries[index - 1].percent - entries[index].percent
            return drop >= RateLimitHighWater.materialDropPoints ? entries[index] : nil
        }
    }

    /// True when a row already tells this window's days.
    ///
    /// By OVERLAP, not by matching starts: the archive is append-only, so any
    /// row sharing days with a candidate means those days would be counted
    /// twice and shown as two weeks. Overlap also survives a grid that
    /// re-phases — a later anchor a few hours off the old one shifts every
    /// boundary, and equal starts would then match nothing.
    ///
    /// 🔴 Overlap must EXCEED the tolerance, and that is the whole subtlety.
    /// `windows.jsonl` round-trips through `.iso8601`, which encodes WHOLE
    /// seconds, while the grid is built from an in-memory anchor that keeps its
    /// fraction (`resetsAt: 1787295600.181`, measured on this machine). So a
    /// candidate ending at `…00.181` laps the stored start of the row after it
    /// by 0.181s, and any-overlap-at-all would read two ADJACENT windows as the
    /// same one and drop the earlier week. In the other direction, treating a
    /// sub-second difference as a new window is what appended the same row on
    /// every 60s flush forever — the archive that shipped held five identical
    /// rows. Real windows are seven days apart, so a minute cannot confuse them.
    static func isAlreadyWritten(start: Date, end: Date, in written: [WindowRow]) -> Bool {
        written.contains { row in
            let shared = min(end, row.end).timeIntervalSince(max(start, row.start))
            return shared > sameResetTolerance
        }
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
