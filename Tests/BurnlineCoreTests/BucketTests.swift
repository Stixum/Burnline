import Testing
import Foundation
@testable import BurnlineCore

@Test func bucketKeyIsStableWithinAQuarterHour() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)  // exactly on a 900s boundary
    #expect(Bucket.key(for: base) == Bucket.key(for: base.addingTimeInterval(899)))
    #expect(Bucket.key(for: base) != Bucket.key(for: base.addingTimeInterval(900)))
}

@Test func bucketKeysAdvanceByOne() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(Bucket.key(for: base.addingTimeInterval(900)) == Bucket.key(for: base) + 1)
}

@Test func bucketStartRoundTripsTheKey() {
    let base = Date(timeIntervalSince1970: 1_800_000_450)
    let start = Bucket.start(ofKey: Bucket.key(for: base))
    #expect(start <= base)
    #expect(base.timeIntervalSince(start) < 900)
}

@Test func bucketKeyFloorsRatherThanRounds() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(Bucket.key(for: base.addingTimeInterval(890)) == Bucket.key(for: base))
}
