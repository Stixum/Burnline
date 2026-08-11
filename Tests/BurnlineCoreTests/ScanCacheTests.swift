import Testing
import Foundation
@testable import BurnlineCore

private let anchorDate = Date(timeIntervalSince1970: 1_800_000_000)

private func state(at date: Date, units: Double) -> FileState {
    FileState(modifiedAt: date, size: 100, offset: 100,
              buckets: [String(Bucket.key(for: date)): units])
}

@Test func sumsBucketsInsideTheWindow() {
    var cache = ScanCache()
    cache.files["a.jsonl"] = state(at: anchorDate.addingTimeInterval(3600), units: 10)
    cache.files["b.jsonl"] = state(at: anchorDate.addingTimeInterval(7200), units: 25)
    let total = cache.units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400))
    #expect(abs(total - 35) < 1e-9)
}

@Test func excludesBucketsOutsideTheWindow() {
    var cache = ScanCache()
    cache.files["old.jsonl"] = state(at: anchorDate.addingTimeInterval(-86_400), units: 999)
    cache.files["new.jsonl"] = state(at: anchorDate.addingTimeInterval(3600), units: 10)
    let total = cache.units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400))
    #expect(abs(total - 10) < 1e-9)
}

@Test func windowEndIsExclusive() {
    var cache = ScanCache()
    let end = anchorDate.addingTimeInterval(86_400)
    cache.files["edge.jsonl"] = state(at: end, units: 50)
    #expect(cache.units(from: anchorDate, to: end) == 0)
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
    cache.files["a.jsonl"] = state(at: anchorDate, units: 12.5)
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
    #expect(ScanCache().units(from: anchorDate, to: anchorDate.addingTimeInterval(86_400)) == 0)
}
