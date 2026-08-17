import Testing
import Foundation
@testable import BurnlineCore

private func temporaryStore() -> (HistoryStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("burnline-history-\(UUID().uuidString)")
    return (HistoryStore(directory: dir), dir)
}

private let hb0 = 1_786_924_800

@Test func historyRowsAreDedupedByKeyWithLastOccurrenceWinning() throws {
    let (store, dir) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let start = Date(timeIntervalSince1970: Double(hb0))
    let row = HistoryRow(bucket: hb0, project: "P", model: "M", counts: TokenCounts(output: 10))
    var corrected = row
    corrected.output = 42

    try store.append(rows: [row])
    try store.append(rows: [corrected])          // simulates a crash-orphan rewrite

    let read = try store.rows(in: start...start.addingTimeInterval(900))
    #expect(read.rows.count == 1)
    #expect(read.rows.first?.output == 42)
}

@Test func aCorruptHistoryLineIsSkippedAndCounted() throws {
    let (store, dir) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let start = Date(timeIntervalSince1970: Double(hb0))
    try store.append(rows: [HistoryRow(bucket: hb0, project: "P", model: "M",
                                       counts: TokenCounts(output: 7))])
    let file = dir.appendingPathComponent(HistoryFileName.forBucket(hb0))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{not json\n".utf8))
    try handle.close()

    let read = try store.rows(in: start...start.addingTimeInterval(900))
    #expect(read.rows.count == 1)
    #expect(read.skipped > 0)
}

@Test func coverageRoundTripsThroughItsLog() throws {
    // ⚠️ Real 900-spaced bucket starts, not toy integers — under bucket-index
    // algebra, 100/200/300/400 all map to bucket 0 and correctly merge into ONE
    // range, so a toy fixture fails against a correct implementation.
    let (store, dir) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    try store.appendCoverage(CoverageRecord(from: hb0, through: hb0 + 900, filledBy: "scan"))
    try store.appendCoverage(CoverageRecord(from: hb0 + 900 * 50, through: hb0 + 900 * 51,
                                            filledBy: "fill", truncated: true))
    let coverage = try store.loadCoverage()
    #expect(coverage.ranges.count == 2)
    #expect(coverage.records.last?.truncated == true)
}

@Test func windowRowsRoundTripWithISO8601Dates() throws {
    let (store, dir) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let row = WindowRow(start: Date(timeIntervalSince1970: 1_786_924_800),
                        end: Date(timeIntervalSince1970: 1_787_529_600),
                        counts: TokenCounts(output: 5), finalPercent: 87,
                        finalPercentAt: Date(timeIntervalSince1970: 1_787_000_000),
                        finalPercentSource: "live", boundsSource: .observed,
                        observedResetsAt: Date(timeIntervalSince1970: 1_787_529_600))
    try store.appendWindows([row])
    // Readable in a spreadsheet: ISO strings, never reference-date doubles.
    let raw = try String(contentsOf: dir.appendingPathComponent("windows.jsonl"), encoding: .utf8)
    #expect(raw.contains("2026-"))
    #expect(!raw.contains("776601600"))
    #expect(try store.loadWindows() == [row])
}

@Test func trackingRoundTripsAndAnIncompatibleVersionIsDiscarded() throws {
    let (store, dir) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let entry = TrackingEntry(percent: 40, at: Date(timeIntervalSince1970: 1_787_000_000),
                              resetsAt: Date(timeIntervalSince1970: 1_787_529_600))
    try store.saveTracking(TrackingFile(entries: [entry]))
    #expect(try store.loadTracking().entries == [entry])

    // Positive control: a file from a future/unknown version is discarded, not
    // migrated — "discarded" and "loaded but equal" are indistinguishable
    // without asserting the difference.
    //
    // ⚠️ The entry here must be NON-EMPTY, and that is the whole point.
    // `{"version":99,"entries":[]}` decodes to something whose entries are
    // already empty, so it passes with the version check deleted outright —
    // measured. Only a readable file that WOULD have loaded something proves
    // the version gate fired.
    try Data(#"{"version":99,"entries":[{"percent":9,"at":"2026-08-16T00:00:00Z","resetsAt":"2026-08-20T00:00:00Z"}]}"#.utf8)
        .write(to: dir.appendingPathComponent("tracking.json"))
    #expect(try store.loadTracking().entries.isEmpty)
}

@Test func aNilObservationNeverClearsTheAnchor() throws {
    let (store, dir) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let anchor = Date(timeIntervalSince1970: 1_787_529_600)
    try store.saveManifest(HistoryManifest(lastObservedReset: anchor))
    try store.advanceAnchor(nil)          // a launch fill commits before any capture lands
    #expect(try store.loadManifest().lastObservedReset == anchor)
}

@Test func theAnchorOnlyMovesForward() throws {
    let (store, dir) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let later = Date(timeIntervalSince1970: 1_787_529_600)
    try store.saveManifest(HistoryManifest(lastObservedReset: later))
    try store.advanceAnchor(later.addingTimeInterval(-7 * 86_400))
    #expect(try store.loadManifest().lastObservedReset == later)
}

@Test func readingAnAbsentArchiveIsEmptyNotAnError() throws {
    let (store, dir) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let start = Date(timeIntervalSince1970: Double(hb0))
    #expect(try store.rows(in: start...start.addingTimeInterval(900)).rows.isEmpty)
    #expect(try store.loadCoverage().ranges.isEmpty)
    #expect(try store.loadWindows().isEmpty)
    #expect(try store.loadManifest().lastObservedReset == nil)
}
