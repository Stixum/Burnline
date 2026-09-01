import Foundation
import Testing
@testable import BurnlineCore

@Test func markSuppressesOnlyItsOwnWindowAndThreshold() {
    let reset: TimeInterval = 1_800_000_000
    // Distinct from `reset`, so holding it fixed here isolates the reset and
    // threshold dimensions exactly as this test always did.
    let epoch: TimeInterval = 1_799_400_000
    let mark = NotificationMarks.Mark(resetsAt: reset, threshold: 90,
                                      epochStartedAt: epoch)

    #expect(NotificationMarks.suppresses(mark, resetsAt: reset, threshold: 90,
                                         epochStartedAt: epoch))
    // Reset instants compare with tolerance, never exactly: the two capture
    // sources report the same window 0.58s apart (measured), and .iso8601
    // round-trips truncate fractional seconds.
    #expect(NotificationMarks.suppresses(mark, resetsAt: reset + 59, threshold: 90,
                                         epochStartedAt: epoch))
    // The measured real-world skew between the two sources is 0.58s.
    #expect(NotificationMarks.suppresses(mark, resetsAt: reset + 0.58, threshold: 90,
                                         epochStartedAt: epoch))
    #expect(!NotificationMarks.suppresses(mark, resetsAt: reset + 61, threshold: 90,
                                          epochStartedAt: epoch))
    // A different threshold is fresh intent — the mark does not suppress it.
    #expect(!NotificationMarks.suppresses(mark, resetsAt: reset, threshold: 85,
                                          epochStartedAt: epoch))
    // No mark never suppresses.
    #expect(!NotificationMarks.suppresses(nil, resetsAt: reset, threshold: 90,
                                          epochStartedAt: epoch))
}

/// The epoch is the third dimension, and it compares the way the reset does:
/// with the shared 60s tolerance. A window start is derived from a ledger
/// anchor whose fractional second comes and goes, so exact equality would hand
/// every rebuild an epoch of its own and re-fire every signal every tick.
@Test func markEpochComparesWithTheSameResetTolerance() {
    let reset: TimeInterval = 1_800_000_000
    let epoch: TimeInterval = 1_799_400_000
    let mark = NotificationMarks.Mark(resetsAt: reset, threshold: 90,
                                      epochStartedAt: epoch)

    #expect(NotificationMarks.suppresses(mark, resetsAt: reset, threshold: 90,
                                         epochStartedAt: epoch + 0.181))
    #expect(NotificationMarks.suppresses(mark, resetsAt: reset, threshold: 90,
                                         epochStartedAt: epoch + 59))
    // Past the tolerance it is a different allowance, and the mark describes a
    // period that is over.
    #expect(!NotificationMarks.suppresses(mark, resetsAt: reset, threshold: 90,
                                          epochStartedAt: epoch + 61))
    #expect(!NotificationMarks.suppresses(mark, resetsAt: reset, threshold: 90,
                                          epochStartedAt: reset))
}

@Test func marksStoreRoundTrips() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = NotificationMarksStore(directory: dir)
    var marks = NotificationMarks()
    marks.weekly = NotificationMarks.Mark(resetsAt: 1_800_000_000, threshold: 90,
                                          epochStartedAt: 1_799_400_000)
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

    let mark = "{\"resetsAt\":1800000000,\"threshold\":90,\"epochStartedAt\":1799400000}"
    try Data("{\"version\":999,\"weekly\":\(mark)}".utf8).write(to: url)
    #expect(store.load() == NotificationMarks())      // discarded

    // Control: same bytes, this build's version. Written from the constant so
    // the next bump cannot silently turn the control into a second negative.
    try Data("{\"version\":\(NotificationMarks.currentVersion),\"weekly\":\(mark)}".utf8)
        .write(to: url)
    let loaded = store.load()
    #expect(loaded.weekly?.threshold == 90)
    #expect(loaded.weekly?.epochStartedAt == 1_799_400_000)
}

/// A v1 file predates `epochStartedAt`, so it neither decodes nor passes the
/// version check — and that IS the migration. The worst case is one repeated
/// notification.
///
/// The fixture carries a DISTINCTIVE threshold: with the ordinary 90 in it,
/// "discarded" and "loaded but happens to equal the default" are the same
/// bytes on the way out.
@Test func aV1MarksFileIsDiscardedNeverMigrated() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notification-marks.json")
    let store = NotificationMarksStore(directory: dir)

    // Exactly what v1 wrote: no epoch key, version 1.
    try Data("{\"version\":1,\"weekly\":{\"resetsAt\":1800000000,\"threshold\":73.5}}".utf8)
        .write(to: url)
    #expect(store.load().weekly == nil)
    #expect(store.load() == NotificationMarks())

    // Positive control: the same distinctive value in a v2 file DOES survive,
    // so the assertion above is about the version and the missing key rather
    // than about the store never loading anything. Version literal on purpose
    // — this fixture is the v2 *shape*, and the next bump must revisit it
    // rather than have it silently follow along.
    try Data("{\"version\":2,\"weekly\":{\"resetsAt\":1800000000,\"threshold\":73.5,\"epochStartedAt\":1799400000}}".utf8)
        .write(to: url)
    #expect(store.load().weekly?.threshold == 73.5)
}

// MARK: - Allowance epochs
//
// A re-grant re-issues the weekly allowance *inside* a window without moving
// `resets_at`. Usage then climbs from zero and can cross the same threshold a
// second time — a genuinely new event. The mark is keyed to the window, so
// without an epoch dimension it stays silent forever.
//
// 🔴 Every instant in this fixture is mutually distinct — window start,
// re-grant start, window end, and the five-hour window's own start — so a test
// can never pass by reading the wrong one.

private let epochWindowStart = Date(timeIntervalSince1970: 1_800_000_000)
private let epochWindowEnd = epochWindowStart.addingTimeInterval(7 * 86_400)
private let epochNow = epochWindowStart.addingTimeInterval(2 * 86_400)
/// Distinct from the window start, the window end, and `now`.
private let epochRegrantStart = epochWindowStart.addingTimeInterval(1.5 * 86_400)

private let epochSettings = NotificationSettings(
    enabled: true, behindPacePoints: 10, weeklyPercent: 90, fiveHourPercent: 80)

/// Reset 6_000s out, so the window's own start (reset − 5h) lands on
/// 1_800_160_800 — distinct from every other instant in the fixture.
private func epochFiveHour(_ percent: Double) -> FiveHourStatus {
    FiveHourStatus(usedPercent: percent,
                   resetsAt: epochNow.addingTimeInterval(6_000),
                   timeRemaining: 6_000)
}

private func epochSnapshot(estimate: Double,
                           regrant: Snapshot.Regrant? = nil,
                           fiveHour: FiveHourStatus? = nil) -> Snapshot {
    let window = Window(start: epochWindowStart, end: epochWindowEnd, now: epochNow)
    return Snapshot(window: window, targetPercent: window.targetPercent,
                    estimatedPercent: estimate, projectedPercent: nil,
                    unitsInWindow: 0, calibrationAge: nil,
                    source: .live(capturedAt: epochNow), isScanning: false,
                    fiveHour: fiveHour, regrant: regrant)
}

/// Fired at the weekly threshold before the re-grant; usage climbs past it
/// again in the same window. That is a new event and must notify.
@Test func aRegrantReArmsTheWeeklyThreshold() {
    let before = epochSnapshot(estimate: 92)
    let fired = NotificationDecision.evaluate(snapshot: before, settings: epochSettings,
                                              targetMode: .realTime,
                                              marks: NotificationMarks())
    #expect(fired.emissions.contains { $0.signal == .weekly })
    #expect(fired.emissions.contains { $0.signal == .behindPace })

    // The allowance is re-issued and usage climbs back over the line. Same
    // window throughout: the reset instant never moved, which is exactly why
    // the window-keyed mark cannot see this.
    let after = epochSnapshot(estimate: 92,
                              regrant: .init(startedAt: epochRegrantStart, startPercent: 0))
    #expect(after.window.end == before.window.end)
    let reArmed = NotificationDecision.evaluate(snapshot: after, settings: epochSettings,
                                                targetMode: .realTime, marks: fired.marks)
    #expect(reArmed.emissions.contains { $0.signal == .weekly })
    #expect(reArmed.emissions.contains { $0.signal == .behindPace })
}

/// POSITIVE CONTROL, and it must assert BOTH directions or it is vacuous:
/// a mark from a DIFFERENT epoch must not suppress, and a mark from the
/// CURRENT epoch must still suppress. Testing only the first passes even if
/// suppresses() were hardcoded to false.
@Test func aMarkFromTheCurrentEpochStillSuppresses() {
    let inEpoch = epochSnapshot(estimate: 92,
                                regrant: .init(startedAt: epochRegrantStart, startPercent: 0))
    let fired = NotificationDecision.evaluate(snapshot: inEpoch, settings: epochSettings,
                                              targetMode: .realTime,
                                              marks: NotificationMarks())
    #expect(fired.emissions.contains { $0.signal == .weekly })

    // Direction 1 — same epoch, still over the line: the mark holds.
    let again = NotificationDecision.evaluate(snapshot: inEpoch, settings: epochSettings,
                                              targetMode: .realTime, marks: fired.marks)
    #expect(!again.emissions.contains { $0.signal == .weekly })
    #expect(!again.emissions.contains { $0.signal == .behindPace })

    // Direction 2 — a second re-grant inside the same window opens a later
    // epoch, and that mark describes a period that is over.
    let laterEpoch = epochSnapshot(
        estimate: 92,
        regrant: .init(startedAt: epochRegrantStart.addingTimeInterval(3_600),
                       startPercent: 0))
    let third = NotificationDecision.evaluate(snapshot: laterEpoch, settings: epochSettings,
                                              targetMode: .realTime, marks: fired.marks)
    #expect(third.emissions.contains { $0.signal == .weekly })
}

/// 🔴 A weekly re-grant must NOT re-arm the five-hour signal. The two windows
/// share a `Mark` type and share nothing else: a five-hour window resets
/// several times inside one weekly window, so the weekly epoch says nothing
/// about it.
@Test func aWeeklyRegrantDoesNotReArmTheFiveHourThreshold() {
    let before = epochSnapshot(estimate: 92, fiveHour: epochFiveHour(82))
    let fired = NotificationDecision.evaluate(snapshot: before, settings: epochSettings,
                                              targetMode: .realTime,
                                              marks: NotificationMarks())
    #expect(fired.emissions.contains { $0.signal == .fiveHour })

    // Weekly allowance re-issued; the five-hour window is untouched — same
    // reset instant, same percentage.
    let after = epochSnapshot(estimate: 92,
                              regrant: .init(startedAt: epochRegrantStart, startPercent: 0),
                              fiveHour: epochFiveHour(82))
    #expect(after.fiveHour?.resetsAt == before.fiveHour?.resetsAt)
    let reArmed = NotificationDecision.evaluate(snapshot: after, settings: epochSettings,
                                                targetMode: .realTime, marks: fired.marks)
    #expect(reArmed.emissions.contains { $0.signal == .weekly })       // control: did re-arm
    #expect(!reArmed.emissions.contains { $0.signal == .fiveHour })    // 🔴 did not
}
