import Foundation
import Testing
@testable import BurnlineCore

struct HistoryFileNameTests {
    @Test func aBucketNearAUTCWeekBoundaryResolvesByUTCNotLocalTime() {
        // ⚠️ BOTH assertions are required; either alone is a fail-open guard.
        // Verified instants:
        //   1786923900  UTC Sun 23:45 W33 | US Pacific Sun 16:45 W33 | Tokyo Mon 08:45 W34
        //   1786924800  UTC Mon 00:00 W34 | US Pacific Sun 17:00 W33 | Tokyo Mon 09:00 W34
        // The first discriminates only EAST of UTC, the second only WEST. On a US
        // machine the first passes against a local-time implementation — which is
        // exactly how an earlier version of this test proved nothing.
        #expect(HistoryFileName.forBucket(1_786_923_900) == "2026-W33.jsonl")
        #expect(HistoryFileName.forBucket(1_786_924_800) == "2026-W34.jsonl")
    }

    @Test func historyFileNameLooksLikeAnISOWeek() {
        let name = HistoryFileName.forBucket(1_786_924_800)
        #expect(name.hasSuffix(".jsonl"))
        #expect(name.count == "2026-W33.jsonl".count)
        #expect(name.contains("-W"))
    }

    @Test func namesForRangeCoversEveryWeekTouched() {
        let start = Date(timeIntervalSince1970: 1_786_924_800)
        let names = HistoryFileName.forRange(from: start, to: start.addingTimeInterval(20 * 86_400))
        #expect(names.count >= 3)          // 20 days spans at least three ISO weeks
        #expect(Set(names).count == names.count)
    }
}
