import Testing
import Foundation
@testable import BurnlineCore

private let anchorDate = Date(timeIntervalSince1970: 1_800_000_000)

/// Cells hold raw tokens, so a fixture has to name a token class and a model.
/// Input tokens on a sonnet model are the identity mapping under
/// `Weights.default` — `input: 1.0` × sonnet `1.0` — so `units` in and weighted
/// units out are the same number, and the sums below stay readable.
private func state(at date: Date, units: Int) -> FileState {
    state(at: date, counts: TokenCounts(input: units))
}

private func state(at date: Date, counts: TokenCounts) -> FileState {
    FileState(modifiedAt: date, size: 100, offset: 100,
              cells: [String(Bucket.key(for: date)): ["claude-sonnet-5": counts]])
}

@Test func sumsBucketsInsideTheWindow() {
    var cache = ScanCache()
    cache.files["a.jsonl"] = state(at: anchorDate.addingTimeInterval(3600), units: 10)
    cache.files["b.jsonl"] = state(at: anchorDate.addingTimeInterval(7200), units: 25)
    let total = cache.units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400),
                            weights: .default)
    #expect(abs(total - 35) < 1e-9)
}

@Test func excludesBucketsOutsideTheWindow() {
    var cache = ScanCache()
    cache.files["old.jsonl"] = state(at: anchorDate.addingTimeInterval(-86_400), units: 999)
    cache.files["new.jsonl"] = state(at: anchorDate.addingTimeInterval(3600), units: 10)
    let total = cache.units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400),
                            weights: .default)
    #expect(abs(total - 10) < 1e-9)
}

@Test func windowEndIsExclusive() {
    var cache = ScanCache()
    let end = anchorDate.addingTimeInterval(86_400)
    cache.files["edge.jsonl"] = state(at: end, units: 50)
    #expect(cache.units(from: anchorDate, to: end, weights: .default) == 0)
}

@Test func evictsFilesUntouchedBeyondTheRetentionWindow() {
    var cache = ScanCache()
    cache.files["stale.jsonl"] = state(at: anchorDate.addingTimeInterval(-15 * 86_400), units: 1)
    cache.files["fresh.jsonl"] = state(at: anchorDate.addingTimeInterval(-1 * 86_400), units: 1)
    cache.evict(before: anchorDate.addingTimeInterval(-14 * 86_400))
    #expect(cache.files["stale.jsonl"] == nil)
    #expect(cache.files["fresh.jsonl"] != nil)
}

@Test func roundTripsThroughJSON() throws {
    var cache = ScanCache()
    cache.files["a.jsonl"] = state(at: anchorDate,
                                   counts: TokenCounts(input: 12, output: 5,
                                                       cacheWrite: 3, cacheRead: 900))
    let data = try JSONEncoder().encode(cache)
    let decoded = try JSONDecoder().decode(ScanCache.self, from: data)
    #expect(decoded == cache)
}

@Test func rejectsACacheFromAnIncompatibleVersion() throws {
    let json = #"{"version":0,"files":{}}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ScanCache.self, from: json)
    #expect(decoded.isCompatible == false)
}

@Test func emptyCacheSumsToZero() {
    #expect(ScanCache().units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400),
                              weights: .default) == 0)
}

@Test func cacheV2HasNoWeightsAndSurvivesAWeightChange() {
    // The inverted 100x test. Weighted buckets had to discard the whole cache
    // on a weight change; raw cells re-render instead.
    var cache = ScanCache()
    let counts = TokenCounts(input: 1_000, output: 100, cacheWrite: 200, cacheRead: 50_000)
    cache.files["a.jsonl"] = state(at: anchorDate.addingTimeInterval(3600), counts: counts)

    let cheap = cache.units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400),
                            weights: .default)
    var doubled = Weights.default
    doubled.output = Weights.default.output * 2
    let dear = cache.units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400),
                           weights: doubled)

    #expect(dear > cheap)
    #expect(cache.files["a.jsonl"]?.cells == state(at: anchorDate.addingTimeInterval(3600),
                                                   counts: counts).cells)
}

@Test func cacheV2SumsAcrossModelsWithinABucket() {
    var cache = ScanCache()
    let key = String(Bucket.key(for: anchorDate.addingTimeInterval(3600)))
    cache.files["a.jsonl"] = FileState(
        modifiedAt: anchorDate, size: 1, offset: 1,
        cells: [key: ["claude-opus-5": TokenCounts(output: 10),
                      "claude-sonnet-5": TokenCounts(output: 10)]]
    )
    // opus 5.0x vs sonnet 1.0x, output weight 5.0 → 10*5*5 + 10*5*1 = 300
    let total = cache.units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400),
                            weights: .default)
    #expect(abs(total - 300) < 1e-9)
}
