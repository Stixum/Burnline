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
}
