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
    /// Folder → name, write-once. See `named(_:workingDirectories:)`.
    private var projects: ProjectRegistry
    /// Every name the cell files hold, read the first time a folder needs one.
    private var archivedNames: Set<String>?

    /// Loads everything the archive knows about itself. `loadManifest`,
    /// `loadWindows` and `loadCoverage` all return empty defaults rather than
    /// throwing when absent, so a first launch needs no special case.
    public init(store: HistoryStore, schedule: ResetSchedule) {
        self.store = store
        self.schedule = schedule
        self.coverage = (try? store.loadCoverage()) ?? Coverage(records: [])
        self.projects = store.loadProjects()

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
        let payload = HistoryArchive.Payload(
            rows: named(payload.rows, workingDirectories: payload.workingDirectories),
            span: payload.span, truncated: payload.truncated,
            workingDirectories: payload.workingDirectories)
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

    // MARK: - Heal

    /// The earliest instant whose buckets the transcripts still fully hold:
    /// one day inside Claude Code's `cleanupPeriodDays` (30 when unset).
    ///
    /// A record at `t` lives in a file modified no earlier than `t`, and
    /// cleanup deletes by modification time — so a bucket younger than the
    /// period is intact. The day of margin covers a cleanup run and a bucket
    /// straddling it. A period of a day or less leaves nothing healable.
    ///
    /// ⚠️ Deliberately tighter than `fillHorizon`. A fill that reaches past
    /// what survives records a known gap; a heal that does so REPLACES cells
    /// with less than they held, which is the one direction it must not err.
    public static func healableSince(now: Date, cleanupPeriodDays: Int?) -> Date {
        let days = max((cleanupPeriodDays ?? 30) - 1, 0)
        return now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// The covered buckets an older `TranscriptParser` counted that the
    /// transcripts can still restate, or nil when there is nothing to heal.
    ///
    /// ⚠️ **Marks the archive current when the answer is "nothing".** A fresh
    /// install, or one whose coverage is all older than `since`, has nothing a
    /// re-read could improve. Leaving it unmarked would make the first launch
    /// fill — counted by the current parser — look like an old archive the
    /// moment it lands, and re-read it in full straight after.
    public func rangeToHeal(since: Date) -> ClosedRange<Int>? {
        let manifest = (try? store.loadManifest()) ?? HistoryManifest()
        guard manifest.parserVersion != TranscriptParser.version else { return nil }

        if let first = coverage.ranges.first, let last = coverage.ranges.last {
            let lower = max(WindowLedger.firstBucketStart(atOrAfter: since), first.lowerBound)
            let upper = min(lastClosedBucketStart(Date()), last.upperBound)
            if lower <= upper { return lower...upper }
        }
        try? store.recordParserVersion(TranscriptParser.version)
        return nil
    }

    public enum HealOutcome: Equatable, Sendable {
        case healed
        /// The read could not stand in for what the archive holds. Nothing was
        /// written and the archive stays unmarked, so the next launch tries again.
        case refused
        /// A write failed. Also unmarked.
        case failed
    }

    /// Heals `range` from a fill of it, or refuses.
    ///
    /// 🔴 A fill does not throw when the transcript folder is missing or
    /// unreadable: it finds no files and returns no rows, and healed from that,
    /// every covered bucket in range became nothing. So does a TRUNCATED fill —
    /// nothing found at or before the range start — for the start of the range,
    /// whose transcripts are gone and whose cells are all that is left. Either
    /// way the archive keeps what it has, unmarked, and the next launch tries
    /// again.
    ///
    /// The cost of being this strict: someone whose Claude Code history is
    /// younger than the heal range re-reads it each launch until the history
    /// reaches back far enough. Losing archived weeks is not recoverable; a
    /// background re-read is.
    public func heal(_ fill: HistoryFill.Result, range: ClosedRange<Int>) async -> HealOutcome {
        guard fill.filesOpened > 0, !fill.truncated else { return .refused }
        let rows = named(fill.rows, workingDirectories: fill.workingDirectories)
        return await heal(rows: rows, range: range) ? .healed : .failed
    }

    // MARK: - Project names

    /// Rows whose `project` is an encoded folder, renamed through the
    /// registry, then re-summed: two folders can resolve to one name, and two
    /// rows on one key would otherwise lose one to dedupe-on-read.
    ///
    /// 🔴 The ONE place a folder becomes a name, for the flush, the fill and
    /// the heal alike. Names used to be resolved in each path against whatever
    /// set of folders that path held, so a project's name flipped when the set
    /// changed (`iOS` ↔ `ConcertTracker/iOS`), and a bucket written twice
    /// across a flip was counted twice.
    func named(_ rows: [HistoryRow], workingDirectories: [String: Set<String>]) -> [HistoryRow] {
        guard !rows.isEmpty else { return rows }
        var evidence = workingDirectories
        for row in rows where evidence[row.project] == nil { evidence[row.project] = [] }
        let before = projects
        let names = projects.names(for: evidence) {
            if let archivedNames { return archivedNames }
            let loaded = store.projectNames()
            archivedNames = loaded
            return loaded
        }
        if projects != before { try? store.saveProjects(projects) }

        var totals: [HistoryRow.Key: TokenCounts] = [:]
        for row in rows {
            let key = HistoryRow.Key(bucket: row.bucket, project: names[row.project] ?? row.project,
                                     model: row.model)
            totals[key, default: .zero] += row.counts
        }
        return totals
            .map { HistoryRow(bucket: $0.key.bucket, project: $0.key.project,
                              model: $0.key.model, counts: $0.value) }
            .sorted { ($0.bucket, $0.project, $0.model) < ($1.bucket, $1.project, $1.model) }
    }

    /// Replaces the archived cells in `range` with `rows`, freshly counted
    /// from the transcripts, restates the totals of every window row wholly
    /// inside it, and records the archive as current. Returns false when a
    /// write failed, in which case nothing is recorded and the next launch
    /// heals again.
    ///
    /// `rows` must be a complete re-read of `range`: every bucket in it closed
    /// before the read began. Only COVERED buckets are replaced — an uncovered
    /// one is the fill's to claim, with the coverage record that goes with it.
    ///
    /// A window row straddling `range.lowerBound` is left exactly as it was:
    /// part of it cannot be re-read, and a total that is half one parser's
    /// count and half another's is not better than either.
    ///
    /// ⚠️ `internal`, and the narrowing is the point: the app must come in
    /// through `heal(_:range:)`, which refuses a read that cannot stand in for
    /// the archive.
    func heal(rows: [HistoryRow], range: ClosedRange<Int>) async -> Bool {
        let coverage = coverage
        do {
            try store.replaceRows(in: range, where: { coverage.contains($0) }, with: rows)
        } catch {
            return false
        }

        let windows = (try? store.loadWindows()) ?? []
        let from = Date(timeIntervalSince1970: Double(range.lowerBound))
        let through = Date(timeIntervalSince1970: Double(range.upperBound))
        // Not `try?` into an empty array: that would restate every row below
        // as zero, permanently.
        let cells: [HistoryRow]
        do {
            cells = try store.rows(in: from...through).rows
        } catch {
            return false
        }
        let restated = windows.map { row -> WindowRow in
            let first = WindowLedger.firstBucketStart(atOrAfter: row.start)
            let last = WindowLedger.lastBucketStart(before: row.end)
            guard first >= range.lowerBound, last <= range.upperBound else { return row }
            var row = row
            let counts = WindowLedger.total(of: cells, from: first, through: last)
            row.input = counts.input
            row.output = counts.output
            row.cacheWrite = counts.cacheWrite
            row.cacheRead = counts.cacheRead
            return row
        }
        if restated != windows {
            do {
                try store.replaceWindows(restated)
            } catch {
                return false
            }
        }

        do {
            try store.recordParserVersion(TranscriptParser.version)
        } catch {
            return false
        }
        return true
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
        let readFrom = Self.readStart(coverage: coverage, written: windows, now: now)
        let cells = readFrom.map { (try? store.rows(in: $0...now).rows) ?? [] } ?? []
        let rows = ledger.writableRows(coverage: coverage, written: windows,
                                       cells: cells, cellsFrom: readFrom,
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
    /// How far back the launch fill reaches: one day past Claude Code's 30-day
    /// `cleanupPeriodDays` default. Coverage older than this can never be
    /// claimed — the transcripts are gone.
    public static let fillHorizon: TimeInterval = 31 * 86_400

    /// The instant the flush reads cells from, or nil when nothing is readable.
    /// Pure, so the rule has tests; `writeCompletedWindows` is its only caller
    /// and hands the same instant to the ledger as `cellsFrom`, so a window the
    /// read skipped can never be written from no cells.
    static func readStart(coverage: Coverage, written: [WindowRow], now: Date) -> Date? {
        guard var from = coverage.ranges.first
            .map({ Date(timeIntervalSince1970: Double($0.lowerBound)) }) else { return nil }

        // `end > from` is what makes this terminate: every step moves `from`
        // strictly forward, and there are finitely many rows.
        func stepOverWrittenRows() {
            while let row = written.first(where: { $0.start <= from && $0.end > from }) {
                from = row.end
            }
        }
        stepOverWrittenRows()

        // A hole older than the fill horizon is permanent: the transcripts
        // that would fill it are gone. A window straddling one can never be
        // fully covered, so the ledger never writes it, and without this the
        // read stuck at that window's start forever — every 60s flush
        // decoding the whole archive from there. Jump to the range after each
        // permanent hole; a hole the next fill can still close is left alone.
        //
        // 🔴 Only when no complete window can still fit between `from` and
        // the hole. The ledger checks COVERAGE, not cells: a covered, unwritten
        // window it was handed no cells for totals to zero and is written that
        // way, permanently. So while a week or more of covered, unwritten
        // buckets sits before the hole, read from `from` — one extra pass —
        // and jump only once those windows are written and `from` has
        // stepped past them.
        let permanentBefore = now.addingTimeInterval(-fillHorizon)
        let ranges = coverage.ranges
        for (earlier, later) in zip(ranges, ranges.dropFirst()) {
            let holeStart = Date(timeIntervalSince1970: Double(earlier.upperBound) + Bucket.seconds)
            let nextStart = Date(timeIntervalSince1970: Double(later.lowerBound))
            guard holeStart < permanentBefore, nextStart > from else { continue }
            guard holeStart.timeIntervalSince(from) < 7 * 86_400 else { break }
            from = nextStart
            stepOverWrittenRows()
        }

        guard from <= now else { return nil }
        return from
    }
}
