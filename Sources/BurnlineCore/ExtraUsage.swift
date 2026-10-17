import Foundation

extension UsageUtilization {

    /// Extra usage — the money meter that pays once a plan limit is hit —
    /// decoded from the `spend` and `extra_usage` siblings of `seven_day`.
    ///
    /// **Two blocks, two different facts, not two guards for one.** `spend`
    /// states its own units (`amount_minor` + `exponent` + `currency`) and
    /// carries `enabled`, `severity` and `disabled_reason`; `extra_usage` is
    /// the only place that says whether the USER switched it off
    /// (`user_disabled`), whether it was ever set up (`credits_ever_enabled`)
    /// and whether Anthropic says the limit was reached (`spend_limit_reached`),
    /// with its own `disabled_reason` as a fallback.
    /// `extra_usage.used_credits` has no stated unit and is never read.
    ///
    /// **Paused needs an explicit `spend.enabled == false`.** "Anthropic turned
    /// it off" is a claim, so a missing or non-boolean `enabled` means no row.
    ///
    /// Dated by the block's own `fetchedAt`, which moves only when `/usage`
    /// runs — so the figure can be days old, and the row says so.
    public struct ExtraUsage: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case active
            /// Anthropic switched it off while the user left it on.
            /// `reason` is display text, or nil for a code we don't recognise.
            case paused(reason: String?)
        }

        public let state: State
        public let usedMinor: Int
        public let limitMinor: Int
        public let exponent: Int
        public let currency: String
        /// Proven only: used at or past the limit, or Anthropic's own
        /// `spend_limit_reached`. Never inferred from `severity`.
        public let isLimitReached: Bool
        /// `severity` is anything but `normal`. Only `normal` has been
        /// observed, so this colours the row and claims nothing more.
        public let isSeverityRaised: Bool
        public let fetchedAt: Date

        /// Past one monthly cycle the figure describes a cycle that has ended.
        public static let maximumAge: TimeInterval = 31 * 86_400

        /// `$999,999.99` at exponent 2. `DisplayValue.whole`'s default ceiling
        /// is the 999 percent cap, which would render a $35 limit as $9.99.
        public static let amountCeilingMinor: Double = 99_999_999

        /// `350000`, 2 → `3,500`; `1240`, 2 → `12.40`; `12345`, 3 → `12.345`.
        ///
        /// Integer arithmetic, not `NumberFormatter`: an `en_US_POSIX` decimal
        /// formatter does not group, and the currency style prints `$ 9999.99`.
        /// Decimals are dropped only when every one of them is zero.
        static func amount(_ minor: Int, exponent requested: Int) -> String {
            // Never trap, like `DisplayValue`: 10^18 is the largest power a UInt
            // holds, and a negative exponent would make `0..<exponent` crash.
            let exponent = (0...18).contains(requested) ? requested : 0
            var scale: UInt = 1
            for _ in 0..<exponent { scale *= 10 }
            let magnitude = minor.magnitude
            let whole = grouped(magnitude / scale)
            let fraction = magnitude % scale
            let body: String
            if fraction == 0 {
                body = whole
            } else {
                let digits = String(fraction)
                body = whole + "." + String(repeating: "0", count: exponent - digits.count) + digits
            }
            return minor < 0 ? "-" + body : body
        }

        private static func grouped(_ value: UInt) -> String {
            let digits = Array(String(value))
            var out = ""
            for (index, digit) in digits.enumerated() {
                if index > 0 && (digits.count - index) % 3 == 0 { out.append(",") }
                out.append(digit)
            }
            return out
        }

        /// `$` on every USD amount; any other code only on the `labelled` one,
        /// so a row reads `EUR 12.40 of 35` rather than repeating the code.
        func money(_ minor: Int, labelled: Bool) -> String {
            let figure = Self.amount(minor, exponent: exponent)
            if currency == "USD" { return "$" + figure }
            return labelled ? "\(currency) \(figure)" : figure
        }
    }
}

extension UsageUtilization.ExtraUsage {

    /// From the decoded block plus the outer `fetchedAt` (seconds). Nil unless
    /// every fact the row needs is present — unknown units mean no figure.
    static func resolve(spend: RawSpend?, extra: RawExtraUsage?,
                        fetchedAt: TimeInterval) -> Self? {
        guard let spend, fetchedAt > 0 else { return nil }

        // Visible while it can be spent, or while the user left it on and
        // Anthropic switched it off. `credits_ever_enabled` keeps the paused
        // state away from users who never set extra usage up.
        let enabled = spend.enabled == true
        let leftOnByUser = spend.enabled == false
            && extra?.userDisabled == false && extra?.creditsEverEnabled == true
        guard enabled || leftOnByUser else { return nil }

        guard let usedRaw = spend.used?.amountMinor,
              let limitRaw = spend.limit?.amountMinor,
              let exponent = spend.limit?.exponent, (0...4).contains(exponent)
        else { return nil }
        // Two stated units that disagree describe no single unit.
        if let usedExponent = spend.used?.exponent, usedExponent != exponent { return nil }
        // Through `DisplayValue`, which saturates — every figure here is JSON on disk.
        let used = DisplayValue.whole(usedRaw, ceiling: amountCeilingMinor)
        let limit = DisplayValue.whole(limitRaw, ceiling: amountCeilingMinor)
        guard limit >= 0 else { return nil }

        let state: State = enabled
            ? .active
            // `??` picks the spend code first; an unknown spend code therefore
            // blocks the fallback on purpose — an unknown code is never echoed.
            : .paused(reason: (spend.disabledReason ?? extra?.disabledReason).flatMap(reasonText))

        return Self(state: state,
                    usedMinor: used,
                    limitMinor: limit,
                    exponent: exponent,
                    currency: spend.used?.currency ?? spend.limit?.currency ?? "USD",
                    isLimitReached: (limit > 0 && used >= limit) || extra?.spendLimitReached == true,
                    isSeverityRaised: (spend.severity ?? "normal") != "normal",
                    fetchedAt: Date(timeIntervalSince1970: fetchedAt))
    }

    /// Known codes only. An unknown one is never shown raw.
    static func reasonText(_ code: String) -> String? {
        code == "out_of_credits" ? "out of credits" : nil
    }

    // MARK: - Raw shapes, every property decoded independently

    struct RawMoney: Decodable {
        var amountMinor: Double?
        var currency: String?
        var exponent: Int?

        enum CodingKeys: String, CodingKey {
            case amountMinor = "amount_minor", currency, exponent
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            amountMinor = (try? c.decodeIfPresent(Double.self, forKey: .amountMinor)) ?? nil
            currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? nil
            exponent = (try? c.decodeIfPresent(Int.self, forKey: .exponent)) ?? nil
        }
    }

    struct RawSpend: Decodable {
        var used: RawMoney?
        var limit: RawMoney?
        var severity: String?
        var enabled: Bool?
        var disabledReason: String?

        enum CodingKeys: String, CodingKey {
            case used, limit, severity, enabled
            case disabledReason = "disabled_reason"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            used = (try? c.decodeIfPresent(RawMoney.self, forKey: .used)) ?? nil
            limit = (try? c.decodeIfPresent(RawMoney.self, forKey: .limit)) ?? nil
            severity = (try? c.decodeIfPresent(String.self, forKey: .severity)) ?? nil
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
            disabledReason = (try? c.decodeIfPresent(String.self, forKey: .disabledReason)) ?? nil
        }
    }

    struct RawExtraUsage: Decodable {
        var userDisabled: Bool?
        var creditsEverEnabled: Bool?
        var disabledReason: String?
        var spendLimitReached: Bool?

        enum CodingKeys: String, CodingKey {
            case userDisabled = "user_disabled"
            case creditsEverEnabled = "credits_ever_enabled"
            case disabledReason = "disabled_reason"
            case spendLimitReached = "spend_limit_reached"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            userDisabled = (try? c.decodeIfPresent(Bool.self, forKey: .userDisabled)) ?? nil
            creditsEverEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .creditsEverEnabled)) ?? nil
            disabledReason = (try? c.decodeIfPresent(String.self, forKey: .disabledReason)) ?? nil
            spendLimitReached = (try? c.decodeIfPresent(Bool.self, forKey: .spendLimitReached)) ?? nil
        }
    }
}
