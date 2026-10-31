import Testing
import Foundation
@testable import BurnlineCore

// Monthly API credits for Max and Ultra (Anthropic, from 2026-10). Credits live
// in a Console org Burnline cannot see, so this states eligibility only.

/// Anthropic renamed Max 20x to Ultra on 2026-10-30; the tier string did not change.
@Test func planCreditForUltraIsTwoHundredDollars() throws {
    let credit = try #require(PlanCredit(rateLimitTier: "default_claude_max_20x"))
    #expect(credit.planName == "Ultra")
    #expect(credit.monthlyDollars == 200)
    #expect(credit.settingsLine
            == "Ultra · includes $200/mo API credits for the Claude Platform, not Claude Code.")
}

/// Inferred, never observed. Pinned so a change to it is deliberate. Max 5x
/// became plain Max on 2026-10-30.
@Test func planCreditForMaxIsOneHundredDollars() throws {
    let credit = try #require(PlanCredit(rateLimitTier: "default_claude_max_5x"))
    #expect(credit.planName == "Max")
    #expect(credit.monthlyDollars == 100)
}

/// Team credit depends on seat counts this file never carries; Pro, Free and
/// Enterprise get none. Every unknown tier fails closed — no line beats a wrong one.
@Test func planCreditIsAbsentForEveryOtherTier() {
    for tier in ["default_claude_team", "default_claude_pro", "default_claude_max_20x_v2",
                 "DEFAULT_CLAUDE_MAX_20X", ""] {
        #expect(PlanCredit(rateLimitTier: tier) == nil, "\(tier)")
    }
    #expect(PlanCredit(rateLimitTier: nil) == nil)
}

@Test func planCreditLinksToTheConsoleBillingPage() {
    #expect(PlanCredit.consoleBillingURL.absoluteString
            == "https://platform.claude.com/settings/billing")
}
