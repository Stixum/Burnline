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

        // Each field is decoded independently: a wrong-typed `used_percentage`
        // must not cost us `resets_at`, or vice versa. See the type-level doc
        // on `StatuslinePayload` for why this can't just be `Optional`.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedPercentage = try? c.decodeIfPresent(Double.self, forKey: .usedPercentage)
            resetsAt = try? c.decodeIfPresent(TimeInterval.self, forKey: .resetsAt)
        }
    }

    public struct RateLimits: Sendable, Decodable {
        public var sevenDay: Limit?
        public var fiveHour: Limit?
        enum CodingKeys: String, CodingKey {
            case sevenDay = "seven_day"
            case fiveHour = "five_hour"
        }

        // A malformed `five_hour` (wrong type, not even an object) must not
        // cost us `seven_day`, and vice versa.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sevenDay = try? c.decodeIfPresent(Limit.self, forKey: .sevenDay)
            fiveHour = try? c.decodeIfPresent(Limit.self, forKey: .fiveHour)
        }
    }

    public var model: Model?
    public var workspace: Workspace?
    public var contextWindow: ContextWindow?
    public var cost: Cost?
    public var rateLimits: RateLimits?
    /// Identifies the session whose cached `rate_limits` this is, which is what
    /// lets the app date the reading exactly. Documented, but never yet observed
    /// at runtime — everything downstream treats it as optional.
    public var sessionId: String?
    public var transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case model
        case workspace
        case contextWindow = "context_window"
        case cost
        case rateLimits = "rate_limits"
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
    }

    // Each top-level property is decoded independently, exactly like the jq
    // filter this replaced extracted each path on its own: a cosmetic field
    // (say, `model.display_name`) arriving with an unexpected TYPE must not
    // cost us `rate_limits`. Plain `Optional` properties only protect against
    // a field that DISAPPEARS — this protects against one that changes shape.
    //
    // `try?` on `decodeIfPresent` flattens `String??` down to `String?`:
    // "missing key", "present but null", and "present but wrong type" all
    // become `nil` here, which is exactly the semantics we want.
    //
    // A top-level value that isn't a keyed container (a JSON array, string,
    // or bare number) still throws out of `container(keyedBy:)`, so
    // `main.swift` still falls back to printing "burnline".
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try? c.decodeIfPresent(Model.self, forKey: .model)
        workspace = try? c.decodeIfPresent(Workspace.self, forKey: .workspace)
        contextWindow = try? c.decodeIfPresent(ContextWindow.self, forKey: .contextWindow)
        cost = try? c.decodeIfPresent(Cost.self, forKey: .cost)
        rateLimits = try? c.decodeIfPresent(RateLimits.self, forKey: .rateLimits)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
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

        // `capturedAt` is "now", which is only the truth for a payload that is
        // actually fresh. An idle session republishes the block it cached hours
        // ago, and stamping that with `Date()` is what made a three-hour-old
        // reading render as thirty seconds old.
        return RateLimitCapture(
            version: RateLimitCapture.currentVersion,
            capturedAt: capturedAt,
            sevenDay: .init(usedPercent: usedPercent, resetsAt: resetsAt),
            fiveHour: fiveHourReading,
            // Recorded, not acted on: dating is file I/O and belongs in the app,
            // not in a helper that runs every 30s inside the user's prompt.
            sessionId: sessionId,
            transcriptPath: transcriptPath
        ).correctedForRepublishing()
    }
}
