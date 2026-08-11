import Foundation

/// Token counts from a single assistant message in a Claude Code transcript.
public struct UsageRecord: Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheWriteTokens: Int
    public let cacheReadTokens: Int

    public init(timestamp: Date, model: String, inputTokens: Int, outputTokens: Int,
                cacheWriteTokens: Int, cacheReadTokens: Int) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
    }
}
