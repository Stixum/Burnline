import Foundation

/// Turns raw transcript bytes into usage records.
///
/// Holds its own date formatters, so create one per scan rather than sharing a
/// global — Foundation formatters are not `Sendable`.
public struct TranscriptParser {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter
    private static let usageNeedle = Data(#""usage""#.utf8)
    private static let newline = UInt8(ascii: "\n")

    public init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    /// The last message seen and the counts already emitted for it. Hand it
    /// back as `after:` on the next read of the same file.
    public struct Continuation: Equatable, Sendable, Codable {
        public let id: String
        public let counts: TokenCounts
        public init(id: String, counts: TokenCounts) {
            self.id = id
            self.counts = counts
        }
    }

    public struct Parsed: Equatable, Sendable {
        public let records: [UsageRecord]
        public let lastMessage: Continuation?
    }

    /// Parses whole lines only. `data` must end at a line boundary.
    public func parse(_ data: Data) -> [UsageRecord] {
        parse(data, after: nil).records
    }

    /// One `UsageRecord` per *message*, not per line.
    ///
    /// Claude Code writes one assistant line per content block (text,
    /// tool_use, …), and every block of a message restates the same
    /// `message.id`. Top-level transcripts repeat the usage byte-for-byte;
    /// subagent transcripts carry a PROVISIONAL figure on the early lines and
    /// the real one on the last. Measured 2026-10-01 across 5,218 files:
    /// 72,989 such groups, every field non-decreasing across a group, and
    /// first-line-wins undercounting output tokens by 49%. The usage is
    /// cumulative for the message, so a message's figure is the maximum of
    /// each field across its lines — which is also right when they are equal.
    ///
    /// `after` is the last message the caller saw in this file and the counts
    /// already credited to it. A message's lines can straddle an incremental
    /// read boundary, and the continuation emits only the increase. A line
    /// with no id is never merged: no evidence of a repeat means count it.
    public func parse(_ data: Data, after continuation: Continuation?) -> Parsed {
        var records: [UsageRecord] = []
        let decoder = JSONDecoder()

        // The open group: its id, the per-field maximum seen so far, what has
        // already been credited for it (by an earlier read, or by the record
        // below), and where its record sits in `records` once one exists.
        var currentId = continuation?.id
        var currentMax = continuation?.counts ?? .zero
        var credited = continuation?.counts ?? .zero
        var currentIndex: Int?

        for line in data.split(separator: Self.newline, omittingEmptySubsequences: true) {
            let lineData = Data(line)
            // Cheap prefilter: most lines are tool results and never mention usage.
            guard lineData.range(of: Self.usageNeedle) != nil else { continue }
            guard let raw = try? decoder.decode(TranscriptLine.self, from: lineData) else { continue }
            guard raw.type == "assistant",
                  let usage = raw.message?.usage,
                  let stamp = raw.timestamp,
                  let timestamp = date(from: stamp) else { continue }

            let counts = TokenCounts(input: usage.inputTokens ?? 0,
                                     output: usage.outputTokens ?? 0,
                                     cacheWrite: usage.cacheCreationInputTokens ?? 0,
                                     cacheRead: usage.cacheReadInputTokens ?? 0)
            let model = raw.message?.model ?? ""

            if let id = raw.message?.id, id == currentId {
                let grown = Self.max(currentMax, counts)
                guard grown != currentMax else { continue }
                currentMax = grown
                let delta = Self.difference(grown, credited)
                credited = grown
                if let index = currentIndex {
                    records[index] = Self.record(records[index], adding: delta)
                } else {
                    records.append(Self.record(timestamp: timestamp, model: model, counts: delta))
                    currentIndex = records.count - 1
                }
                continue
            }

            currentId = raw.message?.id
            currentMax = counts
            credited = counts
            records.append(Self.record(timestamp: timestamp, model: model, counts: counts))
            currentIndex = currentId == nil ? nil : records.count - 1
        }
        return Parsed(records: records,
                      lastMessage: currentId.map { Continuation(id: $0, counts: currentMax) })
    }

    private static func max(_ a: TokenCounts, _ b: TokenCounts) -> TokenCounts {
        TokenCounts(input: Swift.max(a.input, b.input), output: Swift.max(a.output, b.output),
                    cacheWrite: Swift.max(a.cacheWrite, b.cacheWrite),
                    cacheRead: Swift.max(a.cacheRead, b.cacheRead))
    }

    /// `a − b`, never below zero per field; `a` is a per-field maximum that
    /// already includes `b`.
    private static func difference(_ a: TokenCounts, _ b: TokenCounts) -> TokenCounts {
        TokenCounts(input: Swift.max(0, a.input - b.input), output: Swift.max(0, a.output - b.output),
                    cacheWrite: Swift.max(0, a.cacheWrite - b.cacheWrite),
                    cacheRead: Swift.max(0, a.cacheRead - b.cacheRead))
    }

    private static func record(timestamp: Date, model: String, counts: TokenCounts) -> UsageRecord {
        UsageRecord(timestamp: timestamp, model: model,
                    inputTokens: counts.input, outputTokens: counts.output,
                    cacheWriteTokens: counts.cacheWrite, cacheReadTokens: counts.cacheRead)
    }

    private static func record(_ existing: UsageRecord, adding delta: TokenCounts) -> UsageRecord {
        UsageRecord(timestamp: existing.timestamp, model: existing.model,
                    inputTokens: existing.inputTokens + delta.input,
                    outputTokens: existing.outputTokens + delta.output,
                    cacheWriteTokens: existing.cacheWriteTokens + delta.cacheWrite,
                    cacheReadTokens: existing.cacheReadTokens + delta.cacheRead)
    }

    private func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}

/// Only the keys we need. `usage.iterations` is deliberately absent — it
/// restates the same totals per turn and would double-count.
private struct TranscriptLine: Decodable {
    let type: String?
    let timestamp: String?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }
}
