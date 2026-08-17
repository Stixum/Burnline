import Foundation
import Testing
@testable import BurnlineCore

@Test func tokenCountsAddComponentwise() {
    let a = TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 4)
    let b = TokenCounts(input: 10, output: 20, cacheWrite: 30, cacheRead: 40)
    #expect(a + b == TokenCounts(input: 11, output: 22, cacheWrite: 33, cacheRead: 44))
}

@Test func tokenCountsZeroIsAdditiveIdentity() {
    let a = TokenCounts(input: 5, output: 6, cacheWrite: 7, cacheRead: 8)
    #expect(a + .zero == a)
}

@Test func tokenCountsRoundTripsThroughJSON() throws {
    let a = TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 4)
    let data = try JSONEncoder().encode(a)
    #expect(try JSONDecoder().decode(TokenCounts.self, from: data) == a)
}
