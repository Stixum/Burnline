import Foundation

extension Snapshot {

    /// The popover's extra-usage row, every string resolved here so the view
    /// body only picks a shape.
    ///
    /// ⚠️ **The age suffix is on the plain row only.** Measured: with a suffix,
    /// a symbol row overflows its 240pt (`paused · out of credits · 23h ago` is
    /// 241.6pt). Symbol rows carry the age in the tooltip. `RowWidth` holds the
    /// geometry; `theWidestExtraUsageRowsFitThePopover` holds the worst cases.
    public struct ExtraUsageRow: Equatable, Sendable {
        public enum Style: Equatable, Sendable {
            case plain
            /// Muted with a symbol: switched off by Anthropic, left on by the
            /// user. Can stand for weeks, so it is not amber — amber rows in
            /// this popover are exceptions.
            case paused
            /// Amber with a symbol: at the limit, or a raised severity.
            case warning
        }

        public static let label = "Extra usage"
        public let value: String
        public let tooltip: String
        public let style: Style

        /// Nil past `ExtraUsage.maximumAge`: the figure describes a cycle that
        /// has ended. Precedence when several states hold: paused, at limit,
        /// raised severity, plain.
        init?(_ usage: UsageUtilization.ExtraUsage, now: Date, timeZone: TimeZone) {
            let age = now.timeIntervalSince(usage.fetchedAt)
            guard age <= UsageUtilization.ExtraUsage.maximumAge else { return nil }

            switch usage.state {
            case .paused(let reason):
                style = .paused
                value = reason.map { "paused · \($0)" } ?? "paused"
            case .active where usage.isLimitReached:
                style = .warning
                value = "\(usage.money(usage.limitMinor, labelled: true)) · limit reached"
            case .active:
                let base = "\(usage.money(usage.usedMinor, labelled: true)) of "
                    + usage.money(usage.limitMinor, labelled: false)
                if usage.isSeverityRaised {
                    style = .warning
                    value = base
                } else {
                    style = .plain
                    value = CaptureAge.isStale(age) ? "\(base) · \(CaptureAge.description(age))" : base
                }
            }

            // `en_US_POSIX`, as `Snapshot.Regrant` does: a custom `dateFormat`
            // otherwise picks up locale symbols. The whole UI is English.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            // The date is in the format because the row can be up to 31 days
            // old, and a bare weekday wouldn't say which week.
            formatter.dateFormat = "EEE MMM d, h:mm a"
            var tip = "As of \(formatter.string(from: usage.fetchedAt)). "
                + "Extra usage pays after you hit a plan limit; it doesn't change the weekly figure."
            if case .paused = usage.state { tip += " Turned off by Anthropic; you left it on." }
            tooltip = tip
        }
    }
}
