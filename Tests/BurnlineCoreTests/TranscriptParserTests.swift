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
