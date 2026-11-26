import Testing
import Foundation
@testable import BurnlineCore

// The History window re-reads the archive when `HistoryWriter.revision` moves.
// Before this, nothing told an open window the archive had changed: its read
// stayed on screen for a day while the live "now" line moved on (2026-11-26:
// the chart sat at 41% with 74% on disk). These pin the two halves Core owns:
// the writer says when it wrote, and the header says when the window last read
// and whether that read has fallen behind.

// MARK: - Fixtures

private func reloadDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("burnline-reload-\(UUID().uuidString)")
}

private let reloadZone = TimeZone(identifier: "America/Chicago")!

private let reloadSchedule = ResetSchedule(weekday: 5, hour: 9, minute: 0, timeZone: reloadZone)

private let reloadStep = Int(Bucket.seconds)

/// A closed bucket two hours back, so the clamp never refuses the claim
/// whenever the suite runs.
private func closedBucket() -> Int {
    (Bucket.key(for: Date()) - 8) * reloadStep
}

private func reloadCell(_ bucket: Int) -> HistoryRow {
    HistoryRow(bucket: bucket, project: "bus-times", model: "claude-opus-5",
               counts: TokenCounts(output: 3))
}

/// Whole seconds, because `tracking.json` stores `.iso8601` (whole seconds) and
/// `observe` compares a new entry against the decoded file: an entry with a
/// fraction never equals its own stored copy, so it is appended again.
private func reloadEntry(_ percent: Double, minutesAgo: Double) -> TrackingEntry {
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    return TrackingEntry(percent: percent, at: now.addingTimeInterval(-minutesAgo * 60),
                         resetsAt: now.addingTimeInterval(3 * 86_400))
}

// MARK: - The writer says when it wrote

@Test func aNewObservationAdvancesTheArchiveRevision() async throws {
    let dir = reloadDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = HistoryWriter(store: HistoryStore(directory: dir), schedule: reloadSchedule)

    let before = await writer.revision
    await writer.observe(reloadEntry(41, minutesAgo: 30))
    let afterFirst = await writer.revision
    #expect(afterFirst > before)

    // The reading that the 2026-11-26 window never showed.
    await writer.observe(reloadEntry(44, minutesAgo: 1))
    #expect(await writer.revision > afterFirst)
}

@Test func aRepublishedObservationLeavesTheRevisionAlone() async throws {
    // An idle terminal republishes the same reading every 30 seconds. Counting
    // that as a write would re-read the whole archive for nothing, forever.
    let dir = reloadDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = HistoryWriter(store: HistoryStore(directory: dir), schedule: reloadSchedule)

    let entry = reloadEntry(61, minutesAgo: 5)
    await writer.observe(entry)
    let once = await writer.revision
    for _ in 0..<3 { await writer.observe(entry) }
    #expect(await writer.revision == once)
}

@Test func aFlushThatWritesCellsAdvancesTheArchiveRevision() async throws {
    let dir = reloadDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = HistoryWriter(store: HistoryStore(directory: dir), schedule: reloadSchedule)

    let bucket = closedBucket()
    let before = await writer.revision
    await writer.commit(payload: HistoryArchive.Payload(rows: [reloadCell(bucket)],
                                                        span: bucket...bucket),
                        filledBy: "scan", observation: nil)
    #expect(await writer.revision > before)
}

@Test func aFlushWithNothingNewLeavesTheArchiveRevisionAlone() async throws {
    // The ordinary 60-second flush on an idle Mac: no cells, no coverage, no
    // window. The open window must not re-read for it.
    let dir = reloadDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = HistoryWriter(store: HistoryStore(directory: dir), schedule: reloadSchedule)

    let bucket = closedBucket()
    await writer.commit(payload: HistoryArchive.Payload(rows: [reloadCell(bucket)],
                                                        span: bucket...bucket),
                        filledBy: "scan", observation: nil)
    let settled = await writer.revision
    for _ in 0..<3 {
        await writer.commit(payload: HistoryArchive.Payload(rows: [], span: nil),
                            filledBy: "scan", observation: nil)
    }
    #expect(await writer.revision == settled)
}

// MARK: - The header says when the window read

private let readInstant = Date(timeIntervalSince1970: 1_795_672_800) // 2026-11-26 06:00:00Z, midnight in Chicago

private func freshnessLine(readRevision: Int, archiveRevision: Int,
                           changedSecondsAfterRead: TimeInterval?,
                           nowSecondsAfterRead: TimeInterval,
                           readAt: Date = readInstant) -> HistoryFreshness.Line {
    HistoryFreshness.line(
        read: HistoryReadState(readAt: readAt, revision: readRevision),
        archiveRevision: archiveRevision,
        archiveChangedAt: changedSecondsAfterRead.map { readAt.addingTimeInterval($0) },
        now: readAt.addingTimeInterval(nowSecondsAfterRead),
        timeZone: reloadZone)
}

@Test func aReadThatHoldsEveryWriteSaysWhenItWasRead() {
    let line = freshnessLine(readRevision: 7, archiveRevision: 7,
                             changedSecondsAfterRead: nil, nowSecondsAfterRead: 3_600)
    #expect(!line.isBehind)
    #expect(line.text == "Read at 12:00 AM")
}

@Test func aReadTheArchiveHasMovedPastIsFlaggedOnceTheReloadIsOverdue() {
    // The defect itself: a write landed and the window still shows the old
    // read a minute and more later. Say so, rather than draw an old curve
    // beside a live "now" line.
    let line = freshnessLine(readRevision: 7, archiveRevision: 8,
                             changedSecondsAfterRead: 600,
                             nowSecondsAfterRead: 600 + HistoryFreshness.grace + 1)
    #expect(line.isBehind)
    #expect(line.text == "Last read at 12:00 AM. Newer readings are not shown yet.")
}

@Test func aWriteTheReloadHasNotHadTimeToReadIsNotYetFlagged() {
    // A reload starts the moment the revision moves and takes well under a
    // second. Flagging inside the grace would flash a warning on every write.
    let line = freshnessLine(readRevision: 7, archiveRevision: 8,
                             changedSecondsAfterRead: 600, nowSecondsAfterRead: 610)
    #expect(!line.isBehind)
}

@Test func anOldReadWithNoWriteSinceIsNotFlagged() {
    // An idle Mac writes nothing for hours. An old read of an unchanged
    // archive is a current read.
    let line = freshnessLine(readRevision: 7, archiveRevision: 7,
                             changedSecondsAfterRead: nil, nowSecondsAfterRead: 86_400)
    #expect(!line.isBehind)
}

@Test func theReadTimeIsShownToTheNearestMinute() {
    // Every instant the user reads is to the nearest minute (CLAUDE.md, UI).
    let line = freshnessLine(readRevision: 1, archiveRevision: 1,
                             changedSecondsAfterRead: nil, nowSecondsAfterRead: 60,
                             readAt: readInstant.addingTimeInterval(-0.5))
    #expect(line.text == "Read at 12:00 AM")
}

@Test func aReadFromAnotherDayNamesTheDay() {
    // The 2026-11-26 case: a read from the day before. "11:07 AM" alone would
    // be taken as this morning's.
    let line = freshnessLine(readRevision: 7, archiveRevision: 40,
                             changedSecondsAfterRead: 3_600,
                             nowSecondsAfterRead: 29 * 3_600)
    #expect(line.isBehind)
    #expect(line.text == "Last read at Thu 12:00 AM. Newer readings are not shown yet.")
}

@Test func aReadTakenAfterTheLastWriteIsNotFlaggedHoweverOldTheWrite() {
    // The window read revision 8 after it landed; an hour later nothing new
    // has been written. That read is current, even though the write is old.
    let line = freshnessLine(readRevision: 8, archiveRevision: 8,
                             changedSecondsAfterRead: -1, nowSecondsAfterRead: 3_600)
    #expect(!line.isBehind)
    #expect(line.text == "Read at 12:00 AM")
}

// MARK: - The writer counts only writes that landed

@Test func cellsForTheBucketStillFillingAdvanceTheRevision() async throws {
    // A busy minute: the flush restates the bucket still filling and claims no
    // coverage (the clamp refuses an unclosed bucket). Those rows are the only
    // write, so they must move the revision or the window sees new cells only
    // every 15 minutes.
    let dir = reloadDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = HistoryWriter(store: HistoryStore(directory: dir), schedule: reloadSchedule)

    let filling = Bucket.key(for: Date()) * reloadStep
    let before = await writer.revision
    await writer.commit(payload: HistoryArchive.Payload(rows: [reloadCell(filling)],
                                                        span: filling...filling),
                        filledBy: "scan", observation: nil)
    #expect(await writer.currentCoverage().contains(filling) == false)
    #expect(await writer.revision > before)
}

/// A "directory" that is a regular file: every write under it throws.
private func unwritableDirectory() throws -> URL {
    let url = reloadDirectory()
    try Data("not a directory".utf8).write(to: url)
    return url
}

@Test func aTrackingWriteThatFailsLeavesTheRevisionAlone() async throws {
    let dir = try unwritableDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = HistoryWriter(store: HistoryStore(directory: dir), schedule: reloadSchedule)

    await writer.observe(reloadEntry(41, minutesAgo: 3))
    #expect(await writer.revision == 0)
}

@Test func aCellWriteThatFailsLeavesTheRevisionAlone() async throws {
    let dir = try unwritableDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = HistoryWriter(store: HistoryStore(directory: dir), schedule: reloadSchedule)

    let bucket = closedBucket()
    await writer.commit(payload: HistoryArchive.Payload(rows: [reloadCell(bucket)],
                                                        span: bucket...bucket),
                        filledBy: "scan", observation: nil)
    #expect(await writer.revision == 0)
}

// MARK: - The reload key and the cache

private func archiveKey(revision: Int) -> HistoryReload.ArchiveKey {
    HistoryReload.ArchiveKey(fill: .finished, weights: .default, archiveRevision: revision)
}

@Test func twoReloadKeysDifferingOnlyInRevisionAreUnequal() {
    // The bug: nothing in the key moved after the launch fill. The revision
    // is the field that does.
    #expect(archiveKey(revision: 7) != archiveKey(revision: 8))
    #expect(archiveKey(revision: 7) == archiveKey(revision: 7))
}

@Test func aCachedReadIsNeverReusedAcrossANewRevision() {
    // Two seconds old, so age alone would reuse it: the original bug for up
    // to the cache lifetime.
    let readAt = Date()
    #expect(!HistoryReload.mayReuse(cachedRevision: 7, cachedAt: readAt, revision: 8,
                                    now: readAt.addingTimeInterval(2)))
}

@Test func aYoungCachedReadAnswersAPickerChange() {
    let readAt = Date()
    #expect(HistoryReload.mayReuse(cachedRevision: 7, cachedAt: readAt, revision: 7,
                                   now: readAt.addingTimeInterval(2)))
}

@Test func anOldCachedReadIsNotReusedEvenUnderTheSameRevision() {
    let readAt = Date()
    #expect(!HistoryReload.mayReuse(cachedRevision: 7, cachedAt: readAt, revision: 7,
                                    now: readAt.addingTimeInterval(HistoryReload.cacheLifetime)))
}

// MARK: - Publishing the revision

@Test func anUnchangedRevisionIsNotRepublished() {
    // Restamping it on every flush would keep `changedAt` young forever, and
    // the amber "Last read at" line could never show on a busy Mac.
    let current = HistoryReload.Published(revision: 8, changedAt: readInstant)
    #expect(HistoryReload.publish(writerRevision: 8, over: current,
                                  now: readInstant.addingTimeInterval(600)) == nil)
}

@Test func aNewRevisionIsPublishedWithTheMomentItArrived() {
    let current = HistoryReload.Published(revision: 8, changedAt: readInstant)
    let arrived = readInstant.addingTimeInterval(600)
    #expect(HistoryReload.publish(writerRevision: 9, over: current, now: arrived)
            == HistoryReload.Published(revision: 9, changedAt: arrived))
}
