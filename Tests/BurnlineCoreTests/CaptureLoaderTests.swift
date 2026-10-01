import Testing
import Foundation
@testable import BurnlineCore

// Gathering the capture candidates is file I/O: a directory listing, the shared
// file, the ~/.claude.json block, and a 256 KB transcript tail per dated
// candidate. `UsageStore.rebuild()` used to do all of it on the main actor every
// ten seconds and on every settings mutation — one keystroke in a weights field
// read transcripts. The loader is an actor so that work hops off the UI thread,
// and it lives in Core so the gathering rule has a test.

private func scratchDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-loader-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func transcript(lastTurnAt iso: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-loader-\(UUID().uuidString).jsonl")
    let line = #"{"type":"assistant","timestamp":"\#(iso)","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":1}}}"#
    try? Data((line + "\n").utf8).write(to: url)
    return url
}

private func config(fetchedAtMs: Int) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-loader-\(UUID().uuidString).json")
    let json = """
    {"cachedUsageUtilization":{"fetchedAtMs":\(fetchedAtMs),
      "utilization":{"seven_day":{"utilization":75,"resets_at":"2026-08-14T07:00:00.818653+00:00"}}}}
    """
    try? Data(json.utf8).write(to: url)
    return url
}

private let farFuture: TimeInterval = 4_000_000_000

@Test func theLoaderGathersAllThreeSourcesAndDatesThem() async throws {
    let directory = scratchDirectory()
    let lastTurn = ISO8601DateFormatter().date(from: "2026-08-11T20:30:00Z")!.timeIntervalSince1970
    let session = RateLimitCapture(
        version: 1, capturedAt: lastTurn + 600,
        sevenDay: .init(usedPercent: 40, resetsAt: farFuture), fiveHour: nil,
        sessionId: "abc", transcriptPath: transcript(lastTurnAt: "2026-08-11T20:30:00.000Z").path)
    try CaptureDirectory(directory: directory).save(session)
    try RateLimitStore(directory: directory).save(
        RateLimitCapture(version: 1, capturedAt: 1_000,
                         sevenDay: .init(usedPercent: 30, resetsAt: farFuture), fiveHour: nil))

    let loader = CaptureLoader(directory: directory, configPath: config(fetchedAtMs: 1_786_542_556_418))
    let loaded = await loader.load()

    #expect(Set(loaded.candidates.map(\.sevenDay.usedPercent)) == [40, 30, 75])
    let dated = try #require(loaded.candidates.first { $0.sessionId == "abc" })
    #expect(dated.capturedAt == lastTurn)
    #expect(dated.provenAt == lastTurn)
    #expect(loaded.utilization?.fetchedAt == 1_786_542_556.418)
}

@Test func anEmptyDirectoryLoadsNoCandidates() async {
    let loader = CaptureLoader(directory: scratchDirectory(),
                               configPath: scratchDirectory().appendingPathComponent("missing.json"))
    let loaded = await loader.load()
    #expect(loaded.candidates.isEmpty)
    #expect(loaded.utilization == nil)
}
