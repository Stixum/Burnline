import Foundation

/// Raw token counts for one cell. Deliberately *un*weighted.
///
/// Weighted units are an interpretation of these four numbers under one set of
/// `Weights`; the numbers themselves are facts. The archive stores facts, so a
/// weight change re-renders history instead of invalidating it — the one place
/// where the `ScanCache` remedy (rescan) is unavailable, because Claude Code
/// deletes transcripts after 30 days.
public struct TokenCounts: Equatable, Sendable, Codable {
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public static let zero = TokenCounts()

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input,
                    output: lhs.output + rhs.output,
                    cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                    cacheRead: lhs.cacheRead + rhs.cacheRead)
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }
}
