import Foundation

/// Substring match against a model id, in priority order.
public struct ModelMultiplier: Equatable, Sendable, Codable {
    public var match: String
    public var multiplier: Double

    public init(match: String, multiplier: Double) {
        self.match = match
        self.multiplier = multiplier
    }
}

/// How token classes and models convert into abstract "units".
///
/// The absolute scale is irrelevant — calibration divides it out. Only the
/// relative weighting matters, because that governs how the estimate responds
/// when the usage *mix* changes. Defaults are price-proportional with Sonnet
/// as the 1.0 baseline.
public struct Weights: Equatable, Sendable, Codable {
    public var input: Double
    public var cacheWrite: Double
    public var cacheRead: Double
    public var output: Double
    /// Ordered — first substring match wins, so the result is deterministic.
    /// A dictionary would iterate in an unspecified order.
    public var modelMultipliers: [ModelMultiplier]
    public var defaultMultiplier: Double

    public init(input: Double, cacheWrite: Double, cacheRead: Double, output: Double,
                modelMultipliers: [ModelMultiplier], defaultMultiplier: Double) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
        self.modelMultipliers = modelMultipliers
        self.defaultMultiplier = defaultMultiplier
    }

    /// Weights are relative, so a spread wider than this is already meaningless.
    /// The ceiling exists to keep `weight × tokens` finite: unbounded above, a
    /// number typed into the Settings text field overflows the product to
    /// infinity, and infinity then propagates into every downstream figure.
    public static let maximumWeight: Double = 1_000_000

    /// Clamps every weight into `0...maximumWeight`.
    ///
    /// Zero is legitimate — it means "ignore this token class" — but a negative
    /// weight makes units run backwards, so the estimate would *fall* as tokens
    /// are burned. Nothing in the Settings text fields prevents either extreme
    /// being typed, and `Double.nan` survives a plain `max(0,)` untouched.
    public func sanitized() -> Weights {
        func clamp(_ value: Double) -> Double {
            guard !value.isNaN else { return 0 }
            return min(max(0, value), Weights.maximumWeight)
        }
        return Weights(
            input: clamp(input),
            cacheWrite: clamp(cacheWrite),
            cacheRead: clamp(cacheRead),
            output: clamp(output),
            modelMultipliers: modelMultipliers.map {
                ModelMultiplier(match: $0.match, multiplier: clamp($0.multiplier))
            },
            defaultMultiplier: clamp(defaultMultiplier)
        )
    }

    /// Every `modelMultipliers` list `default` has ever shipped, oldest first.
    /// Multipliers are not editable in Settings, so a stored list equal to one
    /// of these is a default the user never chose, and `migrated()` replaces
    /// it. ⚠️ When `default` changes, append the outgoing list here, or every
    /// existing install keeps it forever: settings.json persists the whole list.
    static let retiredDefaultModelMultipliers: [[ModelMultiplier]] = [
        // Opus 4-era prices, shipped until 2026-09-22.
        [
            ModelMultiplier(match: "opus", multiplier: 5.0),
            ModelMultiplier(match: "sonnet", multiplier: 1.0),
            ModelMultiplier(match: "haiku", multiplier: 0.27),
        ],
    ]

    /// Replaces a retired default multiplier list with the current one, and
    /// leaves any other list alone — a hand-edited file is a choice.
    public func migrated() -> Weights {
        guard Weights.retiredDefaultModelMultipliers.contains(modelMultipliers) else { return self }
        var copy = self
        copy.modelMultipliers = Weights.default.modelMultipliers
        return copy
    }

    public static let `default` = Weights(
        input: 1.0,
        cacheWrite: 1.25,
        cacheRead: 0.1,
        output: 5.0,
        // List price relative to Sonnet 5 ($2 / $10 per 1M), checked 2026-09-22.
        // ⚠️ "opus-5-5" must precede "opus" — it is a substring match and the
        // first match wins. Fable 5 and 5.1 share a price, so one entry covers
        // both and the bare `fable` alias.
        modelMultipliers: [
            ModelMultiplier(match: "opus-5-5", multiplier: 2.0),
            ModelMultiplier(match: "opus", multiplier: 2.5),
            ModelMultiplier(match: "fable", multiplier: 5.0),
            ModelMultiplier(match: "sonnet", multiplier: 1.0),
            ModelMultiplier(match: "haiku", multiplier: 0.5),
        ],
        defaultMultiplier: 1.0
    )
}
