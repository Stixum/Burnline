import Foundation

/// The monthly Claude Platform credit a subscription plan includes.
///
/// Anthropic grants Max subscribers API credits each billing cycle, in a
/// Console organization the user links from claude.ai. **Burnline cannot see
/// that organization**, so this states eligibility and points at the Console —
/// it never claims a balance. The credits cover the API and the Agent SDK, not
/// interactive Claude Code, and do not change any limit this app measures.
///
/// ⚠️ **The amounts are Anthropic's prices, hardcoded.** Source:
/// https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers,
/// checked 2026-10-17. A price change means editing this table.
///
/// Only the two Max tiers resolve. `default_claude_max_20x` is observed on a real
/// account; `default_claude_max_5x` is inferred. Team is deliberately absent —
/// its pooled credit depends on seat counts — and every unknown tier is nil, so a
/// wrong guess shows no line rather than a wrong claim.
public struct PlanCredit: Equatable, Sendable {
    public let planName: String
    public let monthlyDollars: Int

    public init?(rateLimitTier: String?) {
        switch rateLimitTier {
        case "default_claude_max_20x":
            planName = "Max 20x"
            monthlyDollars = 200
        case "default_claude_max_5x":
            planName = "Max 5x"
            monthlyDollars = 100
        default:
            return nil
        }
    }

    /// The Settings line, assembled here because `Sources/Burnline` has no tests.
    public var settingsLine: String {
        "\(planName) · includes $\(monthlyDollars)/mo API credits for the Claude Platform, not Claude Code."
    }

    public static let consoleBillingURL = URL(string: "https://platform.claude.com/settings/billing")!
}
