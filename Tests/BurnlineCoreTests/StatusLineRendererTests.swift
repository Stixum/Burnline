import Testing
import Foundation
@testable import BurnlineCore

private func render(_ json: String) throws -> String {
    StatusLineRenderer.render(try JSONDecoder().decode(StatuslinePayload.self, from: Data(json.utf8)))
}

@Test func rendersEveryField() throws {
    let line = try render("""
    {"model":{"display_name":"Opus 5"},
     "workspace":{"current_dir":"/Users/x/Projects/Burnline"},
     "context_window":{"used_percentage":42.7},
     "cost":{"total_cost_usd":1.2345},
     "rate_limits":{"seven_day":{"used_percentage":64.8,"resets_at":1786000000},
                    "five_hour":{"used_percentage":3.2,"resets_at":1785000000}}}
    """)
    #expect(line == "Opus 5  ·  Burnline  ·  ctx 42%  ·  week 64%  ·  5h 3%  ·  $1.23")
}

@Test func percentagesFloorRatherThanRound() throws {
    #expect(try render(#"{"context_window":{"used_percentage":42.99}}"#) == "ctx 42%")
}

@Test func directoryIsTheBasenameOnly() throws {
    #expect(try render(#"{"workspace":{"current_dir":"/a/b/c/Burnline"}}"#) == "Burnline")
}

@Test func omitsAbsentFieldsWithoutStraySeparators() throws {
    let line = try render(#"{"model":{"display_name":"Haiku"},"rate_limits":{"seven_day":{"used_percentage":10,"resets_at":1}}}"#)
    #expect(line == "Haiku  ·  week 10%")
}

@Test func omitsZeroCost() throws {
    // A $0 session hasn't cost anything yet; printing "$0" is noise.
    #expect(try render(#"{"model":{"display_name":"Haiku"},"cost":{"total_cost_usd":0}}"#) == "Haiku")
}

@Test func moneyDropsTrailingZeros() throws {
    #expect(try render(#"{"cost":{"total_cost_usd":1.2}}"#) == "$1.2")
    #expect(try render(#"{"cost":{"total_cost_usd":1.0}}"#) == "$1")
    #expect(try render(#"{"cost":{"total_cost_usd":0.005}}"#) == "$0.01")
}

@Test func rendersFallbackForAnEmptyPayload() throws {
    #expect(try render("{}") == "burnline")
}

@Test func fiveHourRendersWithoutSevenDay() throws {
    #expect(try render(#"{"rate_limits":{"five_hour":{"used_percentage":3,"resets_at":1}}}"#) == "5h 3%")
}

@Test func fiveHourRendersWithoutItsResetInstant() throws {
    // The renderer is deliberately laxer than `capture()`: it renders from
    // used_percentage alone, where capture() also demands resets_at.
    #expect(try render(#"{"rate_limits":{"five_hour":{"used_percentage":3}}}"#) == "5h 3%")
}

@Test func anAbsurdPercentageDoesNotCrash() throws {
    // JSON can deliver a finite Double far outside Int's range with no exotic
    // syntax — a plain 20-digit integer literal decodes to 1e20, and a bare
    // Int(_:) conversion on that TRAPS. This process runs inside the user's
    // terminal prompt; a crash here is far worse than a silly number.
    // Asserted exactly (not just prefix/suffix) so a clamp regression at, say,
    // the wrong ceiling shows up as a failure instead of passing silently.
    #expect(try render(#"{"context_window":{"used_percentage":100000000000000000000}}"#) == "ctx 999%")
}

@Test func anAbsurdCostDoesNotCrash() throws {
    #expect(try render(#"{"cost":{"total_cost_usd":1e308}}"#) == "$1000000000000000")
}

@Test func trailingSlashStillYieldsTheDirectoryName() throws {
    // Deliberate divergence: jq's `split("/") | last` yields "" here.
    #expect(try render(#"{"workspace":{"current_dir":"/a/b/Burnline/"}}"#) == "Burnline")
}
