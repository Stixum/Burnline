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

    /// Parses whole lines only. `data` must end at a line boundary.
    public func parse(_ data: Data) -> [UsageRecord] {
        var records: [UsageRecord] = []
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

            records.append(UsageRecord(
                timestamp: timestamp,
                model: raw.message?.model ?? "",
                inputTokens: usage.inputTokens ?? 0,
                outputTokens: usage.outputTokens ?? 0,
                cacheWriteTokens: usage.cacheCreationInputTokens ?? 0,
                cacheReadTokens: usage.cacheReadInputTokens ?? 0
            ))
        }
        return records
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
