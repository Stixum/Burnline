import Testing
import Foundation
@testable import BurnlineCore

// One shared `rate-limits.json` loses every write but the last. With two
// terminal sessions open — one active, one idle — the idle session's 30s timer
// overwrites the active one's reading twice a minute. RateLimitHighWater keeps
// the correct *value* (usage is cumulative, so fresher is always >= staler), but
// the age then dates to the IDLE session's last turn, which fires a false
// "nothing is reporting" nudge while something very much is.
//
// A file per session removes the contention rather than defending against it:
// nothing is lost, so nothing needs arbitrating.

private func directoryScratch() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-capturedir-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sessionCapture(_ id: String?, percent: Double = 50,
                            capturedAt: TimeInterval = 1_000) -> RateLimitCapture {
    RateLimitCapture(version: RateLimitCapture.currentVersion, capturedAt: capturedAt,
                     sevenDay: .init(usedPercent: percent, resetsAt: 9_000), fiveHour: nil,
                     sessionId: id, transcriptPath: nil)
}

@Test func eachSessionGetsItsOwnFileSoNoWriteIsLost() throws {
    let directory = CaptureDirectory(directory: directoryScratch())
    try directory.save(sessionCapture("aaa", percent: 40))
    try directory.save(sessionCapture("bbb", percent: 75))

    #expect(Set(directory.load().map(\.sevenDay.usedPercent)) == [40, 75])
}

@Test func rewritingASessionReplacesItRatherThanAccumulating() throws {
    let directory = CaptureDirectory(directory: directoryScratch())
    try directory.save(sessionCapture("aaa", percent: 10))
    try directory.save(sessionCapture("aaa", percent: 20))

    let loaded = directory.load()
    #expect(loaded.count == 1)
    #expect(loaded.first?.sevenDay.usedPercent == 20)
}

/// Nothing to key the file on. The caller falls back to the shared file.
@Test func aCaptureWithNoSessionIdIsRefused() {
    let directory = CaptureDirectory(directory: directoryScratch())
    #expect(throws: (any Error).self) { try directory.save(sessionCapture(nil)) }
}

/// A session id becomes a filename. Anything that could escape the directory is
/// refused outright rather than sanitised into something surprising.
@Test func anUnsafeSessionIdIsRefusedNotSanitised() {
    let scratch = directoryScratch()
    let directory = CaptureDirectory(directory: scratch)
    #expect(throws: (any Error).self) { try directory.save(sessionCapture("../../escape")) }
    #expect(directory.load().isEmpty)
}

@Test func corruptAndIncompatibleCaptureFilesAreSkippedNotFatal() throws {
    let scratch = directoryScratch()
    let directory = CaptureDirectory(directory: scratch)
    try directory.save(sessionCapture("good", percent: 60))
    let dir = scratch.appendingPathComponent("captures", isDirectory: true)
    try Data("{ not json".utf8).write(to: dir.appendingPathComponent("bad.json"))
    try Data(#"{"version":99,"capturedAt":1,"sevenDay":{"usedPercent":1,"resetsAt":2}}"#.utf8)
        .write(to: dir.appendingPathComponent("old.json"))

    #expect(directory.load().map(\.sevenDay.usedPercent) == [60])
}

/// One file per session, and sessions are created constantly. Nothing else
/// would ever delete them.
@Test func prunesCapturesFromOutsideTheCurrentWindow() throws {
    let scratch = directoryScratch()
    let directory = CaptureDirectory(directory: scratch)
    try directory.save(sessionCapture("stale", percent: 10, capturedAt: 100))
    try directory.save(sessionCapture("current", percent: 20, capturedAt: 5_000))

    directory.prune(before: 1_000)

    #expect(directory.load().map(\.sevenDay.usedPercent) == [20])
}

// MARK: - Choosing between them

/// The point of keeping every session's write: the freshest reading wins on its
/// own merits rather than on who happened to write last.
@Test func theFreshestCaptureWinsRegardlessOfWriteOrder() {
    let idle = sessionCapture("idle", percent: 70, capturedAt: 1_000)
    let active = sessionCapture("active", percent: 75, capturedAt: 8_000)

    #expect(CaptureDirectory.freshest(of: [idle, active])?.sevenDay.usedPercent == 75)
}

@Test func freshestOfNothingIsNothing() {
    #expect(CaptureDirectory.freshest(of: []) == nil)
}

/// Same instant, cumulative usage — the larger figure is the later one.
@Test func freshestBreaksATieOnTheHigherPercentage() {
    let a = sessionCapture("a", percent: 70, capturedAt: 5_000)
    let b = sessionCapture("b", percent: 75, capturedAt: 5_000)

    #expect(CaptureDirectory.freshest(of: [a, b])?.sevenDay.usedPercent == 75)
}
