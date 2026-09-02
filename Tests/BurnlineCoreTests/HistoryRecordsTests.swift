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
        #expect(row.regrant == nil)

        // Positive control. Without it "absent decodes to nil" is
        // indistinguishable from a field nothing ever populates, and the
        // assertion above would hold against a decoder that ignored the key
        // entirely.
        func withRegrant(_ body: String) -> Data {
            Data(line.replacingOccurrences(
                of: #""boundsSource":"extrapolated""#,
                with: #""boundsSource":"extrapolated","regrant":{"# + body + "}").utf8)
        }
        let carried = try decoder.decode(
            WindowRow.self,
            from: withRegrant(#""at":"2026-05-14T02:00:00Z","percent":3,"observed":1"#))
        #expect(carried.regrant?.at == Date(timeIntervalSince1970: 1_778_724_000))
        #expect(carried.regrant?.percent == 3)
        #expect(carried.regrant?.observed == 1)

        // 🔴 And the point of nesting: a half-written annotation is not a
        // lenient decode, it is not a decode at all. Three independent
        // optionals accepted `observed` with no instant behind it, and
        // `windows.jsonl` is append-only — a line like that would have been
        // permanent. `decodeLines` drops what it cannot read, which is the
        // safe direction for a row no writer of ours can produce.
        #expect(throws: (any Error).self) {
            try decoder.decode(WindowRow.self, from: withRegrant(#""observed":2"#))
        }
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
                      regrant: regrant ? WindowRow.RegrantAnnotation(
                        at: regrantedAt, percent: 3, observed: 1) : nil)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let annotated = try encoder.encode(row(regrant: true))
        let annotatedJSON = String(decoding: annotated, as: UTF8.self)
        #expect(annotatedJSON.contains("\"percent\":3"))
        // Positive control for the omission assertion below: the key is
        // written when there is something to write.
        #expect(annotatedJSON.contains("\"regrant\":{"))
        #expect(annotatedJSON.contains("\"observed\":1"))
        #expect(try decoder.decode(WindowRow.self, from: annotated) == row(regrant: true))

        // An unannotated row carries no `regrant` key at all rather than a
        // null or an empty object: every ordinary week writes one of these
        // lines forever.
        let plain = String(decoding: try encoder.encode(row(regrant: false)), as: UTF8.self)
        #expect(!plain.contains("regrant"))
    }
}
