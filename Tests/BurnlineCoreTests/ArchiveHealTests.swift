import Testing
import Foundation
@testable import BurnlineCore

// Every week archived before 1.5.1 was counted by a parser that emitted one
// record per transcript LINE, and Claude Code writes one line per content
// block — so a tool-using turn was counted two or three times. Coverage already
// claims those ranges, so the launch fill never re-reads them: without a heal,
// an upgraded install keeps the inflated figures forever. The heal re-reads
// whatever the transcripts still hold and REPLACES the archived cells there.
//
// Fixtures are relative to now: retention is the whole subject.

private func healDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("burnline-heal-\(UUID().uuidString)")
}

private let healStep = Int(Bucket.seconds)
private let healSchedule = ResetSchedule(weekday: 5, hour: 9, minute: 0,
                                         timeZone: TimeZone(identifier: "America/New_York")!)

private func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }
private func healBucket(_ date: Date) -> Int { Bucket.key(for: date) * healStep }

private func healCell(_ bucket: Int, _ project: String = "Burnline", output: Int) -> HistoryRow {
    HistoryRow(bucket: bucket, project: project, model: "claude-opus-5",
               counts: TokenCounts(output: output))
}

/// An archive written by the old parser: covered from `from` through `through`,
/// holding `rows`, with a manifest that predates parser versioning.
private func oldArchive(_ directory: URL, from: Date, through: Date,
                        rows: [HistoryRow], windows: [WindowRow] = []) throws -> HistoryStore {
    let store = HistoryStore(directory: directory)
    try store.append(rows: rows)
    try store.appendCoverage(CoverageRecord(from: healBucket(from), through: healBucket(through),
                                            filledBy: "fill"))
    try store.appendWindows(windows)
    try store.saveManifest(HistoryManifest())
    return store
}

private func allRows(_ store: HistoryStore) throws -> [HistoryRow] {
    try store.rows(in: daysAgo(60)...Date()).rows
}

// MARK: - Replacing cells

/// 🔴 Replacement, not append. Appending the fresh rows would let dedupe-on-read
/// pick them for every key they share with the old rows — and keep any old key
/// the new parser no longer produces, inflated, forever. `Admin` is that key.
@Test func aHealReplacesTheOldParsersCellsRatherThanAddingToThem() async throws {
    let directory = healDirectory()
    let b1 = healBucket(daysAgo(10)), b2 = b1 + healStep
    let store = try oldArchive(directory, from: daysAgo(12), through: daysAgo(8), rows: [
        healCell(b1, output: 10), healCell(b1, "Admin", output: 6), healCell(b2, output: 8),
    ])
    let writer = HistoryWriter(store: store, schedule: healSchedule)

    let range = try #require(await writer.rangeToHeal(since: daysAgo(20)))
    let healed = await writer.heal(rows: [healCell(b1, output: 5), healCell(b2, output: 4)],
                                   range: range)

    #expect(healed)
    #expect(try allRows(store) == [healCell(b1, output: 5), healCell(b2, output: 4)])
}

/// Transcripts older than retention are gone, so the cells there are the only
/// record left. Replacing them with whatever a re-read finds — nothing — would
/// turn an inflated week into an empty one.
@Test func aHealNeverReachesPastWhatTheTranscriptsStillHold() async throws {
    let directory = healDirectory()
    let old = healBucket(daysAgo(10)), recent = healBucket(daysAgo(5))
    let store = try oldArchive(directory, from: daysAgo(12), through: daysAgo(4), rows: [
        healCell(old, output: 10), healCell(recent, output: 8),
    ])
    let writer = HistoryWriter(store: store, schedule: healSchedule)

    let range = try #require(await writer.rangeToHeal(since: daysAgo(7)))
    #expect(range.lowerBound >= healBucket(daysAgo(7)))

    // A row offered for a bucket outside the range is refused, not written.
    _ = await writer.heal(rows: [healCell(old, output: 1), healCell(recent, output: 4)],
                          range: range)

    #expect(try allRows(store) == [healCell(old, output: 10), healCell(recent, output: 4)])
}

/// A corrupt line is skipped on read but never destroyed on rewrite: it is not
/// this pass's to judge, and a rewrite that silently drops what it cannot parse
/// is how an archive quietly loses part of itself.
@Test func aHealKeepsALineItCannotDecode() async throws {
    let directory = healDirectory()
    let b1 = healBucket(daysAgo(10))
    let store = try oldArchive(directory, from: daysAgo(12), through: daysAgo(8),
                               rows: [healCell(b1, output: 10)])
    let file = directory.appendingPathComponent(HistoryFileName.forBucket(b1))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{not json\n".utf8))
    try handle.close()
    let writer = HistoryWriter(store: store, schedule: healSchedule)

    let range = try #require(await writer.rangeToHeal(since: daysAgo(20)))
    _ = await writer.heal(rows: [healCell(b1, output: 5)], range: range)

    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("{not json"))
    #expect(try allRows(store) == [healCell(b1, output: 5)])
}

// MARK: - Window rows

/// A window row's totals were summed from the inflated cells, and a window row
/// is otherwise written once. Restated in place, keeping every other field —
/// above all `finalPercent`, Anthropic's own figure, which nothing here can
/// recompute. A row the heal could not fully re-read stays exactly as it was.
@Test func aHealRestatesAWindowsTotalsAndKeepsAnthropicsFigure() async throws {
    let directory = healDirectory()
    let start = Date(timeIntervalSince1970: Double(healBucket(daysAgo(13))))
    let end = start.addingTimeInterval(7 * 86_400)
    let inside = healBucket(start) + healStep

    func row(_ start: Date, _ end: Date, output: Int, percent: Double?) -> WindowRow {
        WindowRow(start: start, end: end, counts: TokenCounts(output: output),
                  finalPercent: percent, finalPercentAt: percent.map { _ in end },
                  finalPercentSource: percent.map { _ in "statusline" },
                  boundsSource: .extrapolated, observedResetsAt: nil)
    }
    let healable = row(start, end, output: 100, percent: 42)
    let straddling = row(start.addingTimeInterval(-7 * 86_400), start, output: 999, percent: 61)

    let store = try oldArchive(directory, from: daysAgo(13), through: daysAgo(6),
                               rows: [healCell(inside, output: 60), healCell(inside + healStep, output: 40)],
                               windows: [straddling, healable])
    let writer = HistoryWriter(store: store, schedule: healSchedule)

    let range = try #require(await writer.rangeToHeal(since: daysAgo(20)))
    _ = await writer.heal(rows: [healCell(inside, output: 30), healCell(inside + healStep, output: 20)],
                          range: range)

    let windows = try store.loadWindows()
    var expected = healable
    expected.output = 50
    #expect(windows == [straddling, expected])
}

// MARK: - Once, and only when needed

@Test func aHealedArchiveIsNotHealedAgainAfterARelaunch() async throws {
    let directory = healDirectory()
    let b1 = healBucket(daysAgo(10))
    let store = try oldArchive(directory, from: daysAgo(12), through: daysAgo(8),
                               rows: [healCell(b1, output: 10)])
    let writer = HistoryWriter(store: store, schedule: healSchedule)
    let range = try #require(await writer.rangeToHeal(since: daysAgo(20)))
    _ = await writer.heal(rows: [healCell(b1, output: 5)], range: range)

    #expect(try store.loadManifest().parserVersion == TranscriptParser.version)
    #expect(await writer.rangeToHeal(since: daysAgo(20)) == nil)
    let relaunched = HistoryWriter(store: store, schedule: healSchedule)
    #expect(await relaunched.rangeToHeal(since: daysAgo(20)) == nil)
}

/// A fresh install has nothing an old parser wrote. It is marked current at
/// once, or the first launch fill would be re-read in full straight after it
/// finished — another half-minute of I/O for nothing.
@Test func anArchiveWithNothingToHealIsMarkedCurrentWithoutAReRead() async throws {
    let store = HistoryStore(directory: healDirectory())
    let writer = HistoryWriter(store: store, schedule: healSchedule)

    #expect(await writer.rangeToHeal(since: daysAgo(20)) == nil)
    #expect(try store.loadManifest().parserVersion == TranscriptParser.version)
}

/// Coverage older than retention only: nothing can be re-read, so there is
/// nothing to heal — and nothing to wait for either.
@Test func anArchiveWhollyOlderThanRetentionIsMarkedCurrent() async throws {
    let directory = healDirectory()
    let store = try oldArchive(directory, from: daysAgo(40), through: daysAgo(35),
                               rows: [healCell(healBucket(daysAgo(38)), output: 10)])
    let writer = HistoryWriter(store: store, schedule: healSchedule)

    #expect(await writer.rangeToHeal(since: daysAgo(29)) == nil)
    #expect(try store.loadManifest().parserVersion == TranscriptParser.version)
}

// MARK: - The manifest field

/// The anchor and the parser version share one file. Advancing either must not
/// drop the other, and a manifest from before the field existed still loads.
@Test func theParserVersionSurvivesAnAnchorAdvanceAndOldManifestsStillLoad() throws {
    let directory = healDirectory()
    let store = HistoryStore(directory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"version":1,"lastObservedReset":"2026-09-01T07:00:00Z"}"#.utf8)
        .write(to: directory.appendingPathComponent("manifest.json"))

    let legacy = try store.loadManifest()
    #expect(legacy.lastObservedReset != nil)
    #expect(legacy.parserVersion == nil)

    try store.recordParserVersion(TranscriptParser.version)
    try store.advanceAnchor(Date())
    #expect(try store.loadManifest().parserVersion == TranscriptParser.version)
}

// MARK: - How far back the transcripts reach

/// One day inside Claude Code's `cleanupPeriodDays`: a bucket that old lives in
/// files modified no earlier than the bucket, which cleanup has not reached.
@Test func theHealableHorizonFollowsClaudeCodesCleanupPeriod() {
    let now = Date()
    #expect(HistoryWriter.healableSince(now: now, cleanupPeriodDays: nil)
            == now.addingTimeInterval(-29 * 86_400))
    #expect(HistoryWriter.healableSince(now: now, cleanupPeriodDays: 7)
            == now.addingTimeInterval(-6 * 86_400))
    #expect(HistoryWriter.healableSince(now: now, cleanupPeriodDays: 365)
            == now.addingTimeInterval(-364 * 86_400))
    #expect(HistoryWriter.healableSince(now: now, cleanupPeriodDays: 1) == now)
    #expect(HistoryWriter.healableSince(now: now, cleanupPeriodDays: 0) == now)
}

@Test func cleanupPeriodDaysIsReadOnlyWhenItIsAWholeNumber() throws {
    func parse(_ json: String) throws -> Int? {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return ClaudeSettingsFile.cleanupPeriodDays(in: object)
    }
    #expect(try parse(#"{"cleanupPeriodDays": 7}"#) == 7)
    #expect(try parse(#"{"model": "opus"}"#) == nil)
    #expect(try parse(#"{"cleanupPeriodDays": "7"}"#) == nil)
    #expect(try parse(#"{"cleanupPeriodDays": 7.5}"#) == nil)
    #expect(try parse(#"{"cleanupPeriodDays": true}"#) == nil)
    #expect(ClaudeSettingsFile.cleanupPeriodDays(in: nil) == nil)
}

// MARK: - Refusing a read that cannot stand in for the archive

// The fill does not throw when the transcript folder is missing or unreadable:
// it finds no files and returns no rows. Healed from that, every covered bucket
// in range was replaced with nothing — up to 29 days of archive — and a parser
// version bump re-runs the heal on every install that upgrades.

private func healFixture() async throws -> (HistoryStore, HistoryWriter, ClosedRange<Int>, Int) {
    let b1 = healBucket(daysAgo(10))
    let store = try oldArchive(healDirectory(), from: daysAgo(12), through: daysAgo(8),
                               rows: [healCell(b1, output: 10)])
    let writer = HistoryWriter(store: store, schedule: healSchedule)
    let range = try #require(await writer.rangeToHeal(since: daysAgo(20)))
    return (store, writer, range, b1)
}

@Test func aHealRefusesAReadThatOpenedNoTranscripts() async throws {
    let (store, writer, range, b1) = try await healFixture()

    let outcome = await writer.heal(HistoryFill.Result(rows: [], truncated: false, filesOpened: 0),
                                    range: range)

    #expect(outcome == .refused)
    #expect(try allRows(store) == [healCell(b1, output: 10)])
    #expect(try store.loadManifest().parserVersion != TranscriptParser.version)
}

/// A read that found nothing at or before the range start cannot restate the
/// start of the range: those transcripts are gone, and the cells are all that
/// is left of them.
@Test func aHealRefusesATruncatedRead() async throws {
    let (store, writer, range, b1) = try await healFixture()

    let outcome = await writer.heal(HistoryFill.Result(rows: [healCell(b1, output: 5)],
                                                       truncated: true, filesOpened: 3),
                                    range: range)

    #expect(outcome == .refused)
    #expect(try allRows(store) == [healCell(b1, output: 10)])
    #expect(try store.loadManifest().parserVersion != TranscriptParser.version)
}

/// The control: a complete read still heals, and marks the archive current.
@Test func aCompleteReadStillHeals() async throws {
    let (store, writer, range, b1) = try await healFixture()

    let outcome = await writer.heal(HistoryFill.Result(rows: [healCell(b1, output: 5)],
                                                       truncated: false, filesOpened: 1),
                                    range: range)

    #expect(outcome == .healed)
    #expect(try allRows(store) == [healCell(b1, output: 5)])
    #expect(try store.loadManifest().parserVersion == TranscriptParser.version)
}
