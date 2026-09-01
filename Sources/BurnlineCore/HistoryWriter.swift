import Foundation

/// The **sole writer of the entire `history/` directory**, and a serial one.
///
/// Two independent paths feed the archive, from different data sources: the 60s
/// flush, whose cells come from `ScanCache`, and the launch/gap fill, whose
/// cells come from transcripts via `HistoryFill`. They collide on the very
/// first launch after upgrade, because `UsageStore.start()` kicks `refresh()`
/// immediately while the fill is still running. Serializing them here is what
/// makes that safe.
///
/// 🔴 **Single ownership, deliberately.** Nothing else writes any file in
/// `history/` — not tracking, not the manifest, not one cell. An earlier design
/// split one file out under a second owner and needed a three-step cross-actor
/// protocol to put it back together; this replaces that with a rule.
///
/// 🔴 **Uncovered is decided HERE, inside the actor, never by the caller.** A
/// caller's `Coverage.uncovered(...)` result is a READ HINT for choosing which
/// transcripts to open — by the time it commits, another path may have covered
/// the same buckets. Filtering at commit is what makes two callers that each
/// computed "uncovered" before either wrote harmless.
public actor HistoryWriter {
    private let store: HistoryStore
    private let schedule: ResetSchedule
    private var coverage: Coverage
    private var anchor: Date?
    private var hasEverObservedAReset: Bool

    /// Loads everything the archive knows about itself. `loadManifest`,
    /// `loadWindows` and `loadCoverage` all return empty defaults rather than
    /// throwing when absent, so a first launch needs no special case.
    public init(store: HistoryStore, schedule: ResetSchedule) {
        self.store = store
        self.schedule = schedule
        self.coverage = (try? store.loadCoverage()) ?? Coverage(records: [])

        // 🔴 Manifest loss must not reinstate placeholder bounds. The newest
        // row that observed a real reset carries the anchor too, so the archive
        // heals itself from its own contents. The later of the two wins: a
        // manifest that predates the newest row would otherwise re-date windows
        // against a reset the archive has already moved past.
        let windows = (try? store.loadWindows()) ?? []
        let manifest = (try? store.loadManifest()) ?? HistoryManifest()
        let recovered = WindowLedger.recoverAnchor(from: windows)
        self.anchor = [manifest.lastObservedReset, recovered].compactMap { $0 }.max()

        // "A reset was seen here once, but I no longer know when" means DEFER a
        // row, not fall back to the schedule — so a written row whose bounds did
        // not come from the schedule is evidence in its own right.
        self.hasEverObservedAReset =
            self.anchor != nil || windows.contains { $0.boundsSource != .schedule }
    }

    /// A **read hint** for callers deciding which transcripts to open, and the
    /// range to ask for. Never a write authority — see `commit`.
    public func currentCoverage() -> Coverage { coverage }

    /// Appends whatever of `payload` the archive does not already hold, claims
    /// the coverage that establishes, and writes any window that has become
    /// complete.
    public func commit(payload: HistoryArchive.Payload, filledBy: String,
                       observation: TrackingEntry?) async {
        // One `now` for the whole commit, taken inside the actor: `commit` has
        // no `now` parameter because a caller's clock is exactly the input that
        // must not be able to claim an unclosed bucket.
        let now = Date()
        appendRowsThenCoverage(payload: payload, filledBy: filledBy, now: now)
        if let observation { advanceAnchor(to: observation.resetsAt) }
        writeCompletedWindows(now: now)
    }

    /// Records a capture observation. Reaches `tracking.json` through the actor
    /// like everything else in `history/`.
    public func observe(_ entry: TrackingEntry) async {
        var tracking = (try? store.loadTracking()) ?? TrackingFile()
        // A session republishes an unchanged `rate_limits` every 30 seconds. An
        // identical entry carries no new information and only grows a file that
        // is loaded and rewritten on every commit.
        if !tracking.entries.contains(entry) {
            tracking.entries.append(entry)
            try? store.saveTracking(tracking)
        }
        advanceAnchor(to: entry.resetsAt)
    }

    // MARK: - Rows and coverage

    private func appendRowsThenCoverage(payload: HistoryArchive.Payload,
                                        filledBy: String, now: Date) {
        let fresh = payload.rows.filter { !coverage.contains($0.bucket) }

        // 🔴 Rows first, then the claim. A torn write then under-claims
        // coverage — the next fill rewrites those rows and dedupe-on-read
        // resolves it. Over-claiming is the unrecoverable direction: the buckets
        // it skips can never be re-read once transcripts are deleted.
        do {
            try store.append(rows: fresh)
        } catch {
            return
        }

        // Rows in an unclosed bucket are harmless — the next flush restates
        // that bucket in full — so they are kept even when there is nothing to
        // claim.
        guard let claim = clamped(payload.span, now: now) else { return }

        // `truncated` is carried through: a fill that could not reach the start
        // of its range still claims the FULL requested range, which is what
        // makes the unreachable part a *known* gap rather than a silent absence.
        let record = CoverageRecord(from: claim.lowerBound, through: claim.upperBound,
                                    filledBy: filledBy, truncated: payload.truncated)
        do {
            try store.appendCoverage(record)
            coverage = coverage.adding(record)
        } catch {
            // In-memory coverage stays in step with the log: claiming a range
            // that was never written is the one mistake with no remedy.
        }
    }

    /// 🔴 A span may never extend past the last CLOSED bucket.
    ///
    /// The flush path clamps upstream; the fill does not — it is asked for
    /// everything "up to now". Claim the still-filling bucket and the 60s flush
    /// skips it forever, because `coverage.contains` is then true: up to 15
    /// minutes of usage dropped on every single launch, permanently.
    ///
    /// ⚠️ **The clamp can leave nothing, and the obvious code traps.** Relaunch
    /// inside the same 15-minute bucket as the last flush and the only
    /// uncovered range *is* the still-filling bucket, so the caller submits
    /// `span = [current...current]`, `upperBound` lands below `lowerBound`, and
    /// `ClosedRange` traps — a crash loop on an ordinary launch. Callers are
    /// forbidden from clamping, so this input arrives here by design.
    private func clamped(_ span: ClosedRange<Int>?, now: Date) -> ClosedRange<Int>? {
        guard let span else { return nil }
        let upper = min(span.upperBound, lastClosedBucketStart(now))
        guard span.lowerBound <= upper else { return nil }
        return span.lowerBound...upper
    }

    /// Via `Bucket.key(for:)` rather than raw `%` arithmetic: it floors, and it
    /// clamps a nonsense clock instead of trapping on the `Double`→`Int`.
    private func lastClosedBucketStart(_ now: Date) -> Int {
        (Bucket.key(for: now) - 1) * Int(Bucket.seconds)
    }

    // MARK: - Anchor

    /// Forward only, and nil never reaches here — a launch fill commits before
    /// any capture has landed, and an anchor cleared by that is an anchor every
    /// past window's bounds can no longer roll back from.
    private func advanceAnchor(to instant: Date) {
        try? store.advanceAnchor(instant)
        anchor = max(anchor ?? instant, instant)
        hasEverObservedAReset = true
    }

    // MARK: - Windows

    private func writeCompletedWindows(now: Date) {
        guard let windows = supersedeScheduleRows((try? store.loadWindows()) ?? []) else { return }
        let tracking = (try? store.loadTracking()) ?? TrackingFile()

        let ledger = WindowLedger(anchor: anchor, schedule: schedule,
                                  hasEverObservedAReset: hasEverObservedAReset)
        let rows = ledger.writableRows(coverage: coverage, written: windows,
                                       cells: cells(notCoveredBy: windows, now: now),
                                       tracking: tracking.entries, now: now)
        guard !rows.isEmpty else { return }
        do {
            try store.appendWindows(rows)
        } catch {
            return
        }

        // ⚠️ NOTHING IS PRUNED HERE, AND THAT IS THE POINT.
        //
        // Entries a row consumed used to be dropped once it landed, on the
        // reasoning that the row had extracted the only figure worth keeping.
        // It hadn't. `finalPercent` is ONE number and cannot express a drop, so
        // a mid-window allowance re-grant — Anthropic re-issuing the allowance
        // without moving `resetsAt` — was visible in the series and nowhere
        // else, and the prune destroyed it at the moment the row was written.
        //
        // Measured on the live archive: ~15KB per window, ≈800KB/year beside an
        // existing ≈3.9MB/year. Guarded by
        // `aTrackedEntryOutlivesTheRowThatConsumedIt`, which is the inversion of
        // the test that used to police the prune.
    }

    /// Drops rows whose bounds came from the schedule, once a real reset is
    /// known. Returns nil when the rewrite failed, which means "do not write
    /// windows this pass" — appending onto a file that still holds the rows we
    /// meant to remove is how the overlap gets worse rather than better.
    ///
    /// 🔴 **Two grids may never coexist in one archive.** `.schedule` bounds are
    /// the placeholder Thursday 09:00, written only on a machine that has never
    /// seen a capture. The moment one lands, those rows describe a seven-day
    /// slicing the app no longer believes, and they OVERLAP the anchored rows
    /// written beside them — `Aug 6 → Aug 13` next to `Aug 7 → Aug 14`, with
    /// the same days counted in both. Observed for real; the History window
    /// showed both as separate weeks.
    ///
    /// Dropping is not data loss. The cells and the coverage that produced
    /// these rows are still in the archive — nothing prunes either — so once
    /// they are gone the ledger restates the same weeks on the anchored grid,
    /// which is strictly better data. Nor can a percentage go with them: a
    /// `.schedule` row is only ever written when no reset has EVER been
    /// observed here, and every tracking entry carries one, so a schedule row's
    /// `finalPercent` is always nil.
    ///
    /// ⚠️ Rows that OVERLAP a superseded one go with it, but only when they
    /// carry no `finalPercent`. Two grids' rows overlap by days rather than
    /// aligning, so an anchored row left standing across the hole blocks the
    /// anchored week it shares those days with — which is exactly the archive
    /// the bug produced: three schedule weeks with one anchored row written
    /// *after* them, a day into the last of them.
    ///
    /// A percentless row is safe to drop because it is a pure function of the
    /// grid and the cells, both still in hand. One with a percentage is not:
    /// that is Anthropic's own figure — so it stays, even at the cost of
    /// leaving the weeks behind it unwritten. (An `.observed` row always
    /// carries one, so this never drops ground truth.)
    ///
    /// ⚠️ This paragraph used to reason from "its tracking entry has since been
    /// pruned, and nothing can reconstruct it". That premise died with the
    /// prune: the entry now survives. Dropping such a row would in principle be
    /// recoverable — but it is still not dropped, because the reconstruction
    /// path does not exist and inventing one buys nothing here.
    ///
    /// Idempotent, and after the first pass it costs one `filter`.
    private func supersedeScheduleRows(_ windows: [WindowRow]) -> [WindowRow]? {
        guard anchor != nil else { return windows }
        let superseded = windows.filter { $0.boundsSource == .schedule }
        guard let from = superseded.map(\.start).min(),
              let through = superseded.map(\.end).max() else { return windows }

        let kept = windows.filter { row in
            guard row.boundsSource != .schedule else { return false }
            guard row.start < through, row.end > from else { return true }
            return row.finalPercent != nil
        }
        do {
            try store.replaceWindows(kept)
        } catch {
            return nil
        }
        return kept
    }

    /// Cells for every window that could still be written.
    ///
    /// Starts at the oldest covered bucket and then steps forward over the rows
    /// that already own it, so the read reaches back exactly as far as the
    /// oldest window still missing and no further. In the steady state that is
    /// the newest row's end, which is what keeps this off the whole archive on
    /// every 60s flush — an append-only file that is never healed.
    ///
    /// 🔴 It may NOT be bounded by the newest row alone. A first launch fills
    /// backwards, so the windows still missing are OLDER than everything
    /// written; handed cells from the newest row onward they would each be
    /// totalled from nothing and the archive would record real weeks as zero —
    /// permanently, since a window row is written once. This is the same defect
    /// as the ledger's high-water skip and hides directly behind it.
    private func cells(notCoveredBy written: [WindowRow], now: Date) -> [HistoryRow] {
        guard var from = coverage.ranges.first
            .map({ Date(timeIntervalSince1970: Double($0.lowerBound)) }) else { return [] }

        // `end > from` is what makes this terminate: every step moves `from`
        // strictly forward, and there are finitely many rows.
        while let row = written.first(where: { $0.start <= from && $0.end > from }) {
            from = row.end
        }

        guard from <= now else { return [] }
        return (try? store.rows(in: from...now).rows) ?? []
    }
}
