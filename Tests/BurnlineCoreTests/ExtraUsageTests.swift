import Testing
import Foundation
@testable import BurnlineCore

// Extra usage: the plan's second money meter, which pays once a plan limit is
// hit. Read from `spend` (amounts, enabled, severity) and `extra_usage`
// (whether the USER turned it off) in the `cachedUsageUtilization` block.

@Test func extraUsageAmountsGroupThousandsAndKeepTheExponentsDecimals() {
    typealias E = UsageUtilization.ExtraUsage
    #expect(E.amount(350_000, exponent: 2) == "3,500")
    #expect(E.amount(1_240, exponent: 2) == "12.40")
    #expect(E.amount(999_999, exponent: 2) == "9,999.99")
    #expect(E.amount(12_345, exponent: 3) == "12.345")
    #expect(E.amount(35, exponent: 0) == "35")
    #expect(E.amount(0, exponent: 2) == "0")
    #expect(E.amount(105, exponent: 2) == "1.05")
    #expect(E.amount(99_999_999, exponent: 2) == "999,999.99")
}

private func extraUsage(used: Int = 1_240, limit: Int = 3_500, exponent: Int = 2,
                        currency: String = "USD") -> UsageUtilization.ExtraUsage {
    .init(state: .active, usedMinor: used, limitMinor: limit, exponent: exponent,
          currency: currency, isLimitReached: false, isSeverityRaised: false,
          fetchedAt: Date())
}

@Test func extraUsageMoneyPrefixesDollarsOnEveryAmountAndOtherCodesOnTheFirstOnly() {
    let usd = extraUsage()
    #expect(usd.money(1_240, labelled: true) == "$12.40")
    #expect(usd.money(3_500, labelled: false) == "$35")
    let eur = extraUsage(currency: "EUR")
    #expect(eur.money(1_240, labelled: true) == "EUR 12.40")
    #expect(eur.money(3_500, labelled: false) == "35")
}

/// Shaped from the real block observed 2026-10-17. Only the fields this
/// feature reads, plus `seven_day` to prove a bad `spend` never costs it.
private func extraUsageConfig(spend: String?, extra: String? = nil,
                              fetchedAtMs: String = "1792268174067") -> String {
    var siblings = ""
    if let spend { siblings += ",\"spend\":\(spend)" }
    if let extra { siblings += ",\"extra_usage\":\(extra)" }
    return """
    {"fetchedAtMs":\(fetchedAtMs),"utilization":{
      "seven_day":{"utilization":9,"resets_at":"2026-10-22T07:00:00.000000+00:00"}\(siblings)}}
    """
}

private func spendBlock(used: String = "1240", limit: String = "3500", exponent: String = "2",
                        currency: String = "\"USD\"", severity: String = "\"normal\"",
                        enabled: String = "true", reason: String = "null") -> String {
    """
    {"used":{"amount_minor":\(used),"currency":\(currency),"exponent":\(exponent)},
     "limit":{"amount_minor":\(limit),"currency":\(currency),"exponent":\(exponent)},
     "percent":35,"severity":\(severity),"enabled":\(enabled),"disabled_reason":\(reason)}
    """
}

private func extraBlock(userDisabled: String = "false", everEnabled: String = "true",
                        reason: String = "null", limitReached: String = "false") -> String {
    """
    {"user_disabled":\(userDisabled),"credits_ever_enabled":\(everEnabled),
     "disabled_reason":\(reason),"spend_limit_reached":\(limitReached)}
    """
}

private func decodedExtraUsage(_ json: String) throws -> UsageUtilization {
    try JSONDecoder().decode(UsageUtilization.self, from: Data(json.utf8))
}

@Test func anEnabledSpendBlockDecodesToActiveExtraUsage() throws {
    let u = try decodedExtraUsage(extraUsageConfig(spend: spendBlock(), extra: extraBlock()))
    let extra = try #require(u.extraUsage)
    #expect(extra.state == .active)
    #expect(extra.usedMinor == 1_240)
    #expect(extra.limitMinor == 3_500)   // not clamped to the 999 percent ceiling
    #expect(extra.exponent == 2)
    #expect(extra.currency == "USD")
    #expect(!extra.isLimitReached)
    #expect(!extra.isSeverityRaised)
    #expect(extra.fetchedAt == Date(timeIntervalSince1970: 1_792_268_174.067))
}

/// The state on the real account 2026-10-17: left on by the user, switched off
/// by Anthropic.
@Test func extraUsageTheUserLeftOnButAnthropicSwitchedOffIsPausedOutOfCredits() throws {
    let u = try decodedExtraUsage(extraUsageConfig(
        spend: spendBlock(used: "0", enabled: "false", reason: "\"out_of_credits\""),
        extra: extraBlock(reason: "\"out_of_credits\"")))
    #expect(u.extraUsage?.state == .paused(reason: "out of credits"))
}

/// An unrecognised code is never echoed raw.
@Test func extraUsagePausedForAnUnknownReasonCarriesNoReason() throws {
    let u = try decodedExtraUsage(extraUsageConfig(
        spend: spendBlock(enabled: "false", reason: "\"policy_hold_v2\""), extra: extraBlock()))
    #expect(u.extraUsage?.state == .paused(reason: nil))
}

@Test func extraUsageFallsBackToTheExtraUsageBlocksReason() throws {
    let u = try decodedExtraUsage(extraUsageConfig(
        spend: spendBlock(enabled: "false"), extra: extraBlock(reason: "\"out_of_credits\"")))
    #expect(u.extraUsage?.state == .paused(reason: "out of credits"))
}

@Test func extraUsageTheUserTurnedOffIsAbsent() throws {
    let u = try decodedExtraUsage(extraUsageConfig(
        spend: spendBlock(enabled: "false"), extra: extraBlock(userDisabled: "true")))
    #expect(u.extraUsage == nil)
}

/// Never set up: no row, or every user who never touched it would see "paused".
@Test func extraUsageNeverSetUpIsAbsent() throws {
    let u = try decodedExtraUsage(extraUsageConfig(
        spend: spendBlock(enabled: "false"), extra: extraBlock(everEnabled: "false")))
    #expect(u.extraUsage == nil)
}

@Test func extraUsageWithoutALimitIsAbsent() throws {
    let spend = #"{"used":{"amount_minor":0,"currency":"USD","exponent":2},"enabled":true}"#
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spend)).extraUsage == nil)
}

/// Per-property leniency: the bad field costs this block, never `seven_day`.
@Test func aMalformedExtraUsageAmountCostsOnlyTheExtraUsage() throws {
    let u = try decodedExtraUsage(extraUsageConfig(spend: spendBlock(used: "\"12\"")))
    #expect(u.extraUsage == nil)
    #expect(u.sevenDay?.percent == 9)
}

@Test func extraUsageWithAMissingOrOutOfRangeExponentIsAbsent() throws {
    let missing = #"""
    {"used":{"amount_minor":1240,"currency":"USD"},"limit":{"amount_minor":3500,"currency":"USD"},"enabled":true}
    """#
    #expect(try decodedExtraUsage(extraUsageConfig(spend: missing)).extraUsage == nil)
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spendBlock(exponent: "5"))).extraUsage == nil)
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spendBlock(exponent: "0"))).extraUsage?.exponent == 0)
}

@Test func extraUsageWithANegativeLimitIsAbsent() throws {
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spendBlock(limit: "-1"))).extraUsage == nil)
}

/// No fetch timestamp means a 1970 "as of" — worse than no row.
@Test func extraUsageWithoutAFetchTimeIsAbsent() throws {
    let noFetch = """
    {"utilization":{"spend":\(spendBlock())}}
    """
    #expect(try decodedExtraUsage(noFetch).extraUsage == nil)
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spendBlock(), fetchedAtMs: "0")).extraUsage == nil)
}

@Test func extraUsageWithAMissingSeverityIsNormal() throws {
    let spend = #"""
    {"used":{"amount_minor":1240,"currency":"USD","exponent":2},"limit":{"amount_minor":3500,"currency":"USD","exponent":2},"enabled":true}
    """#
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spend)).extraUsage?.isSeverityRaised == false)
}

/// A raised severity is not proof the limit was reached.
@Test func extraUsageWithARaisedSeverityIsNotAtLimit() throws {
    let extra = try #require(try decodedExtraUsage(
        extraUsageConfig(spend: spendBlock(severity: "\"warning\""))).extraUsage)
    #expect(extra.isSeverityRaised)
    #expect(!extra.isLimitReached)
}

@Test func extraUsageIsAtLimitWhenUsedMeetsLimitOrAnthropicSaysSo() throws {
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spendBlock(used: "3500")))
        .extraUsage?.isLimitReached == true)
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spendBlock(),
                                                   extra: extraBlock(limitReached: "true")))
        .extraUsage?.isLimitReached == true)
    // A zero limit with zero used is not "reached".
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spendBlock(used: "0", limit: "0")))
        .extraUsage?.isLimitReached == false)
}

@Test func extraUsageCurrencyComesFromTheBlockAndDefaultsToDollars() throws {
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spendBlock(currency: "\"EUR\"")))
        .extraUsage?.currency == "EUR")
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spendBlock(currency: "null")))
        .extraUsage?.currency == "USD")
}

// MARK: - Review follow-ups

/// `Block` decodes `spend` and `extra_usage` with `try?`; if it lost that, one
/// malformed sibling would cost `seven_day` and the whole capture.
@Test func aGarbageSpendBlockCostsOnlyTheExtraUsageNeverSevenDay() throws {
    let u = try decodedExtraUsage(extraUsageConfig(spend: "\"garbage\""))
    #expect(u.extraUsage == nil)
    #expect(u.sevenDay?.percent == 9)
}

@Test func aGarbageExtraUsageBlockCostsOnlyTheExtraUsageNeverSevenDay() throws {
    let u = try decodedExtraUsage(extraUsageConfig(spend: spendBlock(), extra: "[1]"))
    #expect(u.sevenDay?.percent == 9)
    // The valid `spend` still resolves: only the bad sibling is lost.
    #expect(u.extraUsage?.state == .active)
}

@Test func extraUsageWithANegativeExponentIsAbsent() throws {
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spendBlock(exponent: "-1"))).extraUsage == nil)
}

/// `amount` must never trap, whatever the caller passes (like `DisplayValue`).
@Test func extraUsageAmountNeverTrapsOnAnOutOfRangeExponent() {
    typealias E = UsageUtilization.ExtraUsage
    #expect(E.amount(1_240, exponent: -1) == "1,240")
    #expect(E.amount(1_240, exponent: 19) == "1,240")
}

/// Paused is a claim ("Anthropic turned it off") that needs the explicit `false`.
@Test func extraUsageWithoutAnEnabledFlagIsAbsentEvenIfTheUserLeftItOn() throws {
    let spend = #"""
    {"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":{"amount_minor":3500,"currency":"USD","exponent":2}}
    """#
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spend, extra: extraBlock())).extraUsage == nil)
}

@Test func extraUsageWithANonBooleanEnabledFlagIsAbsent() throws {
    let u = try decodedExtraUsage(extraUsageConfig(
        spend: spendBlock(enabled: "\"true\""), extra: extraBlock()))
    #expect(u.extraUsage == nil)
}

/// Two exponents that disagree describe no single unit.
@Test func extraUsageWhoseUsedAndLimitExponentsDisagreeIsAbsent() throws {
    let spend = #"""
    {"used":{"amount_minor":1240,"currency":"USD","exponent":3},"limit":{"amount_minor":3500,"currency":"USD","exponent":2},"enabled":true}
    """#
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spend)).extraUsage == nil)
    // A used block that states no exponent is not a disagreement.
    let bare = #"""
    {"used":{"amount_minor":1240,"currency":"USD"},"limit":{"amount_minor":3500,"currency":"USD","exponent":2},"enabled":true}
    """#
    #expect(try decodedExtraUsage(extraUsageConfig(spend: bare)).extraUsage?.exponent == 2)
}

/// An unknown `spend` reason intentionally blocks the fallback: never echo it.
@Test func extraUsageSpendsReasonWinsOverTheExtraUsageBlocksReason() throws {
    let u = try decodedExtraUsage(extraUsageConfig(
        spend: spendBlock(enabled: "false", reason: "\"out_of_credits\""),
        extra: extraBlock(reason: "\"x\"")))
    #expect(u.extraUsage?.state == .paused(reason: "out of credits"))
}

/// Pins the other half of the rule above: a spend code we do not recognise is
/// not a missing one, so the `extra_usage` code must not stand in for it.
@Test func anUnknownSpendReasonBlocksTheFallbackToTheExtraUsageBlocksReason() throws {
    let u = try decodedExtraUsage(extraUsageConfig(
        spend: spendBlock(enabled: "false", reason: "\"policy_hold_v2\""),
        extra: extraBlock(reason: "\"out_of_credits\"")))
    #expect(u.extraUsage?.state == .paused(reason: nil))
}

@Test func extraUsageCurrencyComesFromUsedBeforeLimit() throws {
    let spend = #"""
    {"used":{"amount_minor":1240,"currency":"EUR","exponent":2},"limit":{"amount_minor":3500,"currency":"GBP","exponent":2},"enabled":true}
    """#
    #expect(try decodedExtraUsage(extraUsageConfig(spend: spend)).extraUsage?.currency == "EUR")
}

/// `enabled: true` is the whole truth for "can be spent"; `user_disabled` only
/// matters once Anthropic has switched it off.
@Test func extraUsageEnabledWinsOverUserDisabled() throws {
    let u = try decodedExtraUsage(extraUsageConfig(
        spend: spendBlock(enabled: "true"), extra: extraBlock(userDisabled: "true")))
    #expect(u.extraUsage?.state == .active)
}
