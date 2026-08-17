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
