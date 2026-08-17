import Foundation
import Testing
@testable import BurnlineCore

struct HistoryRecordsTests {
    @Test func historyRowRoundTripsWithReadableKeys() throws {
        let row = HistoryRow(bucket: 1_786_924_800, project: "Burnline", model: "claude-opus-5",
                             counts: TokenCounts(input: 1_204, output: 8_811,
                                                 cacheWrite: 41_200, cacheRead: 992_304))
        let data = try JSONEncoder().encode(row)
        let json = String(decoding: data, as: UTF8.self)
        // Flat, readable keys — the archive is a queryable artifact, not just an
        // internal format. A nested `counts` object would break spreadsheet use.
        #expect(json.contains("\"cacheRead\":992304"))
        #expect(json.contains("\"project\":\"Burnline\""))
        #expect(!json.contains("\"counts\""))
        #expect(try JSONDecoder().decode(HistoryRow.self, from: data) == row)
    }

    @Test func windowRowOmitsAbsentPercentRatherThanZeroing() throws {
        let row = WindowRow(start: Date(timeIntervalSince1970: 1_786_924_800),
                            end: Date(timeIntervalSince1970: 1_787_529_600),
                            counts: .zero, finalPercent: nil, finalPercentAt: nil,
                            finalPercentSource: nil, boundsSource: .extrapolated,
                            observedResetsAt: nil)
        let json = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        #expect(!json.contains("finalPercent\":0"))
        #expect(json.contains("\"boundsSource\":\"extrapolated\""))
    }

    @Test func coverageRecordDefaultsToVerified() throws {
        let data = Data(#"{"from":100,"through":200,"filledBy":"scan"}"#.utf8)
        let record = try JSONDecoder().decode(CoverageRecord.self, from: data)
        #expect(record.verified)        // absent means verified
        #expect(!record.truncated)
    }
}
