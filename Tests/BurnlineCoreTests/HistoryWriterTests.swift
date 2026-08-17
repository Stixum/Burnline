import Testing
import Foundation
@testable import BurnlineCore

// MARK: - Fixtures

private func writerDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("burnline-writer-\(UUID().uuidString)")
}

private let writerZone = TimeZone(identifier: "America/New_York")!

/// Thursday 09:00 — the shipped `BurnlineSettings` placeholder, which nothing
/// ever writes the real reset back over. Every anchored fixture below disagrees
/// with it deliberately: an implementation that falls back to the schedule
/// produces different bounds and fails, rather than passing quietly.
private let writerSchedule = ResetSchedule(weekday: 5, hour: 9, minute: 0, timeZone: writerZone)

private let writerStep = Int(Bucket.seconds)

private var writerCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = writerZone
    return calendar
}

/// Tuesday 2026-06-09 14:15 New York — not the placeholder's weekday, not its
/// time, and comfortably in the past so every fixture bucket is closed no
/// matter when the suite runs.
private let observedReset = writerCalendar.date(
    from: DateComponents(year: 2026, month: 6, day: 9, hour: 14, minute: 15))!

private func plusDays(_ days: Int, _ date: Date) -> Date {
    writerCalendar.date(byAdding: .day, value: days, to: date)!
}

private func epoch(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

/// The start of the bucket being written right now — never claimable.
private func fillingBucketStart() -> Int {
    Bucket.key(for: Date()) * writerStep
}

private func writerCell(_ bucket: Int, output: Int = 1) -> HistoryRow {
    HistoryRow(bucket: bucket, project: "Burnline", model: "claude-opus-5",
               counts: TokenCounts(output: output))
}

/// ⚠️ RAW lines across every cell file, deliberately not `rows(in:)` — the read
/// path deduplicates, so a writer that appends everything twice still returns
/// the right number of distinct keys.
private func rawCellLines(in directory: URL) throws -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    var lines = 0
    for name in names where name.hasSuffix(".jsonl") && name.contains("-W") {
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        lines += text.split(separator: "\n").count
    }
    return lines
}

/// Exactly the window that follows the observed reset: `[reset, reset + 7d)`,
/// covered bucket for bucket, with one cell inside it.
private func windowAfterTheReset() -> HistoryArchive.Payload {
    let from = epoch(observedReset)
    let through = epoch(plusDays(7, observedReset)) - writerStep
    return HistoryArchive.Payload(rows: [writerCell(from + writerStep, output: 9)],
                                  span: from...through)
}

/// The row that recorded the reset — the window *before* the anchor, so the one
/// after it is still unwritten.
private func rowThatObservedTheReset() -> WindowRow {
    WindowRow(start: plusDays(-7, observedReset), end: observedReset, counts: .zero,
              finalPercent: nil, finalPercentAt: nil, finalPercentSource: nil,
              boundsSource: .observed, observedResetsAt: observedReset)
}

/// ⚠️ A real reset instant carries a FRACTION. Measured on this machine:
/// `rate-limit-highwater.json` held `sevenDay.resetsAt: 1787295600.181`, and
/// the two capture sources disagree sub-second by design. Nothing rounds it
/// off before it becomes the anchor.
private let fractionalReset = observedReset.addingTimeInterval(0.181)

/// `[fractionalReset, fractionalReset + 7d)`, covered bucket for bucket.
///
/// A window owns the buckets whose START falls inside it, so a start a fraction
/// past a bucket boundary pushes the first owned bucket to the next one — hence
/// the `+ writerStep` rather than reusing `windowAfterTheReset()`.
private func windowAfterAFractionalReset() -> HistoryArchive.Payload {
    let from = epoch(observedReset) + writerStep
    let through = epoch(plusDays(7, observedReset))
    return HistoryArchive.Payload(rows: [writerCell(from, output: 9)], span: from...through)
}

/// A flush that found nothing new — the ordinary 60s case once the archive has
/// caught up.
private func nothingNew() -> HistoryArchive.Payload {
    HistoryArchive.Payload(rows: [], span: nil)
}

// MARK: - The clamp

@Test func theStillFillingBucketIsNeverClaimedAsCovered() async throws {
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = HistoryWriter(store: HistoryStore(directory: dir), schedule: writerSchedule)

    // The fill is asked for everything "up to now" and does not clamp: its span
    // runs into the bucket still being written, and past it.
    let filling = fillingBucketStart()
    await writer.commit(
        payload: HistoryArchive.Payload(
            rows: [writerCell(filling - writerStep), writerCell(filling)],
            span: (filling - 2 * writerStep)...(filling + writerStep)),
        filledBy: "fill", observation: nil)

    let coverage = await writer.currentCoverage()
    #expect(coverage.contains(filling - 2 * writerStep))
    // Claim the filling bucket and the 60s flush skips it forever, because
    // `coverage.contains` is then true: up to 15 minutes of usage dropped on
    // every launch, permanently.
    #expect(!coverage.contains(filling))
    #expect(!coverage.contains(filling + writerStep))
}

@Test func aSpanThatClampsToNothingDoesNotCrashOrClaim() async throws {
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = HistoryWriter(store: HistoryStore(directory: dir), schedule: writerSchedule)

    // Relaunch inside the same 15-minute bucket as the last flush: the only
    // uncovered range IS the still-filling bucket. `lower...clampedUpper` traps
    // when the clamp inverts the range — a crash loop on an ordinary launch.
    let filling = fillingBucketStart()
    await writer.commit(
        payload: HistoryArchive.Payload(rows: [writerCell(filling)], span: filling...filling),
        filledBy: "fill", observation: nil)

    #expect(await writer.currentCoverage().records.isEmpty)
    // The rows are harmless and are kept: the next flush restates that bucket
    // in full and dedupe-on-read resolves it.
    #expect(try rawCellLines(in: dir) == 1)
}

// MARK: - Serialization

@Test func concurrentFillAndFlushProduceNoDuplicateRows() async throws {
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = HistoryWriter(store: HistoryStore(directory: dir), schedule: writerSchedule)

    // Both payloads are computed before either commits — the first-launch
    // collision, where the fill and the 60s flush overlap by two buckets.
    let base = fillingBucketStart() - 10 * writerStep
    let fill = HistoryArchive.Payload(rows: (0..<4).map { writerCell(base + $0 * writerStep) },
                                      span: base...(base + 3 * writerStep))
    let flush = HistoryArchive.Payload(rows: (2..<6).map { writerCell(base + $0 * writerStep) },
                                       span: (base + 2 * writerStep)...(base + 5 * writerStep))

    await withTaskGroup(of: Void.self) { group in
        group.addTask { await writer.commit(payload: fill, filledBy: "fill", observation: nil) }
        group.addTask { await writer.commit(payload: flush, filledBy: "scan", observation: nil) }
    }

    // Six distinct buckets, and whichever commit lands second must have
    // filtered its two overlapping rows against the coverage the first claimed.
    // Either order gives 6; an unfiltered writer gives 8.
    #expect(try rawCellLines(in: dir) == 6)
}

@Test func nothingOutsideTheWriterWritesTheHistoryDirectory() async throws {
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    let writer = HistoryWriter(store: store, schedule: writerSchedule)

    let entry = TrackingEntry(percent: 12.5, at: plusDays(-3, observedReset),
                              resetsAt: observedReset)
    await writer.observe(entry)

    // tracking.json is reached through the actor, not by a second owner.
    #expect(try store.loadTracking().entries == [entry])
    let names = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    #expect(names == ["tracking.json", "manifest.json"])
}

// MARK: - Windows, tracking and the anchor

@Test func aTrackedEntryIsPrunedOnlyAfterItsRowIsWritten() async throws {
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    try store.appendWindows([rowThatObservedTheReset()])
    let writer = HistoryWriter(store: store, schedule: writerSchedule)

    let consumed = TrackingEntry(percent: 61, at: plusDays(3, observedReset),
                                 resetsAt: plusDays(7, observedReset))
    let live = TrackingEntry(percent: 12, at: plusDays(9, observedReset),
                             resetsAt: plusDays(14, observedReset))
    await writer.observe(consumed)
    await writer.observe(live)

    // Covers `[reset, reset + 7d)` only, so the window holding `live` stays
    // unwritten.
    await writer.commit(payload: windowAfterTheReset(), filledBy: "fill", observation: nil)

    let written = try store.loadWindows()
    #expect(written.count == 2)
    #expect(written.last?.finalPercent == 61)
    // The live window's observation must survive, or the next row loses its
    // percentage — the one figure a row may never estimate.
    #expect(try store.loadTracking().entries == [live])
}

@Test func aNilObservationLeavesTheAnchorAlone() async throws {
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    try store.saveManifest(HistoryManifest(lastObservedReset: observedReset))
    let writer = HistoryWriter(store: store, schedule: writerSchedule)

    // A launch fill commits before any capture has landed. Unconditional
    // assignment would destroy the anchor on an ordinary launch.
    await writer.commit(payload: windowAfterTheReset(), filledBy: "fill", observation: nil)

    #expect(try store.loadManifest().lastObservedReset == observedReset)
    // And in memory too: the row it just wrote is on the anchor's grid.
    let written = try store.loadWindows()
    #expect(written.count == 1)
    #expect(written.first?.start == observedReset)
    #expect(written.first?.boundsSource == .extrapolated)
}

@Test func theAnchorIsRecoveredFromWindowsWhenTheManifestIsAbsent() async throws {
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    try store.appendWindows([rowThatObservedTheReset()])
    #expect(try store.loadManifest().lastObservedReset == nil)

    let writer = HistoryWriter(store: store, schedule: writerSchedule)
    await writer.commit(payload: windowAfterTheReset(), filledBy: "fill", observation: nil)

    // Manifest loss must not reinstate placeholder bounds: Thursday 09:00 and
    // `.schedule`, which are wrong forever because rows are written once.
    let written = try store.loadWindows()
    #expect(written.count == 2)
    #expect(written.last?.start == observedReset)
    #expect(written.last?.end == plusDays(7, observedReset))
    #expect(written.last?.boundsSource == .extrapolated)
    #expect(written.last?.counts.output == 9)
}

@Test func aTruncatedFillStillClaimsItsFullRequestedRange() async throws {
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    let writer = HistoryWriter(store: store, schedule: writerSchedule)

    // The fill could not reach the start of its range — those transcripts are
    // already deleted. It claims the whole range anyway, marked truncated:
    // that is what makes the shortfall a KNOWN gap rather than a silent absence.
    let base = fillingBucketStart() - 20 * writerStep
    let through = base + 5 * writerStep
    await writer.commit(
        payload: HistoryArchive.Payload(rows: [writerCell(through)],
                                        span: base...through, truncated: true),
        filledBy: "fill", observation: nil)

    let records = try store.loadCoverage().records
    #expect(records.count == 1)
    #expect(records.first?.from == base)
    #expect(records.first?.through == through)
    #expect(records.first?.truncated == true)
    #expect(records.first?.filledBy == "fill")
}

@Test func aWrittenWindowIsNotWrittenAgainOnEveryFlush() async throws {
    // 🔴 Found by running the app, not by the suite: `windows.jsonl` held FIVE
    // identical `extrapolated` rows, one per 60s flush.
    //
    // `HistoryStore` pins `.iso8601`, which encodes WHOLE seconds. The grid is
    // built from the in-memory anchor, which keeps its fraction, so the row goes
    // out with `start` = `…14:15:00.181` and comes back `…14:15:00`. The
    // ledger's `start <= lastWritten` then compares `.181` against `.000` and
    // never fires, so the same window is appended again, forever.
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    let writer = HistoryWriter(store: store, schedule: writerSchedule)

    // Only `advanceAnchor` carries the fraction into memory — the manifest
    // cannot, which IS the defect — so the anchor has to arrive the way the
    // app's does, from an observation.
    let observation = TrackingEntry(percent: 41, at: plusDays(9, observedReset),
                                    resetsAt: plusDays(7, fractionalReset))
    await writer.commit(payload: windowAfterAFractionalReset(), filledBy: "fill",
                        observation: observation)
    #expect(try store.loadWindows().count == 1)

    // Four more flushes with nothing left to archive: no new cells, no new
    // coverage, no new window. Nothing may be appended.
    for _ in 0..<4 {
        await writer.commit(payload: nothingNew(), filledBy: "scan", observation: observation)
    }

    let written = try store.loadWindows()
    #expect(written.count == 1)
    // ⚠️ The stored start is the TRUNCATED form and stays that way — `.iso8601`
    // is what makes the archive human- and spreadsheet-readable, which is half
    // the point of it. The fix is not to preserve the fraction; it is that the
    // ledger must not read a sub-second difference as a different window.
    let start = try #require(written.first?.start)
    #expect(start != fractionalReset)
    #expect(abs(start.timeIntervalSince(fractionalReset)) < 1)
}

@Test func republishingAnIdenticalObservationDoesNotGrowTheFile() async throws {
    // A session republishes an unchanged `rate_limits` blob every 30 seconds,
    // and tracking.json is loaded and rewritten on every commit — so an
    // append-always `observe` grows without bound between window prunes.
    //
    // Added because the guard was implemented beyond spec and shipped
    // uncovered. It is exact-equality on the whole entry, which is right: a
    // republished cached reading carries the same percent, the same capture
    // instant, and the same reset.
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    let writer = HistoryWriter(store: store, schedule: writerSchedule)

    let entry = TrackingEntry(percent: 61, at: plusDays(-1, observedReset),
                              resetsAt: observedReset)
    for _ in 0..<5 { await writer.observe(entry) }
    #expect(try store.loadTracking().entries.count == 1)

    // A genuinely new reading still lands — the guard must not swallow those.
    let newer = TrackingEntry(percent: 74, at: observedReset.addingTimeInterval(-3_600),
                              resetsAt: observedReset)
    await writer.observe(newer)
    #expect(try store.loadTracking().entries.count == 2)
}

@Test func scheduleRowsDoNotSurviveTheArrivalOfAnAnchor() async throws {
    // 🔴 Also found by running the app: `Aug 6 → Aug 13  schedule` sitting
    // directly above `Aug 7 → Aug 14  extrapolated`. Two grids, one archive.
    // The user reads them as separate weeks and the overlapping days are
    // counted in both.
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    let writer = HistoryWriter(store: store, schedule: writerSchedule)

    // A machine that has never seen a capture. The placeholder Thursday 09:00
    // is the only grid there is, and a row goes out on it.
    let from = epoch(plusDays(-14, observedReset))
    let through = epoch(observedReset)
    await writer.commit(
        payload: HistoryArchive.Payload(rows: [writerCell(from, output: 3)],
                                        span: from...through),
        filledBy: "fill", observation: nil)
    #expect(try store.loadWindows().contains { $0.boundsSource == .schedule })

    // Then a capture lands, and the app learns where the resets really are.
    let observation = TrackingEntry(percent: 41, at: plusDays(-2, observedReset),
                                    resetsAt: observedReset)
    await writer.commit(payload: nothingNew(), filledBy: "scan", observation: observation)

    let written = try store.loadWindows().sorted { $0.start < $1.start }
    // Nothing may still describe a grid the app has stopped believing in.
    #expect(!written.contains { $0.boundsSource == .schedule })
    // And whatever remains must partition time, not overlap it.
    for (earlier, later) in zip(written, written.dropFirst()) {
        #expect(earlier.end <= later.start)
    }
    // The weeks are not lost — they are restated on the grid the app now
    // believes, from cells the archive still holds.
    #expect(written.count == 2)
    #expect(written.map(\.boundsSource) == [.extrapolated, .extrapolated])
    #expect(written.first?.start == plusDays(-14, observedReset))
    #expect(written.last?.end == observedReset)
}

/// The two-grid archive the bug actually produced: schedule rows, and an
/// anchored row written *after* them once a capture landed. `finalPercent` is
/// the caller's, because whether a row carries one is what decides its fate.
private func mixedGridArchive(finalPercent: Double?) -> [WindowRow] {
    let scheduleRow = WindowRow(
        start: writerCalendar.date(from: DateComponents(year: 2026, month: 5, day: 28, hour: 9))!,
        end: writerCalendar.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: 9))!,
        counts: .zero, finalPercent: nil, finalPercentAt: nil, finalPercentSource: nil,
        boundsSource: .schedule, observedResetsAt: nil)
    let anchoredRow = WindowRow(
        start: plusDays(-7, observedReset), end: observedReset, counts: .zero,
        finalPercent: finalPercent, finalPercentAt: finalPercent == nil ? nil : observedReset,
        finalPercentSource: finalPercent == nil ? nil : "live",
        boundsSource: .extrapolated, observedResetsAt: nil)
    return [scheduleRow, anchoredRow]
}

/// Two weeks of coverage ending at the reset, with one cell in the older week.
private func twoWeeksBeforeTheReset() -> HistoryArchive.Payload {
    let from = epoch(plusDays(-14, observedReset))
    return HistoryArchive.Payload(rows: [writerCell(from, output: 3)],
                                  span: from...epoch(observedReset))
}

@Test func aMixedArchiveIsRestatedOnTheOneGridItNowBelieves() async throws {
    // The archive found on disk: three `schedule` weeks with one `extrapolated`
    // row written after them, starting a day INTO the last of them.
    //
    // `lastWritten` is a high-water mark, so dropping only the schedule rows
    // would leave that later row barring the ledger from ever refilling the
    // hole — the superseded weeks would simply vanish. It goes too, because a
    // row with no percentage is a pure function of the grid and the cells, and
    // the archive still holds both.
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    try store.appendWindows(mixedGridArchive(finalPercent: nil))

    let writer = HistoryWriter(store: store, schedule: writerSchedule)
    let observation = TrackingEntry(percent: 41, at: plusDays(-2, observedReset),
                                    resetsAt: observedReset)
    await writer.commit(payload: twoWeeksBeforeTheReset(), filledBy: "fill",
                        observation: observation)

    let written = try store.loadWindows().sorted { $0.start < $1.start }
    #expect(written.count == 2)
    #expect(written.map(\.boundsSource) == [.extrapolated, .extrapolated])
    #expect(written.map(\.start) == [plusDays(-14, observedReset),
                                     plusDays(-7, observedReset)])
    #expect(written.last?.end == observedReset)
    // Nothing was lost on the way: the cell is still counted, once.
    #expect(written.first?.counts.output == 3)
    #expect(written.last?.counts.output == 0)
}

@Test func supersedingNeverDropsARowCarryingAnthropicsOwnFigure() async throws {
    // 🔴 The stop on the rule above. A percentage is Anthropic's own figure and
    // its tracking entry has long since been pruned — nothing can reconstruct
    // it, so an overlapping row that carries one survives even though that
    // leaves the week behind it unwritten. Absent is recoverable; invented is
    // not, and this archive may never estimate a final percentage.
    let dir = writerDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    try store.appendWindows(mixedGridArchive(finalPercent: 77))

    let writer = HistoryWriter(store: store, schedule: writerSchedule)
    let observation = TrackingEntry(percent: 41, at: plusDays(-2, observedReset),
                                    resetsAt: observedReset)
    await writer.commit(payload: twoWeeksBeforeTheReset(), filledBy: "fill",
                        observation: observation)

    let written = try store.loadWindows()
    #expect(written.count == 1)
    #expect(written.first?.finalPercent == 77)
    #expect(written.first?.start == plusDays(-7, observedReset))
    // The placeholder grid still goes, whatever else survives.
    #expect(!written.contains { $0.boundsSource == .schedule })
}
