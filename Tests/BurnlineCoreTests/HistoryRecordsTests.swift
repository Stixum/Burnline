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

    @Test func aWindowRowWrittenBeforeTheReGrantAnnotationStillDecodes() throws {
        // 🔴 `windows.jsonl` is append-only and is never rewritten, so every
        // row the live archive already holds lacks these keys. `decodeLines`
        // SKIPS a line it cannot decode — so a decoder that threw on the
        // absent keys would not fail loudly, it would make every historical
        // week vanish from the History window.
        let line = """
        {"start":"2026-05-12T18:23:00Z","end":"2026-05-19T18:23:00Z","input":0,"output":11,"cacheWrite":0,"cacheRead":0,"boundsSource":"extrapolated"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(WindowRow.self, from: Data(line.utf8))
        #expect(row.output == 11)
        #expect(row.regrantedAt == nil)
        #expect(row.percentAtRegrant == nil)
        #expect(row.regrantsObserved == nil)

        // Positive control. Without it "absent decodes to nil" is
        // indistinguishable from a field nothing ever populates, and the
        // assertions above would hold against a decoder that ignored the keys
        // entirely.
        let annotated = line.replacingOccurrences(
            of: #""boundsSource":"extrapolated""#,
            with: #""boundsSource":"extrapolated","regrantedAt":"2026-05-14T02:00:00Z","#
                + #""percentAtRegrant":3,"regrantsObserved":1"#)
        let carried = try decoder.decode(WindowRow.self, from: Data(annotated.utf8))
        #expect(carried.regrantedAt == Date(timeIntervalSince1970: 1_778_724_000))
        #expect(carried.percentAtRegrant == 3)
        #expect(carried.regrantsObserved == 1)
    }

    @Test func theReGrantAnnotationRoundTripsAndIsOmittedWhenAbsent() throws {
        // Whole-second instants on purpose: `.iso8601` encodes whole seconds,
        // so a fractional `regrantedAt` comes back up to a second early. No
        // consumer matches it against another instant, and a second cannot
        // move which day it fell on — but the truncation is real, and a
        // fixture that hid it would mislead whoever adds one.
        let regrantedAt = Date(timeIntervalSince1970: 1_787_000_000)
        func row(regrant: Bool) -> WindowRow {
            WindowRow(start: Date(timeIntervalSince1970: 1_786_924_800),
                      end: Date(timeIntervalSince1970: 1_787_529_600),
                      counts: .zero, finalPercent: 30,
                      finalPercentAt: Date(timeIntervalSince1970: 1_787_100_000),
                      finalPercentSource: "live", boundsSource: .observed,
                      observedResetsAt: nil,
                      regrantedAt: regrant ? regrantedAt : nil,
                      percentAtRegrant: regrant ? 3 : nil,
                      regrantsObserved: regrant ? 1 : nil)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let annotated = try encoder.encode(row(regrant: true))
        let annotatedJSON = String(decoding: annotated, as: UTF8.self)
        #expect(annotatedJSON.contains("\"percentAtRegrant\":3"))
        // Positive control for the omission assertions below: these keys are
        // written when there is something to write.
        #expect(annotatedJSON.contains("\"regrantedAt\""))
        #expect(annotatedJSON.contains("\"regrantsObserved\":1"))
        #expect(try decoder.decode(WindowRow.self, from: annotated) == row(regrant: true))

        // An unannotated row carries none of the three keys rather than
        // zeroes: every ordinary week writes one of these lines forever.
        let plain = String(decoding: try encoder.encode(row(regrant: false)), as: UTF8.self)
        #expect(!plain.contains("regrantedAt"))
        #expect(!plain.contains("percentAtRegrant"))
        #expect(!plain.contains("regrantsObserved"))
    }
}
