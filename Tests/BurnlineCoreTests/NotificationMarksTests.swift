import Foundation
import Testing
@testable import BurnlineCore

@Test func markSuppressesOnlyItsOwnWindowAndThreshold() {
    let reset: TimeInterval = 1_800_000_000
    let mark = NotificationMarks.Mark(resetsAt: reset, threshold: 90)

    #expect(NotificationMarks.suppresses(mark, resetsAt: reset, threshold: 90))
    // Reset instants compare with tolerance, never exactly: the two capture
    // sources report the same window 0.58s apart (measured), and .iso8601
    // round-trips truncate fractional seconds.
    #expect(NotificationMarks.suppresses(mark, resetsAt: reset + 59, threshold: 90))
    // The measured real-world skew between the two sources is 0.58s.
    #expect(NotificationMarks.suppresses(mark, resetsAt: reset + 0.58, threshold: 90))
    #expect(!NotificationMarks.suppresses(mark, resetsAt: reset + 61, threshold: 90))
    // A different threshold is fresh intent — the mark does not suppress it.
    #expect(!NotificationMarks.suppresses(mark, resetsAt: reset, threshold: 85))
    // No mark never suppresses.
    #expect(!NotificationMarks.suppresses(nil, resetsAt: reset, threshold: 90))
}

@Test func marksStoreRoundTrips() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = NotificationMarksStore(directory: dir)
    var marks = NotificationMarks()
    marks.weekly = NotificationMarks.Mark(resetsAt: 1_800_000_000, threshold: 90)
    try store.save(marks)
    #expect(store.load() == marks)
}

@Test func marksFromAnUnknownVersionAreDiscarded() throws {
    // Positive control required: "discarded" and "loaded but empty" are
    // indistinguishable without the paired same-content compatible load.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notification-marks.json")
    let store = NotificationMarksStore(directory: dir)

    let mark = "{\"resetsAt\":1800000000,\"threshold\":90}"
    try Data("{\"version\":999,\"weekly\":\(mark)}".utf8).write(to: url)
    #expect(store.load() == NotificationMarks())      // discarded

    try Data("{\"version\":1,\"weekly\":\(mark)}".utf8).write(to: url)
    let loaded = store.load()                          // control: same bytes, valid version
    #expect(loaded.weekly?.threshold == 90)
}
