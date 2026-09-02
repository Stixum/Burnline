import Foundation

/// Every number the History window draws, derived in one pure place.
///
/// **No view in this codebase does arithmetic** — that rule is why the pure
/// units carry the tests, and a scoreboard cell, a curve point and a breakdown
/// share are all arithmetic. Three views (week-over-week scoreboard, overlaid
/// burn curves, project/model breakdown) read this one enum.
public enum HistoryQuery {

    /// The label a folded tail carries. Exposed so a view can match on it
    /// rather than re-spelling the string.
    public static let otherLabel = "Other"

    // MARK: - Types

    public struct ScoreboardRow: Equatable, Sendable {
        public let window: WindowRow

        /// Weighted units for the whole window.
        ///
        /// **Guaranteed: this equals the sum of that window's `breakdown`
        /// rows.** Both are computed from the same cells, over the same
        /// bucket-ownership rule, through the same `ResolvedMultipliers` — so
        /// the headline and the bars beneath it are one quantity and a reader
        /// can add the bars up.
        ///
        /// ⚠️ That is why this takes cells and not `WindowRow.counts`: a
        /// `WindowRow` sums its four token counts across every model, so the
        /// model dimension is gone and no per-model multiplier can be
        /// recovered from it. Weighting those counts read 1× for an all-Opus
        /// week where the breakdown read 5×.
        public let units: Double

        /// 🔴 **nil means NOT RECORDED — never render it as zero.**
        ///
        /// Anthropic's own figure or nothing. Every window in the real archive
        /// is nil today: the app only began recording percentages now, none
        /// exist anywhere on disk, and none can be reconstructed. That is the
        /// normal first-open state, not an edge case. `0%` would claim a week
        /// of no usage.
        public let usedPercent: Double?

        /// Coverage has a hole inside this window: usage there is **unknown**,
        /// not idle. The app was not running; tokens may well have been burned.
        public let hasGap: Bool

        public init(window: WindowRow, units: Double, usedPercent: Double?, hasGap: Bool) {
            self.window = window
            self.units = units
            self.usedPercent = usedPercent
            self.hasGap = hasGap
        }
    }

    public struct CurvePoint: Equatable, Sendable {
        /// 0...1 through the window — the shared axis that makes overlay valid.
        public let elapsedFraction: Double
        /// Cumulative weighted units consumed by this point in the window.
        public let units: Double

        public init(elapsedFraction: Double, units: Double) {
            self.elapsedFraction = elapsedFraction
            self.units = units
        }
    }

    public struct BreakdownRow: Equatable, Sendable {
        public let label: String
        public let units: Double
        /// Fraction of the total, 0...1. Zero when the total is zero.
        public let share: Double
        /// This row is the folded tail, not a single project or model.
        public let isOther: Bool

        public init(label: String, units: Double, share: Double, isOther: Bool) {
            self.label = label
            self.units = units
            self.share = share
            self.isOther = isOther
        }
    }

    /// `Hashable` because a SwiftUI `Picker` tag has to be.
    public enum Dimension: Hashable, CaseIterable, Sendable {
        case project, model

        public var title: String {
            switch self {
            case .project: return "Project"
            case .model: return "Model"
            }
        }
    }

    // MARK: - Scoreboard

    /// One row per completed window, **newest first**.
    ///
    /// Archive order is oldest-first, because rows are appended as windows
    /// close; a list fed that order renders the history upside down.
    ///
    /// 🔴 **Units come from `cells`, never from `WindowRow.counts`.** The row's
    /// stored counts are correct *as tokens* and are what the archive persists,
    /// but they are summed across every model — so weighting them loses every
    /// per-model multiplier and the headline disagrees with the `breakdown`
    /// bars printed under it. See `ScoreboardRow.units`.
    public static func scoreboard(windows: [WindowRow], cells: [HistoryRow],
                                  coverage: Coverage, weights: Weights) -> [ScoreboardRow] {
        // ⚠️ ONCE per query, before the walk — the rule spelled out on
        // `breakdown`, and the reason `burnCurve` resolves up front too.
        let resolved = ConsumptionModel.ResolvedMultipliers(models: cells.lazy.map(\.model),
                                                            weights: weights)
        // Weight each cell once, then index by bucket so a window can take its
        // own slice. A ten-year archive is ~500 windows over hundreds of
        // thousands of cells; re-scanning the whole archive per window is the
        // same O(windows × cells) trap `multipliersAreResolvedOncePerQueryNotPerCell`
        // pins on the other side. Tuples, not rows: sorting `HistoryRow` moves
        // three strings per element for no gain here.
        var weighted = cells.map { (bucket: $0.bucket,
                                    units: ConsumptionModel.units(for: $0.counts,
                                                                  multiplier: resolved[$0.model],
                                                                  weights: weights)) }
        weighted.sort { $0.bucket < $1.bucket }

        return windows
            .sorted { $0.start > $1.start }
            .map { window in
                ScoreboardRow(
                    window: window,
                    units: units(in: window, weighted: weighted),
                    // 🔴 Passed through unchanged. nil stays nil.
                    usedPercent: window.finalPercent,
                    hasGap: hasGap(in: window, coverage: coverage)
                )
            }
    }

    private static func units(in window: WindowRow,
                              weighted: [(bucket: Int, units: Double)]) -> Double {
        // The same bucket-ownership rule as `hasGap` and `burnCurve`: a window
        // owns the buckets whose START falls in [start, end). A second rule
        // here would double-count or drop the buckets around every reset.
        let first = WindowLedger.firstBucketStart(atOrAfter: window.start)
        let last = WindowLedger.lastBucketStart(before: window.end)
        guard first <= last else { return 0 }

        let lower = lowerBound(weighted, bucket: first)
        let upper = lowerBound(weighted, bucket: last + 1)
        guard lower < upper else { return 0 }
        return weighted[lower..<upper].reduce(0) { $0 + $1.units }
    }

    /// First index in a bucket-sorted array at or after `bucket`.
    private static func lowerBound(_ weighted: [(bucket: Int, units: Double)],
                                   bucket: Int) -> Int {
        var low = 0
        var high = weighted.count
        while low < high {
            let mid = low + (high - low) / 2
            if weighted[mid].bucket < bucket { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func hasGap(in window: WindowRow, coverage: Coverage) -> Bool {
        // The same bucket-ownership rule `WindowLedger` used to decide the
        // window was writable in the first place: a window owns the buckets
        // whose START falls in [start, end). Two different rules here and there
        // would flag every window as holed, or none.
        let first = WindowLedger.firstBucketStart(atOrAfter: window.start)
        let last = WindowLedger.lastBucketStart(before: window.end)
        guard first <= last else { return false }
        return !coverage.covers(from: first, through: last)
    }

    // MARK: - Burn curve

    /// Cumulative consumption through a window, on a 0...1 elapsed axis.
    ///
    /// Takes plain bounds, **not a `WindowRow`** — the current week is the
    /// curve the user most wants and has no row, because a row is only written
    /// once the window completes.
    ///
    /// **Cumulative**, because the question is "was I ahead or behind", and
    /// only a running total answers it against a straight pace line. And keyed
    /// to *fraction elapsed*, because windows do not all start on the same
    /// weekday — the reset moves whenever a new one is observed — so a wall
    /// clock axis compares Tuesday of one week to Friday of another. On this
    /// axis "day 3 of the window" is the same place in every curve.
    ///
    /// The series opens with `(0, 0)`: at the window's start, zero has been
    /// consumed *within the window* by definition, so every overlaid curve
    /// begins from the same origin. Empty in, empty out.
    public static func burnCurve(cells: [HistoryRow], start: Date, end: Date,
                                 weights: Weights) -> [CurvePoint] {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return [] }

        let first = WindowLedger.firstBucketStart(atOrAfter: start)
        let last = WindowLedger.lastBucketStart(before: end)
        guard first <= last else { return [] }

        let inWindow = cells.filter { $0.bucket >= first && $0.bucket <= last }
        guard !inWindow.isEmpty else { return [] }

        // ⚠️ Once, before the walk. See `breakdown`.
        let resolved = ConsumptionModel.ResolvedMultipliers(models: inWindow.lazy.map(\.model),
                                                            weights: weights)

        var byBucket: [Int: Double] = [:]
        for row in inWindow {
            byBucket[row.bucket, default: 0] += ConsumptionModel.units(
                for: row.counts, multiplier: resolved[row.model], weights: weights)
        }

        let origin = start.timeIntervalSince1970
        var running = 0.0
        var points: [CurvePoint] = [CurvePoint(elapsedFraction: 0, units: 0)]
        points.reserveCapacity(byBucket.count + 1)
        for bucket in byBucket.keys.sorted() {
            running += byBucket[bucket] ?? 0
            // The bucket's END: its tokens accrued *over* the bucket, so the
            // running total is only true once the bucket has finished.
            let instant = Double(bucket) + Bucket.seconds
            let fraction = min(max((instant - origin) / duration, 0), 1)
            points.append(CurvePoint(elapsedFraction: fraction, units: running))
        }
        return points
    }

    /// One window's cells, by the **same bucket-ownership rule** `scoreboard`
    /// weighs its units with.
    ///
    /// 🔴 This exists so the breakdown can be pointed at one window and still
    /// sum to that window's scoreboard row. Filtering on `start...end` in
    /// seconds instead would take a different set around every reset, and the
    /// headline and the bars under it would disagree by a bucket — small,
    /// plausible, and permanent.
    public static func cells(_ cells: [HistoryRow], in window: WindowRow) -> [HistoryRow] {
        let first = WindowLedger.firstBucketStart(atOrAfter: window.start)
        let last = WindowLedger.lastBucketStart(before: window.end)
        guard first <= last else { return [] }
        return cells.filter { $0.bucket >= first && $0.bucket <= last }
    }

    /// One point per hour of the window, for display only.
    ///
    /// ⚠️ A week at 15-minute resolution is ~670 points per series, three series
    /// deep. That is a line chart drawing 2,000 marks to render something the
    /// eye reads at a tenth of the resolution. The query keeps every bucket —
    /// the totals must stay exact — and only the drawn series is thinned.
    ///
    /// **The LAST point in each hour wins**, because the series is cumulative:
    /// the running total at the end of the hour is the true total at that hour.
    /// Taking the first, or a mean, would draw a curve that lags or undershoots
    /// its own endpoint.
    ///
    /// The origin and the final point are always kept. The origin is what makes
    /// overlaid curves start from one place; the final point is the window's
    /// real total, and a chart whose last drawn value is an hour short of it
    /// disagrees with the scoreboard printed above it.
    public static func hourly(_ points: [CurvePoint], windowDuration: TimeInterval) -> [CurvePoint] {
        guard points.count > 2, windowDuration > 0 else { return points }
        let hours = max(1, Int((windowDuration / 3600).rounded()))

        func hour(of point: CurvePoint) -> Int {
            let scaled = point.elapsedFraction * Double(hours)
            // `Int(Double)` traps on NaN and on anything outside Int's range.
            // `burnCurve` clamps its fractions, but this is public and the trap
            // is a crash rather than an error.
            guard scaled.isFinite else { return 0 }
            // `hours - 1`, not `hours`: a fraction of exactly 1.0 is the
            // window's final instant, which belongs to the LAST hour rather
            // than to a 169th one containing a single point.
            return Int(min(max(scaled, 0), Double(hours - 1)))
        }

        var result = [points[0]]
        var current = -1                    // no real hour, so the first point appends
        for point in points.dropFirst() {
            let bucket = hour(of: point)
            if bucket == current {
                result[result.count - 1] = point
            } else {
                result.append(point)
                current = bucket
            }
        }
        return result
    }

    // MARK: - Percent of allowance

    /// One reading of Anthropic's own percentage, on the same 0...1 elapsed
    /// axis `CurvePoint` uses.
    ///
    /// 🔴 **A sibling of `CurvePoint`, deliberately not the same type.** The two
    /// series share an x axis and nothing else. Units are cumulative and
    /// monotonic *by construction* — nothing can un-spend a token — while a
    /// percentage is a reading that can FALL, and that it falls is the whole
    /// reason this query exists. Folding both into one type with two y fields
    /// would let a chart plot one series' axis against the other's values; one
    /// with an optional `percent` would let it plot a missing week as zero.
    public struct PercentPoint: Equatable, Sendable {
        /// 0...1 through the window — the shared axis that makes overlay valid.
        public let elapsedFraction: Double
        /// Anthropic's own figure at `at`. Never an estimate, never a
        /// calibration: `TrackingEntry` only ever holds a captured percentage.
        public let percent: Double
        /// When it was observed. Carried so a hover label can name the instant
        /// without converting a fraction back to a date in a view body, and so
        /// a caller can match a point against a `WindowRow.regrantedAt`.
        public let at: Date

        /// Which allowance this reading measures. 0 is the one the window
        /// opened with; each observed re-grant opens the next.
        ///
        /// **The grouping key that breaks the drawn line.** Two readings either
        /// side of a re-grant are measurements of different allowances, and a
        /// segment joining them draws a plunge that never happened — 51% did not
        /// fall to 3%, it was replaced. A renderer keys its series on this and
        /// the break costs it no arithmetic.
        public let allowance: Int

        /// This reading is the FIRST of a new allowance — the discontinuity
        /// itself, and where a renderer puts its ring.
        ///
        /// 🔴 On the reading AFTER the drop, never the one before it. The
        /// earlier reading is the last honest measurement of the allowance that
        /// ended; this one is the earliest proof the new one was already in
        /// force.
        public let followsRegrant: Bool

        public init(elapsedFraction: Double, percent: Double, at: Date,
                    allowance: Int, followsRegrant: Bool) {
            self.elapsedFraction = elapsedFraction
            self.percent = percent
            self.at = at
            self.allowance = allowance
            self.followsRegrant = followsRegrant
        }
    }

    /// Where an allowance was re-granted, as much as the readings can say.
    ///
    /// 🔴 **The re-grant itself is unrecoverable, so this is a STRETCH and not
    /// an instant.** On the live 2026-09-01 event the readings either side were
    /// 51% and 3%, ninety-seven minutes apart — the gap is there precisely
    /// because nothing was reporting across it. Somewhere in there the
    /// allowance was re-issued and nothing recorded where.
    ///
    /// Both ends are carried so a renderer can draw the uncertainty rather than
    /// a hard rule at a time nobody observed, and so that it measures nothing
    /// itself. Named `…Marker` rather than `Regrant` because it is drawing
    /// geometry: `RateLimitHighWater.Regrant` and `Snapshot.Regrant` are the
    /// domain values, and this is neither.
    public struct RegrantMarker: Equatable, Sendable {
        /// Fraction of the last reading of the allowance that ended.
        public let lastKnownFraction: Double
        /// That reading's percentage — the high-water of the old allowance.
        public let percentBefore: Double
        /// Fraction of the first reading of the new allowance: the earliest
        /// point the re-grant is known to have ALREADY happened. It can only
        /// ever be late.
        public let knownByFraction: Double
        /// That reading's percentage — **the first figure seen after the
        /// re-grant, not zero.** The live event's was 3%: the reporting gap had
        /// already been burned through by the time anything reported again.
        public let percentAfter: Double

        public init(lastKnownFraction: Double, percentBefore: Double,
                    knownByFraction: Double, percentAfter: Double) {
            self.lastKnownFraction = lastKnownFraction
            self.percentBefore = percentBefore
            self.knownByFraction = knownByFraction
            self.percentAfter = percentAfter
        }
    }

    /// One window's percentage readings, plus every discontinuity in them.
    ///
    /// 🔴 **Empty means NOT RECORDED — never render it as a week at 0%.** The
    /// same rule as `ScoreboardRow.usedPercent`, and here it is the common case
    /// rather than the edge one: tracking entries survived a window's close
    /// only from the commit that stopped pruning them onward, so every week
    /// archived before that has no percentage series at all and never will.
    /// That is why the series carries no synthetic origin — see `percentCurve`.
    public struct PercentSeries: Equatable, Sendable {
        public let points: [PercentPoint]
        /// Oldest first, one per observed re-grant. `regrants.count` is the
        /// number of allowances this window is known to have been given beyond
        /// its first, and `points.last?.allowance` equals it.
        public let regrants: [RegrantMarker]

        public init(points: [PercentPoint], regrants: [RegrantMarker]) {
            self.points = points
            self.regrants = regrants
        }

        /// Nothing was recorded for this window. **Not "no usage".**
        public var isEmpty: Bool { points.isEmpty }
    }

    /// The percentage of the weekly allowance through a window, on the same
    /// 0...1 elapsed axis as `burnCurve`, broken wherever the allowance was
    /// re-granted.
    ///
    /// 🔴 **Why this exists at all.** `burnCurve` plots cumulative token units,
    /// and units are MONOTONIC — a re-grant does not un-spend a token, so a
    /// re-granted week's unit curve looks perfectly ordinary while the
    /// scoreboard beside it reports 3%. The percentage is the only series in
    /// which the event is visible, and until this it was plotted nowhere.
    ///
    /// Takes plain bounds, **not a `WindowRow`** — the live window is the one a
    /// reader most wants and has no row, because a row is written only once a
    /// window closes. Same signature shape, same reason, as `burnCurve`.
    ///
    /// ⚠️ **No synthetic `(0, 0)` origin, unlike `burnCurve`.** Zero units
    /// consumed at a window's start is true by definition; nothing of the sort
    /// is true of a percentage. An origin here would draw every week with no
    /// readings as a line rising from 0%, which claims an allowance was
    /// untouched rather than admitting it was never measured. The series starts
    /// at the first real reading or does not exist.
    ///
    /// ⚠️ **Gaps between readings are drawn straight through, on purpose.**
    /// Readings land roughly every 45 minutes and irregularly, and a quiet
    /// stretch is a real absence of information — but unlike a coverage gap it
    /// is a BOUNDED one: the two readings either side pin exactly how much was
    /// consumed across it, only not when. A straight segment is that
    /// interpolation and it cannot overstate or understate the total. The one
    /// case where interpolating would lie is the re-grant, and that is exactly
    /// what `allowance` breaks. Choosing a "too long a gap" threshold here
    /// would be inventing a constant the data does not supply.
    ///
    /// ⚠️ **Not thinned, unlike the unit curve.** A week holds ~210 readings
    /// against the unit curve's ~670 buckets, because this series is
    /// observation-driven rather than bucket-driven, so there is a third as much
    /// to draw. And `hourly`'s last-in-the-hour rule would silently swallow a
    /// re-grant whose two readings fell in one hour — the single point the whole
    /// feature exists to show.
    public static func percentCurve(tracking: [TrackingEntry],
                                    start: Date, end: Date) -> PercentSeries {
        let duration = end.timeIntervalSince(start)
        // ⚠️ Belt and braces, and written down rather than reasoned about. The
        // containment filter below cannot admit a reading when `end <= start`,
        // so nothing ever reaches the division — mutating this guard away
        // changes no result. It stays because it is the division's guard, and
        // the next edit to the filter must not silently make it load-bearing.
        guard duration > 0 else { return PercentSeries(points: [], regrants: []) }

        // Containment of the INSTANT in [start, end) — the rule `WindowLedger`
        // matches an entry to a window by, and deliberately not the
        // bucket-ownership rule the unit queries share. A tracking entry is an
        // observation at an instant, not a fifteen-minute bucket, and rounding
        // one to a bucket would walk readings across a boundary.
        //
        // 🔴 Per window, never across the series: the ordinary weekly reset is
        // an 87 → 4 drop, so a walk over the whole file would read almost every
        // week as re-granted.
        //
        // Sorted by instant because the archive's own order is not a guarantee;
        // ties break on ASCENDING percent, which makes the order total (and so
        // the series deterministic, which `sort` does not otherwise promise) and
        // means a transition within one instant is never downward. Two readings
        // dated to the same instant are two sources describing one moment, not
        // an event between two moments, and must never open an allowance.
        let contained = tracking
            .filter { $0.at >= start && $0.at < end }
            .sorted { $0.at == $1.at ? $0.percent < $1.percent : $0.at < $1.at }
        guard !contained.isEmpty else { return PercentSeries(points: [], regrants: []) }

        let origin = start.timeIntervalSince1970
        func fraction(of instant: Date) -> Double {
            (instant.timeIntervalSince1970 - origin) / duration
        }

        var points: [PercentPoint] = []
        points.reserveCapacity(contained.count)
        var regrants: [RegrantMarker] = []
        var allowance = 0

        // One walk produces all three signals — the per-point allowance index,
        // the per-point flag and the marker list — so they cannot drift apart.
        for (index, entry) in contained.enumerated() {
            let previous = index > 0 ? contained[index - 1] : nil
            // 🔴 The threshold is `RateLimitHighWater.materialDropPoints`, read
            // from there and restated nowhere. `WindowLedger.regrantObservations`
            // annotates the archived row from the same rule over the same
            // entries; the row and this curve describe one event and must never
            // disagree about whether it happened. Materiality is on the
            // ADJACENT drop, as it is in the live path.
            let opensAllowance = previous.map {
                $0.percent - entry.percent >= RateLimitHighWater.materialDropPoints
            } ?? false

            if opensAllowance, let previous {
                allowance += 1
                regrants.append(RegrantMarker(
                    lastKnownFraction: fraction(of: previous.at),
                    percentBefore: previous.percent,
                    knownByFraction: fraction(of: entry.at),
                    percentAfter: entry.percent))
            }

            points.append(PercentPoint(elapsedFraction: fraction(of: entry.at),
                                       percent: entry.percent,
                                       at: entry.at,
                                       allowance: allowance,
                                       followsRegrant: opensAllowance))
        }

        return PercentSeries(points: points, regrants: regrants)
    }

    // MARK: - Breakdown

    /// Weighted units by project or model, descending, with the tail past
    /// `limit` folded into a single `isOther` row.
    ///
    /// The folded row carries the whole remainder, so the rows **including
    /// Other sum to the total** and the shares add to 1. A breakdown that does
    /// not reconcile with the total it sits under is worse than none: the
    /// reader cannot tell whether the tail was folded or dropped.
    public static func breakdown(cells: [HistoryRow], by dimension: Dimension,
                                 weights: Weights, limit: Int) -> [BreakdownRow] {
        guard !cells.isEmpty else { return [] }

        // ⚠️ ONCE per query, before the walk. `Weights.modelMultipliers` is an
        // ordered, substring-matched array, so resolving one model costs a walk
        // of the list plus a `lowercased()` allocation per candidate. Per cell
        // that is O(cells × candidates) over hundreds of thousands of rows —
        // the performance question measured and explicitly closed on
        // `ScanCache.units`. Pinned by `multipliersAreResolvedOncePerQueryNotPerCell`.
        let resolved = ConsumptionModel.ResolvedMultipliers(models: cells.lazy.map(\.model),
                                                            weights: weights)

        var totals: [String: Double] = [:]
        var total = 0.0
        for row in cells {
            let units = ConsumptionModel.units(for: row.counts, multiplier: resolved[row.model],
                                               weights: weights)
            let label = switch dimension {
            case .project: row.project
            case .model: row.model
            }
            totals[label, default: 0] += units
            total += units
        }

        // Ties break on the label so the table does not reshuffle between
        // refreshes; dictionary order is unspecified.
        //
        // ⚠️ **A label that consumed nothing is dropped, not ranked.** The real
        // archive carries a `<synthetic>` model — Claude Code's placeholder for
        // an assistant message it produced without an API call — on nine cells
        // whose four token counts are all zero. In a magnitude chart that is a
        // bar with no length and a cryptic name, which reads as a defect. The
        // rule is stated as "zero units" rather than as that literal string on
        // purpose: a `<synthetic>` cell that ever *did* carry tokens is real
        // usage and must appear, and any other label that burned nothing has
        // equally nothing to show. Dropping zero changes no total and no share,
        // so the rows still reconcile exactly.
        let ranked = totals
            .filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }

        func share(_ units: Double) -> Double { total > 0 ? units / total : 0 }
        func row(_ label: String, _ units: Double, isOther: Bool) -> BreakdownRow {
            BreakdownRow(label: label, units: units, share: share(units), isOther: isOther)
        }

        let keep = max(0, limit)
        guard ranked.count > keep else {
            return ranked.map { row($0.key, $0.value, isOther: false) }
        }
        var rows = ranked.prefix(keep).map { row($0.key, $0.value, isOther: false) }
        let tail = ranked.dropFirst(keep).reduce(0) { $0 + $1.value }
        // Same rule as above: an Other row worth nothing is a bar with no
        // length. It cannot happen while every ranked row is positive, and it
        // is written down rather than reasoned about.
        if tail > 0 { rows.append(row(otherLabel, tail, isOther: true)) }
        return rows
    }
}
