import Foundation

/// Renders the line Claude Code prints in the user's terminal.
///
/// A 1:1 port of the jq filter in the original `burnline-statusline.sh`. The
/// format is settled and in daily use — this file exists to remove the `jq`
/// dependency, not to change what it prints.
public enum StatusLineRenderer {
    static let separator = "  ·  "
    /// Printed when the payload carries nothing renderable, so the status line
    /// is never blank.
    public static let fallback = "burnline"

    public static func render(_ payload: StatuslinePayload) -> String {
        var fields: [String] = []

        if let name = payload.model?.displayName, !name.isEmpty {
            fields.append(name)
        }
        if let dir = payload.workspace?.currentDir,
           let last = dir.split(separator: "/").last {
            // Deliberate divergence from jq: its `split("/") | last` yields ""
            // for a trailing slash, where Swift's split omits empty
            // subsequences and yields the real last component. current_dir
            // realistically never has one, and a name beats a blank field.
            fields.append(String(last))
        }
        if let ctx = payload.contextWindow?.usedPercentage {
            fields.append("ctx \(percent(ctx))")
        }
        if let week = payload.rateLimits?.sevenDay?.usedPercentage {
            fields.append("week \(percent(week))")
        }
        if let fiveHour = payload.rateLimits?.fiveHour?.usedPercentage {
            fields.append("5h \(percent(fiveHour))")
        }
        if let cost = payload.cost?.totalCostUsd, cost > 0 {
            fields.append(money(cost))
        }

        return fields.isEmpty ? fallback : fields.joined(separator: separator)
    }

    private static func percent(_ value: Double) -> String {
        "\(DisplayValue.floor(value))%"
    }

    /// Two decimal places with trailing zeros dropped, matching how jq prints
    /// the number: $1.2, not $1.20.
    ///
    /// `.rounded()` is away-from-zero and must stay that way: 0.005 * 100 is
    /// exactly 0.5 in binary, which banker's rounding would take to 0 and
    /// render as "$0".
    private static func money(_ value: Double) -> String {
        let clamped = min(max(value, -1e15), 1e15)
        let rounded = (clamped * 100).rounded() / 100
        if rounded == rounded.rounded(.towardZero) {
            return "$\(DisplayValue.floor(rounded, ceiling: 1e15))"
        }
        return "$" + String(format: "%.2f", rounded)
            .replacingOccurrences(of: #"0$"#, with: "", options: .regularExpression)
    }
}
