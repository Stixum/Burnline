import Testing
import Foundation
@testable import BurnlineCore

private let assistantLine = """
{"type":"assistant","timestamp":"2026-08-10T18:51:57.446Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":26527,"cache_read_input_tokens":30640,"output_tokens":135}}}
"""

private func parse(_ text: String) -> [UsageRecord] {
    TranscriptParser().parse(Data(text.utf8))
}

@Test func parsesAnAssistantLine() {
    let records = parse(assistantLine + "\n")
    #expect(records.count == 1)
    #expect(records[0].model == "claude-sonnet-5")
    #expect(records[0].inputTokens == 2)
    #expect(records[0].outputTokens == 135)
    #expect(records[0].cacheWriteTokens == 26527)
    #expect(records[0].cacheReadTokens == 30640)
}

@Test func parsesFractionalSecondTimestamps() {
    let records = parse(assistantLine + "\n")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    #expect(calendar.component(.hour, from: records[0].timestamp) == 18)
    #expect(calendar.component(.minute, from: records[0].timestamp) == 51)
}

@Test func parsesTimestampsWithoutFractionalSeconds() {
    let line = assistantLine.replacingOccurrences(of: "57.446Z", with: "57Z")
    #expect(parse(line + "\n").count == 1)
}

@Test func skipsMalformedLinesAndKeepsGoing() {
    let text = "not json at all\n" + assistantLine + "\n{\"broken\":\n"
    #expect(parse(text).count == 1)
}

@Test func ignoresNonAssistantLines() {
    let user = #"{"type":"user","timestamp":"2026-08-10T18:00:00.000Z","message":"a plain string"}"#
    let text = user + "\n" + assistantLine + "\n"
    #expect(parse(text).count == 1)
}

@Test func ignoresAssistantLinesWithoutUsage() {
    let noUsage = #"{"type":"assistant","timestamp":"2026-08-10T18:00:00.000Z","message":{"model":"claude-opus-5"}}"#
    #expect(parse(noUsage + "\n").isEmpty)
}

@Test func doesNotDoubleCountIterations() {
    // `iterations` restates the same totals. Only the outer numbers may count.
    let withIterations = """
    {"type":"assistant","timestamp":"2026-08-10T18:51:57.446Z","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"iterations":[{"input_tokens":10,"output_tokens":20}]}}}
    """
    let records = parse(withIterations + "\n")
    #expect(records.count == 1)
    #expect(records[0].inputTokens == 10)
    #expect(records[0].outputTokens == 20)
}

@Test func treatsMissingTokenFieldsAsZero() {
    let sparse = #"{"type":"assistant","timestamp":"2026-08-10T18:00:00.000Z","message":{"model":"claude-opus-5","usage":{"output_tokens":7}}}"#
    let records = parse(sparse + "\n")
    #expect(records[0].inputTokens == 0)
    #expect(records[0].cacheReadTokens == 0)
    #expect(records[0].outputTokens == 7)
}

@Test func skipsLinesWithNoTimestamp() {
    let noTime = #"{"type":"assistant","message":{"model":"claude-opus-5","usage":{"output_tokens":7}}}"#
    #expect(parse(noTime + "\n").isEmpty)
}

@Test func handlesAnEmptyModelName() {
    let noModel = #"{"type":"assistant","timestamp":"2026-08-10T18:00:00.000Z","message":{"usage":{"output_tokens":7}}}"#
    let records = parse(noModel + "\n")
    #expect(records.count == 1)
    #expect(records[0].model == "")
}

// MARK: - One message, several content blocks

/// Claude Code writes one assistant line per content block (text, tool_use…),
/// each restating the same `message.id` and byte-identical `usage`. Measured on
/// 40 real transcripts on 2026-10-01: 56% of usage-bearing lines were such
/// repeats. The usage describes the whole message, so it counts once.
private func block(id: String, output: Int = 135) -> String {
    """
    {"type":"assistant","timestamp":"2026-08-10T18:51:57.446Z","requestId":"req_\(id)","message":{"id":"\(id)","model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\(output)}}}\n
    """
}

@Test func contentBlocksOfOneMessageCountOnce() {
    let records = parse(block(id: "msg_a") + block(id: "msg_a") + block(id: "msg_a"))
    #expect(records.count == 1)
    #expect(records[0].outputTokens == 135)
}

@Test func distinctMessagesStillCountSeparately() {
    let records = parse(block(id: "msg_a") + block(id: "msg_b"))
    #expect(records.count == 2)
}

@Test func aLineWithNoMessageIdIsNeverCollapsed() {
    // No id means no evidence of a repeat: counting is the safe default.
    let records = parse(assistantLine + "\n" + assistantLine + "\n")
    #expect(records.count == 2)
}

@Test func theMessageIdCarriesAcrossAnIncrementalBoundary() {
    // A message's blocks can straddle the scanner's read boundary. The caller
    // hands back the last message it saw so the continuation is not counted again.
    let first = TranscriptParser().parse(Data(block(id: "msg_a").utf8), after: nil)
    #expect(first.records.count == 1)
    #expect(first.lastMessage?.id == "msg_a")
    let second = TranscriptParser().parse(Data((block(id: "msg_a") + block(id: "msg_b")).utf8),
                                          after: first.lastMessage)
    #expect(second.records.count == 1)
    #expect(second.lastMessage?.id == "msg_b")
}

/// Subagent transcripts carry a PROVISIONAL figure on a message's early lines
/// and the real one on its last — measured 2026-10-01 across 5,044 subagent
/// files: 72,989 such groups, every field non-decreasing across the group,
/// and first-line-wins undercounting output tokens by 49%. The usage is
/// cumulative for the message, so the maximum per field is the figure.
@Test func aLaterBlockWithTheFinalFigureWins() {
    let records = parse(block(id: "msg_a", output: 8) + block(id: "msg_a", output: 8)
                        + block(id: "msg_a", output: 5_527))
    #expect(records.count == 1)
    #expect(records[0].outputTokens == 5_527)
}

/// The final line can land after the read boundary. What was already counted
/// for that message is handed back, and only the increase is emitted.
@Test func aContinuationEmitsOnlyTheIncrease() {
    let first = TranscriptParser().parse(Data(block(id: "msg_a", output: 8).utf8), after: nil)
    #expect(first.records.map(\.outputTokens) == [8])
    let second = TranscriptParser().parse(
        Data((block(id: "msg_a", output: 5_527) + block(id: "msg_b", output: 100)).utf8),
        after: first.lastMessage)
    #expect(second.records.map(\.outputTokens) == [5_519, 100])
    #expect(second.lastMessage == TranscriptParser.Continuation(id: "msg_b", counts: TokenCounts(input: 2, output: 100)))
}

@Test func aContinuationWithNoIncreaseEmitsNothing() {
    let first = TranscriptParser().parse(Data(block(id: "msg_a", output: 50).utf8), after: nil)
    let second = TranscriptParser().parse(Data(block(id: "msg_a", output: 50).utf8), after: first.lastMessage)
    #expect(second.records.isEmpty)
    #expect(second.lastMessage?.id == "msg_a")
}
