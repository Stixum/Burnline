import Foundation

/// The session JSON Claude Code pipes to a statusline command on stdin.
///
/// Every field is optional by design. This payload is not a stable contract —
/// a field that disappears in a future Claude Code release must cost us one
/// element of the status line, never the whole decode. See
/// <https://code.claude.com/docs/en/statusline>.
public struct StatuslinePayload: Sendable, Decodable {
    public struct Model: Sendable, Decodable {
        public var displayName: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }

    public struct Workspace: Sendable, Decodable {
        public var currentDir: String?
        enum CodingKeys: String, CodingKey { case currentDir = "current_dir" }
    }

    public struct ContextWindow: Sendable, Decodable {
        public var usedPercentage: Double?
        enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage" }
    }

    public struct Cost: Sendable, Decodable {
        public var totalCostUsd: Double?
        enum CodingKeys: String, CodingKey { case totalCostUsd = "total_cost_usd" }
    }

    public struct Limit: Sendable, Decodable {
        public var usedPercentage: Double?
        public var resetsAt: TimeInterval?
        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    public struct RateLimits: Sendable, Decodable {
        public var sevenDay: Limit?
        public var fiveHour: Limit?
        enum CodingKeys: String, CodingKey {
            case sevenDay = "seven_day"
            case fiveHour = "five_hour"
        }
    }

    public var model: Model?
    public var workspace: Workspace?
    public var contextWindow: ContextWindow?
    public var cost: Cost?
    public var rateLimits: RateLimits?

    enum CodingKeys: String, CodingKey {
        case model
        case workspace
        case contextWindow = "context_window"
        case cost
        case rateLimits = "rate_limits"
    }

    /// The capture to persist, or `nil` when this payload carries nothing worth
    /// recording.
    ///
    /// `rate_limits` is absent on non-Pro/Max plans and before a session's first
    /// API response — that is the normal case, not an error.
    ///
    /// A seven-day percentage without `resets_at` is rejected outright: the
    /// reading's validity is judged against its window boundary, and a
    /// percentage that can never be expired would be treated as current
    /// forever.
    public func capture(capturedAt: TimeInterval) -> RateLimitCapture? {
        guard let sevenDay = rateLimits?.sevenDay,
              let usedPercent = sevenDay.usedPercentage,
              let resetsAt = sevenDay.resetsAt
        else { return nil }

        var fiveHourReading: RateLimitCapture.Reading?
        if let fiveHour = rateLimits?.fiveHour,
           let percent = fiveHour.usedPercentage,
           let resets = fiveHour.resetsAt {
            fiveHourReading = .init(usedPercent: percent, resetsAt: resets)
        }

        return RateLimitCapture(
            version: RateLimitCapture.currentVersion,
            capturedAt: capturedAt,
            sevenDay: .init(usedPercent: usedPercent, resetsAt: resetsAt),
            fiveHour: fiveHourReading
        )
    }
}
