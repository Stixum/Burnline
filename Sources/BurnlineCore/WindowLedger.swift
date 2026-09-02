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

        var rows: [WindowRow] = []

        // `bounds` is mutated in place below but never resized, so the range is
        // stable for the whole walk.
        for cursor in 1..<bounds.count {
            let start = bounds[cursor - 1]
            let gridEnd = bounds[cursor]
            var end = gridEnd

            // Rule 3. An entry belongs to the window whose [start, end)
            // CONTAINS `at`. Windows are seven days and non-overlapping, so
            // containment is exact and needs no tolerance — unlike comparing
            // two derived boundaries, which can differ by days.
            let onTheGrid = Self.contained(tracking, from: start, to: end)

            var boundsSource = base
            var observedResetsAt: Date?

            if let newest = onTheGrid.last {
                if abs(newest.resetsAt.timeIntervalSince(end)) <= Self.sameResetTolerance {
                    boundsSource = .observed
                    observedResetsAt = newest.resetsAt
                } else if newest.resetsAt > newest.at,
                          cursor + 1 >= bounds.count || newest.resetsAt < bounds[cursor + 1] {
                    // The observation wins: the grid is an inference, and this
                    // is a reset someone actually saw. Writing it back into
                    // `bounds` moves the NEXT window's start with it, so the
                    // grid stays contiguous and non-overlapping.
                    end = newest.resetsAt
                    bounds[cursor] = end
                    boundsSource = .observed
                    observedResetsAt = newest.resetsAt
                }
            }

            // Rule 2. Closed, unwritten, and every bucket in hand.
            guard end <= now else { continue }

            if Self.isAlreadyWritten(start: start, end: end, in: written) { continue }

            let firstBucket = Self.firstBucketStart(atOrAfter: start)
            let lastBucket = Self.lastBucketStart(before: end)
            guard firstBucket <= lastBucket else { continue }
            guard coverage.covers(from: firstBucket, through: lastBucket) else { continue }

            // 🔴 ONE series backs every reading this row reports, taken from
            // the row's OWN bounds — re-filtered exactly when the substitution
            // above moved them.
            //
            // `finalPercent` used to come from the GRID's newest entry while
            // the annotation came from the substituted bounds, and a later
            // `end` made them different entries: a row could report
            // `finalPercent` 51 from before the re-grant beside an annotation
            // at 3, so `finalPercent − percent` read 48 — a subtraction across
            // two allowances, which is the fabrication this whole feature
            // exists to refuse. `finalPercentAt >= regrant.at` is now true by
            // construction rather than by argument.
            //
            // 🔴 Per window, never across the series. The last reading of one
            // window and the first of the next are 87% and 4% on an ordinary
            // week: that is the reset, and a walk over the whole file would
            // annotate almost every week as re-granted.
            //
            // A window whose FIRST contained reading is already post-re-grant
            // shows no drop and goes unannotated. That is deliberate — an
            // omitted annotation costs a row a note, a guessed one is wrong
            // forever.
            let window = end == gridEnd ? onTheGrid : Self.contained(tracking, from: start, to: end)
            let regrants = Self.regrantObservations(in: window)

            // Rule 4. Anthropic's own figure or nothing — never an estimate,
            // never a calibration. The newest of `window`, which is contained
            // by construction, so no substitution can strand it outside the
            // row that reports it.
            let entry = window.last

            rows.append(WindowRow(
                start: start,
                end: end,
                counts: Self.total(of: cells, from: firstBucket, through: lastBucket),
                finalPercent: entry?.percent,
                finalPercentAt: entry?.at,
                finalPercentSource: entry == nil ? nil : "live",
                boundsSource: boundsSource,
                observedResetsAt: observedResetsAt,
                // The LAST re-grant, carrying the count so the row does not
                // claim there was exactly one. Built through `map` on that
                // last observation: an annotation with no instant behind it is
                // then unspellable rather than merely unwritten.
                regrant: regrants.last.map {
                    WindowRow.RegrantAnnotation(at: $0.at, percent: $0.percent,
                                                observed: regrants.count)
                }
            ))
        }

        return rows
    }

    // MARK: - The re-grant rule
    //
    // 🔴 ONE definition, two callers. `HistoryQuery.percentCurve` draws the
    // discontinuity from the same series this row is annotated from, and the
    // row and the curve describe ONE event: a week the scoreboard calls
    // re-granted must be a week the chart breaks, and the reverse. They
    // diverged for real while each owned its own containment and ordering —
    // the curve sorted ascending with a tie-break, the ledger sorted
    // descending and reversed — so the two disagreed on a same-instant pair.
    // Containment, ordering and materiality all live here now; a caller that
    // reimplements any of the three is reopening that bug.

    /// One window's entries, contained and in a TOTAL chronological order.
    ///
    /// Containment is of the INSTANT in `[start, end)`, the rule an entry is
    /// matched to a window by. Deliberately not the bucket-ownership rule the
    /// unit queries share: a tracking entry is an observation at an instant,
    /// not a fifteen-minute bucket, and rounding one to a bucket would walk
    /// readings across a boundary.
    ///
    /// 🔴 **Ties break on ASCENDING percent, and that is not tidiness.**
    /// `tracking.json` stores `at` through `.iso8601`, which truncates to whole
    /// seconds, while `HistoryWriter.observe` dedupes on FULL equality — so two
    /// readings dated to the same second both survive routinely. Ordered only
    /// by instant, `sort` leaves those two in either order, and the pair reads
    /// as a rise or as a drop depending on which. Measured on the probe that
    /// found this: `[49, 51, 55]` at one instant annotated a re-grant that
    /// never happened, while `[51, 49, 55]` missed one.
    ///
    /// Ascending percent makes the order total — so the series is
    /// deterministic, which `sort` does not otherwise promise — and makes a
    /// transition WITHIN one instant never downward. Two readings sharing an
    /// instant are two sources describing one moment, not an event between two
    /// moments, and must never open an allowance.
    static func contained(_ tracking: [TrackingEntry],
                          from start: Date, to end: Date) -> [TrackingEntry] {
        tracking
            .filter { $0.at >= start && $0.at < end }
            .sorted { $0.at == $1.at ? $0.percent < $1.percent : $0.at < $1.at }
    }

    /// Whether two adjacent readings of one window are a re-grant.
    ///
    /// 🔴 The threshold is `RateLimitHighWater.materialDropPoints` and is read
    /// from there, never restated. The archive and the live path must agree on
    /// what counts as a re-grant, or a week is annotated as re-granted while no
    /// epoch ever opened, or the reverse — and a 51 → 50 flicker is far likelier
    /// two sources rounding one figure than a re-issued allowance.
    ///
    /// ⚠️ Materiality is on the ADJACENT drop, not the distance from the epoch
    /// that opened. Settled in the live path, and it is why a second re-grant
    /// inside an open epoch re-bases it rather than being absorbed.
    ///
    /// 🔴 The entries' own `resetsAt` is NEVER compared. A re-grant is a drop
    /// with the reset unmoved, but "unmoved" is established by both readings
    /// being contained in ONE window — not by equality between two `resetsAt`
    /// values. On the live 2026-09-01 event those two values are `06:59:59Z`
    /// and `07:00:00Z`, because the readings came from the two sources, which
    /// report the same instant to different precision. An equality test there
    /// would have missed the only re-grant on record.
    static func isMaterialDrop(from previous: TrackingEntry, to entry: TrackingEntry) -> Bool {
        previous.percent - entry.percent >= RateLimitHighWater.materialDropPoints
    }

    /// The observations that FOLLOW a material drop, oldest first — one per
    /// re-grant seen in `entries`, which must be one window's own series as
    /// `contained(_:from:to:)` returns it.
    ///
    /// The returned entry is the one AFTER the drop: the reading before it is
    /// the last of the allowance that ended.
    static func regrantObservations(in entries: [TrackingEntry]) -> [TrackingEntry] {
        guard entries.count >= 2 else { return [] }
        return (1..<entries.count).compactMap { index in
            isMaterialDrop(from: entries[index - 1], to: entries[index]) ? entries[index] : nil
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
