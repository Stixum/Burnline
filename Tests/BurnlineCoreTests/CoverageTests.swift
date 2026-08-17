import Testing
import Foundation
@testable import BurnlineCore

// Real bucket starts, each one bucket after the last.
private let b0 = 1_786_924_800
private let b1 = 1_786_925_700
private let b2 = 1_786_926_600
private let b3 = 1_786_927_500

@Test func adjacentBucketsMergeIntoOneRange() {
    // 🔴 THE test for this unit. Two commits contiguous in BUCKETS are 900
    // apart in seconds. Merge with `+1` in second-space and they never join —
    // uncovered() then reports 899-second pseudo-gaps forever and no window is
    // ever fully covered, so no window row is ever written. Silently.
    let coverage = Coverage(records: [
        CoverageRecord(from: b0, through: b1, filledBy: "fill"),
        CoverageRecord(from: b2, through: b3, filledBy: "scan"),
    ])
    #expect(coverage.ranges.count == 1)
    #expect(coverage.uncovered(from: b0, through: b3).isEmpty)
}

@Test func coverageMergesOverlappingRanges() {
    let coverage = Coverage(records: [
        CoverageRecord(from: b0, through: b2, filledBy: "fill"),
        CoverageRecord(from: b1, through: b3, filledBy: "scan"),
    ])
    #expect(coverage.ranges.count == 1)
}

@Test func coverageKeepsAnInteriorGapSeparate() {
    let far = b0 + 900 * 100
    let coverage = Coverage(records: [
        CoverageRecord(from: b0, through: b1, filledBy: "fill"),
        CoverageRecord(from: far, through: far + 900, filledBy: "scan"),
    ])
    #expect(coverage.ranges.count == 2)
    #expect(coverage.gaps(in: b0...(far + 900)) == [b2...(far - 900)])
}

@Test func coverageContainsIsInclusiveOfBothEnds() {
    let coverage = Coverage(records: [CoverageRecord(from: b0, through: b2, filledBy: "scan")])
    #expect(coverage.contains(b0))
    #expect(coverage.contains(b2))
    #expect(!coverage.contains(b0 - 900))
    #expect(!coverage.contains(b3))
}

@Test func uncoveredReturnsWholeBucketsNotSecondSlivers() {
    let coverage = Coverage(records: [CoverageRecord(from: b1, through: b2, filledBy: "scan")])
    #expect(coverage.uncovered(from: b0, through: b3) == [b0...b0, b3...b3])
}

@Test func uncoveredIsEverythingWhenNothingIsCovered() {
    #expect(Coverage(records: []).uncovered(from: b0, through: b1) == [b0...b1])
}

@Test func coversIsTrueOnlyWhenEveryBucketIsHeld() {
    let coverage = Coverage(records: [CoverageRecord(from: b0, through: b2, filledBy: "scan")])
    #expect(coverage.covers(from: b0, through: b2))
    #expect(!coverage.covers(from: b0, through: b3))
}

@Test func anInvertedRecordIsSkippedRatherThanTrapping() {
    // A decoded `from > through` would trap in the ClosedRange constructor —
    // and HistoryWriter loads coverage at launch, so one malformed line would
    // be a crash loop rather than a degraded read.
    let coverage = Coverage(records: [
        CoverageRecord(from: b3, through: b0, filledBy: "corrupt"),
        CoverageRecord(from: b0, through: b1, filledBy: "scan"),
    ])
    #expect(coverage.ranges.count == 1)
    #expect(coverage.contains(b0))
}
