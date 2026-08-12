import Testing
import Foundation
@testable import BurnlineCore

// An assistant message IS an API response, and a session's `rate_limits` block
// refreshes only when that session calls the API. So the last assistant turn at
// or before the moment the helper saw the payload is when the reading was
// minted — an exact instant, where the five-hour rule gives only an upper bound.

private func datingTranscript(_ lines: [String]) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-dating-\(UUID().uuidString).jsonl")
    try? Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: url)
    return url
}

private func assistantTurn(_ iso: String) -> String {
    #"{"type":"assistant","timestamp":"\#(iso)","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":1}}}"#
}

private func epoch(_ iso: String) -> TimeInterval {
    ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970
}

@Test func datesACaptureByTheLastAssistantTurn() {
    let url = datingTranscript([assistantTurn("2026-08-11T18:00:00.000Z"),
                                assistantTurn("2026-08-11T20:30:00.000Z")])
    #expect(TranscriptDating.mintedAt(transcriptPath: url.path,
                                      observedAt: epoch("2026-08-11T21:00:00Z"))
            == epoch("2026-08-11T20:30:00Z"))
}

/// A turn that happened after we read the payload cannot have minted it.
@Test func ignoresAssistantTurnsAfterTheObservation() {
    let url = datingTranscript([assistantTurn("2026-08-11T18:00:00.000Z"),
                                assistantTurn("2026-08-11T23:00:00.000Z")])
    #expect(TranscriptDating.mintedAt(transcriptPath: url.path,
                                      observedAt: epoch("2026-08-11T19:00:00Z"))
            == epoch("2026-08-11T18:00:00Z"))
}

@Test func aMissingTranscriptYieldsNoMintTime() {
    #expect(TranscriptDating.mintedAt(transcriptPath: "/nope/missing.jsonl",
                                      observedAt: 1_786_500_000) == nil)
}

/// User turns are not API responses. Only an assistant turn dates the reading.
@Test func aTranscriptWithNoAssistantTurnsYieldsNoMintTime() {
    let url = datingTranscript([#"{"type":"user","timestamp":"2026-08-11T18:00:00.000Z"}"#])
    #expect(TranscriptDating.mintedAt(transcriptPath: url.path,
                                      observedAt: 1_786_500_000) == nil)
}

/// Transcripts run to megabytes; only the tail is read and the answer must still
/// be right. Also pins that a partial first line never reaches the parser — the
/// tail almost always starts mid-line.
@Test func readsOnlyTheTailAndStillFindsTheLastTurn() {
    var lines = (0..<5_000).map { _ in
        #"{"type":"user","timestamp":"2026-08-11T10:00:00.000Z","pad":"\#(String(repeating: "x", count: 200))"}"#
    }
    lines.append(assistantTurn("2026-08-11T20:30:00.000Z"))
    let url = datingTranscript(lines)

    #expect(TranscriptDating.mintedAt(transcriptPath: url.path,
                                      observedAt: epoch("2026-08-11T21:00:00Z"))
            == epoch("2026-08-11T20:30:00Z"))
}

/// The whole point, end to end: a capture stamped now, whose session last spoke
/// three hours ago, is three hours old.
@Test func anIdleSessionsCaptureIsDatedToItsLastTurnNotToNow() {
    let url = datingTranscript([assistantTurn("2026-08-11T18:00:00.000Z")])
    let observed = epoch("2026-08-11T21:00:00Z")
    let capture = RateLimitCapture(version: 1, capturedAt: observed,
                                   sevenDay: .init(usedPercent: 69, resetsAt: observed + 86_400),
                                   fiveHour: nil,
                                   sessionId: "s", transcriptPath: url.path)

    let minted = TranscriptDating.mintedAt(transcriptPath: url.path, observedAt: observed)
    #expect(capture.dated(mintedAt: minted).capturedAt == epoch("2026-08-11T18:00:00Z"))
}
