import Testing
import Foundation
@testable import BurnlineCore

private func record(model: String, input: Int = 0, output: Int = 0,
                    cacheWrite: Int = 0, cacheRead: Int = 0) -> UsageRecord {
    UsageRecord(timestamp: Date(timeIntervalSince1970: 0), model: model,
                inputTokens: input, outputTokens: output,
                cacheWriteTokens: cacheWrite, cacheReadTokens: cacheRead)
}

@Test func weightsTokenClassesIndependently() {
    let weights = Weights.default
    let sonnet = record(model: "claude-sonnet-5", input: 100, output: 10,
                        cacheWrite: 40, cacheRead: 1000)
    // 100*1.0 + 40*1.25 + 1000*0.1 + 10*5.0 = 100 + 50 + 100 + 50 = 300, x1.0
    #expect(abs(ConsumptionModel.units(for: sonnet, weights: weights) - 300) < 1e-9)
}

@Test func opusCostsFiveTimesSonnet() {
    let weights = Weights.default
    let sonnet = record(model: "claude-sonnet-5", output: 100)
    let opus = record(model: "claude-opus-5", output: 100)
    let ratio = ConsumptionModel.units(for: opus, weights: weights)
        / ConsumptionModel.units(for: sonnet, weights: weights)
    #expect(abs(ratio - 5.0) < 1e-9)
}

@Test func unknownModelFallsBackToDefaultMultiplier() {
    let weights = Weights.default
    let unknown = record(model: "some-future-model", output: 100)
    // 100 * 5.0 * 1.0
    #expect(abs(ConsumptionModel.units(for: unknown, weights: weights) - 500) < 1e-9)
}

@Test func modelMatchingIsCaseInsensitive() {
    let weights = Weights.default
    let shouty = record(model: "CLAUDE-OPUS-5", output: 100)
    #expect(abs(ConsumptionModel.units(for: shouty, weights: weights) - 2500) < 1e-9)
}

@Test func modelMatchingIsDeterministicallyOrdered() {
    // First match in the ordered list wins, every time.
    var weights = Weights.default
    weights.modelMultipliers = [
        ModelMultiplier(match: "opus", multiplier: 2),
        ModelMultiplier(match: "claude", multiplier: 99),
    ]
    let subject = record(model: "claude-opus-5", output: 1)
    for _ in 0..<50 {
        #expect(ConsumptionModel.units(for: subject, weights: weights) == 10) // 1*5.0*2
    }
}

@Test func emptyRecordCostsNothing() {
    #expect(ConsumptionModel.units(for: record(model: "claude-opus-5"), weights: .default) == 0)
}

@Test func totalSumsRecords() {
    let records = [record(model: "claude-sonnet-5", output: 10),
                   record(model: "claude-sonnet-5", output: 20)]
    #expect(abs(ConsumptionModel.totalUnits(for: records, weights: .default) - 150) < 1e-9)
}
