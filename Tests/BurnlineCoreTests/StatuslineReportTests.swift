import Testing
import Foundation
@testable import BurnlineCore

// "Connected" used to mean *configured*: the statusline entry in
// ~/.claude/settings.json names this app's helper. It said nothing about
// whether the helper RUNS — and it only runs in sessions that draw a status
// line, which the desktop app's never do. On the Mac this was written on, the
// helper had last written six days earlier while Settings showed a green tick.

// MARK: - The report

@Test func aHelperThatHasNeverWrittenIsConnectedButNotReporting() {
    let report = StatuslineReport(lastWrote: nil, now: Date())
    #expect(report == .never)
    #expect(report.title == "Connected · no report yet")
    #expect(report.isQuiet)
    #expect(report.explanation(pollEnabled: false) != nil)
}

@Test func aRecentWriteReadsAsReporting() {
    let now = Date()
    let report = StatuslineReport(lastWrote: now.addingTimeInterval(-20), now: now)
    #expect(report == .reporting(age: 20))
    #expect(report.title == "Connected · reported just now")
    #expect(!report.isQuiet)
    #expect(report.explanation(pollEnabled: false) == nil)
}

/// Same threshold as the popover's "Extrapolated" styling, so the two surfaces
/// cannot disagree about when a report has gone quiet.
@Test func aReportGoesQuietExactlyWhereACaptureGoesStale() {
    let now = Date()
    let atThreshold = StatuslineReport(lastWrote: now.addingTimeInterval(-CaptureAge.stalenessThreshold),
                                       now: now)
    let past = StatuslineReport(lastWrote: now.addingTimeInterval(-CaptureAge.stalenessThreshold - 1),
                                now: now)
    #expect(!atThreshold.isQuiet)
    #expect(past.isQuiet)
}

@Test func aQuietHelperSaysHowLongAndWhy() {
    let now = Date()
    let report = StatuslineReport(lastWrote: now.addingTimeInterval(-6 * 86_400), now: now)
    #expect(report == .quiet(age: 6 * 86_400))
    #expect(report.title == "Connected · last report 6d ago")

    let withoutPoll = report.explanation(pollEnabled: false) ?? ""
    let withPoll = report.explanation(pollEnabled: true) ?? ""
    #expect(withoutPoll.contains("desktop app"))
    #expect(withoutPoll.contains("Refresh usage automatically"))
    #expect(withPoll.contains("/usage"))
    #expect(!withPoll.contains("Refresh usage automatically"))
}

/// A clock that stepped backwards must not produce a negative age.
@Test func aWriteStampedInTheFutureReadsAsJustNow() {
    let now = Date()
    #expect(StatuslineReport(lastWrote: now.addingTimeInterval(120), now: now) == .reporting(age: 0))
}

// MARK: - Where the write time comes from

private func reportScratch() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-report-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url.appendingPathComponent("captures"),
                                             withIntermediateDirectories: true)
    return url
}

private func touch(_ url: URL, at date: Date) throws {
    try Data("{}".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

/// File modification time, not the stamp inside: the helper pulls a replay's
/// `capturedAt` back to the window it describes, so the stamp can be hours
/// older than the write. Whether the helper is RUNNING is the question here.
@Test func theLoaderReportsTheNewestWriteByTheStatuslineHelper() async throws {
    let directory = reportScratch()
    let older = Date().addingTimeInterval(-3_600)
    let newer = Date().addingTimeInterval(-60)
    try touch(directory.appendingPathComponent("rate-limits.json"), at: older)
    try touch(directory.appendingPathComponent("captures/abc.json"), at: newer)

    let loaded = await CaptureLoader(directory: directory,
                                     configPath: directory.appendingPathComponent("absent.json")).load()

    let wrote = try #require(loaded.statuslineLastWrote)
    #expect(abs(wrote.timeIntervalSince(newer)) < 1)
}

/// Control: the utilization block is refreshed by `/usage`, not by the helper,
/// so a fresh `~/.claude.json` must not make a silent helper look alive.
@Test func aFreshUtilizationBlockDoesNotCountAsTheHelperReporting() async throws {
    let directory = reportScratch()
    let config = directory.appendingPathComponent("claude.json")
    let fetchedAtMs = Int(Date().timeIntervalSince1970 * 1000)
    try Data("""
    {"cachedUsageUtilization":{"fetchedAtMs":\(fetchedAtMs),
      "utilization":{"seven_day":{"utilization":75,"resets_at":"2099-08-14T07:00:00.818653+00:00"}}}}
    """.utf8).write(to: config)

    let loaded = await CaptureLoader(directory: directory, configPath: config).load()

    #expect(!loaded.candidates.isEmpty, "the utilization source was read")
    #expect(loaded.statuslineLastWrote == nil)
}
