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

    public struct Parsed: Equatable, Sendable {
        public let records: [UsageRecord]
        /// The `message.id` of the last usage-bearing line, carried or not.
        /// Hand it back as `after:` on the next read of the same file.
        public let lastMessageId: String?
    }

    /// Parses whole lines only. `data` must end at a line boundary.
    public func parse(_ data: Data) -> [UsageRecord] {
        parse(data, after: nil).records
    }

    /// One `UsageRecord` per *message*, not per line.
    ///
    /// Claude Code writes one assistant line per content block (text,
    /// tool_use, …), and every block of a message restates the same
    /// `message.id` with byte-identical `usage`. Measured on 40 real
    /// transcripts (2026-10-01): 56% of usage-bearing lines were repeats, 67%
    /// of output tokens. The usage describes the whole message, so it counts
    /// once — the first line carries it and the rest are skipped.
    ///
    /// `after` is the id the caller last saw in this file. A message's blocks
    /// can straddle an incremental read boundary, and without it the
    /// continuation would count the message a second time. A line with no id
    /// is never collapsed: no evidence of a repeat means count it.
    public func parse(_ data: Data, after lastMessageId: String?) -> Parsed {
        var records: [UsageRecord] = []
        var lastId = lastMessageId
        let decoder = JSONDecoder()

        for line in data.split(separator: Self.newline, omittingEmptySubsequences: true) {
            let lineData = Data(line)
            // Cheap prefilter: most lines are tool results and never mention usage.
            guard lineData.range(of: Self.usageNeedle) != nil else { continue }
            guard let raw = try? decoder.decode(TranscriptLine.self, from: lineData) else { continue }
            guard raw.type == "assistant",
                  let usage = raw.message?.usage,
                  let stamp = raw.timestamp,
                  let timestamp = date(from: stamp) else { continue }

            if let id = raw.message?.id {
                if id == lastId { continue }
                lastId = id
            }

            records.append(UsageRecord(
                timestamp: timestamp,
                model: raw.message?.model ?? "",
                inputTokens: usage.inputTokens ?? 0,
                outputTokens: usage.outputTokens ?? 0,
                cacheWriteTokens: usage.cacheCreationInputTokens ?? 0,
                cacheReadTokens: usage.cacheReadInputTokens ?? 0
            ))
        }
        return Parsed(records: records, lastMessageId: lastId)
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
