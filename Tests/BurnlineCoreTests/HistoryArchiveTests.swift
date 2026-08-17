import Testing
import Foundation
@testable import BurnlineCore

private let bucketStart = 1_786_924_800     // divisible by 900

private func cache(files: [String: [String: TokenCounts]]) -> ScanCache {
    var cache = ScanCache()
    let key = String(Bucket.key(for: Date(timeIntervalSince1970: Double(bucketStart))))
    for (path, byModel) in files {
        cache.files[path] = FileState(modifiedAt: Date(), size: 1, offset: 1, cells: [key: byModel])
    }
    return cache
}

@Test func cellsAreSummedAcrossFilesBeforeRowsAreEmitted() {
    // 🔴 THE test. Two session files, same project, same model, same bucket.
    // One row carrying the SUM — not two rows, and not one file's share.
    let scan = cache(files: [
        "/Users/me/.claude/projects/-Users-me-Burnline/session-a.jsonl":
            ["claude-opus-5": TokenCounts(output: 10)],
        "/Users/me/.claude/projects/-Users-me-Burnline/session-b.jsonl":
            ["claude-opus-5": TokenCounts(output: 32)],
    ])
    let rows = HistoryArchive.rows(from: scan, coverage: Coverage(records: []),
                                   through: bucketStart + 900)
    #expect(rows.count == 1)
    #expect(rows.first?.output == 42)
}

@Test func differentModelsInOneBucketStayDistinctRows() {
    let scan = cache(files: [
        "/p/projects/-Users-me-Burnline/a.jsonl": ["claude-opus-5": TokenCounts(output: 10),
                                                   "claude-sonnet-5": TokenCounts(output: 5)],
    ])
    let rows = HistoryArchive.rows(from: scan, coverage: Coverage(records: []),
                                   through: bucketStart + 900)
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.model)) == ["claude-opus-5", "claude-sonnet-5"])
}

@Test func coveredBucketsAreNotReEmitted() {
    let scan = cache(files: ["/p/projects/-Users-me-Burnline/a.jsonl":
                                ["claude-opus-5": TokenCounts(output: 10)]])
    let covered = Coverage(records: [CoverageRecord(from: bucketStart, through: bucketStart,
                                                    filledBy: "scan")])
    #expect(HistoryArchive.rows(from: scan, coverage: covered,
                                through: bucketStart + 900).isEmpty)
}

@Test func theStillFillingBucketIsNotArchived() {
    let scan = cache(files: ["/p/projects/-Users-me-Burnline/a.jsonl":
                                ["claude-opus-5": TokenCounts(output: 10)]])
    // `through` lands INSIDE the bucket, so it has not closed.
    #expect(HistoryArchive.rows(from: scan, coverage: Coverage(records: []),
                                through: bucketStart + 60).isEmpty)
}

@Test func anIdleTailIsStillClaimedAsCovered() {
    // 🔴 The span is the range SCANNED, not the extent of the rows.
    let scan = cache(files: ["/p/projects/-Users-me-Burnline/a.jsonl":
                                ["claude-opus-5": TokenCounts(output: 10)]])
    let idleUntil = bucketStart + 900 * 20        // 5 idle hours after the only row
    let payload = HistoryArchive.payload(from: scan, coverage: Coverage(records: []),
                                         through: idleUntil + 900)
    #expect(payload.rows.count == 1)
    #expect(payload.span?.lowerBound == bucketStart)
    #expect(payload.span?.upperBound == idleUntil)
}

@Test func spanIsNilWhenEverythingIsAlreadyCovered() {
    let scan = cache(files: ["/p/projects/-Users-me-Burnline/a.jsonl":
                                ["claude-opus-5": TokenCounts(output: 10)]])
    let covered = Coverage(records: [CoverageRecord(from: bucketStart,
                                                    through: bucketStart + 900 * 5,
                                                    filledBy: "scan")])
    let payload = HistoryArchive.payload(from: scan, coverage: covered,
                                         through: bucketStart + 900 * 3)
    #expect(payload.rows.isEmpty)
    #expect(payload.span == nil)
}

@Test func projectComesFromTheEncodedDirectoryNotTheParent() {
    // Session and subagent transcripts nest BELOW the encoded project dir, so
    // the parent directory is not the project.
    let scan = cache(files: [
        "/Users/me/.claude/projects/-Users-me-Burnline/sess/subagents/a.jsonl":
            ["claude-opus-5": TokenCounts(output: 7)],
    ])
    let rows = HistoryArchive.rows(from: scan, coverage: Coverage(records: []),
                                   through: bucketStart + 900)
    #expect(rows.first?.project == "Burnline")
}
