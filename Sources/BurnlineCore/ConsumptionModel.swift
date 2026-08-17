import Foundation

/// Pure: token counts → weighted units.
public enum ConsumptionModel {

    public static func multiplier(for model: String, weights: Weights) -> Double {
        let lowered = model.lowercased()
        for candidate in weights.modelMultipliers where lowered.contains(candidate.match.lowercased()) {
            return candidate.multiplier
        }
        return weights.defaultMultiplier
    }

    public static func units(for record: UsageRecord, weights: Weights) -> Double {
        let base = Double(record.inputTokens) * weights.input
            + Double(record.cacheWriteTokens) * weights.cacheWrite
            + Double(record.cacheReadTokens) * weights.cacheRead
            + Double(record.outputTokens) * weights.output
        return base * multiplier(for: record.model, weights: weights)
    }

    public static func totalUnits(for records: [UsageRecord], weights: Weights) -> Double {
        records.reduce(0) { $0 + units(for: $1, weights: weights) }
    }

    /// Model id → multiplier, resolved once.
    ///
    /// `Weights.modelMultipliers` is an ordered array matched by substring, on
    /// purpose, so matching is deterministic. Doing that lookup per cell — three
    /// times per rebuild — reopens a performance question that was measured and
    /// closed. Resolve against the exact model strings present, then multiply.
    public struct ResolvedMultipliers: Sendable {
        private let table: [String: Double]
        private let fallback: Double

        public init(models: some Sequence<String>, weights: Weights) {
            var table: [String: Double] = [:]
            for model in models where table[model] == nil {
                table[model] = ConsumptionModel.multiplier(for: model, weights: weights)
            }
            self.table = table
            self.fallback = weights.defaultMultiplier
        }

        public subscript(model: String) -> Double { table[model] ?? fallback }
    }

    public static func units(for counts: TokenCounts, model: String, weights: Weights) -> Double {
        units(for: counts, multiplier: multiplier(for: model, weights: weights), weights: weights)
    }

    public static func units(for counts: TokenCounts, multiplier: Double, weights: Weights) -> Double {
        let base = Double(counts.input) * weights.input
            + Double(counts.cacheWrite) * weights.cacheWrite
            + Double(counts.cacheRead) * weights.cacheRead
            + Double(counts.output) * weights.output
        return base * multiplier
    }
}
