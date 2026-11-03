import Foundation

/// Whether to spawn a Claude Code session to refresh the usage anchor.
///
/// Separated from the machinery that carries it out so the rule can be tested
/// on its own. Getting it wrong costs either a figure that silently freezes, or
/// Claude Code sessions accumulating on someone's machine — eight of them piled
/// up unnoticed during the 2026-08-11 investigation.
///
/// **Why polling is needed at all.** A session's `rate_limits` refreshes only
/// when *that session* calls the API, and only sessions that render a status
/// line publish. So an idle terminal republishes a two-hour-old reading every
/// 30s while a desktop session burns quota and never publishes. Measured
/// 2026-08-12: the bar sat on a stale 75% for 2h18m against a true 76%.
///
/// `/usage` refreshes `~/.claude.json` and costs **no model tokens** — verified
/// by pty sessions that produced no transcript and no assistant turns.
public enum PollDecision {
    /// Never let the anchor reach the age at which the UI calls it stale.
    ///
    /// Derived from that threshold rather than hardcoded: the two were once
    /// equal, which meant the anchor had to actually go stale before anything
    /// refreshed it — so in normal operation the footer flipped amber and the
    /// menu bar grew a tilde for the ~30s each poll took. With headroom the
    /// figure simply stays live, and those signals mean what they should: the
    /// refresh itself failed.
    public static let relaxed: TimeInterval = CaptureAge.stalenessThreshold - 5 * 60
    public static let normal: TimeInterval = 45 * 60
    /// Approaching a limit, or projected to exceed one.
    public static let elevated: TimeInterval = 20 * 60
    /// About to hit one. Worth 3.5 CPU-seconds every ten minutes.
    public static let critical: TimeInterval = 10 * 60

    /// How often to refresh, given where usage actually stands.
    ///
    /// **The worst signal wins.** Any of the three can be the binding
    /// constraint, and the five-hour window especially: it moves several times
    /// faster than the weekly one (3% → 17% in a morning) and is deliberately
    /// never extrapolated between anchors, so between polls it is simply
    /// whatever was last read.
    ///
    /// Missing signals are not pressure. Early in a window there is no estimate
    /// and no projection, and treating `nil` as urgent would poll a brand new
    /// window at the tightest rate for nothing.
    public static func interval(weeklyPercent: Double?,
                                fiveHourPercent: Double?,
                                projectedPercent: Double?,
                                ceiling: RefreshInterval) -> TimeInterval {
        let banded: TimeInterval
        if (weeklyPercent ?? 0) > 92 || (fiveHourPercent ?? 0) > 90 {
            banded = critical
        } else if (weeklyPercent ?? 0) > 80
                    || (fiveHourPercent ?? 0) > 70
                    || (projectedPercent ?? 0) > 100 {
            banded = elevated
        } else if (weeklyPercent ?? 0) > 50 || (fiveHourPercent ?? 0) > 50 {
            banded = normal
        } else {
            banded = relaxed
        }
        // A ceiling only ever tightens.
        return min(banded, ceiling.seconds)
    }

    /// The wait after one poll that refreshed nothing. Matches the CLI's own
    /// five-minute throttle on writing `fetchedAtMs`: sooner, a retry could not
    /// show a moved cache even if it worked.
    public static let firstRetry: TimeInterval = 5 * 60

    /// How long to wait before the next poll, given how many in a row have
    /// failed to refresh the anchor.
    ///
    /// The interval used to be the floor after a failure too, so one miss at
    /// minute 46 meant the next attempt at minute 91 — past the hour the UI
    /// calls stale. A failure now retries after `firstRetry` and doubles from
    /// there, settling at the interval: a failure that persists (Claude Code
    /// missing, the command renamed) costs a few extra sessions, then the old
    /// cadence. Never longer than the interval, so it cannot loosen one.
    public static func retryFloor(afterFailures failures: Int,
                                  interval: TimeInterval) -> TimeInterval {
        guard failures > 0 else { return interval }
        let backoff = firstRetry * pow(2, Double(min(failures, 32) - 1))
        return min(backoff, interval)
    }

    /// - Parameters:
    ///   - anchorAge: seconds since the freshest usable reading; `nil` when
    ///     there is none, which is the strongest case for polling rather than
    ///     the weakest.
    ///   - lastPollAt: when this app last spawned a poll, successful or not.
    ///   - consecutiveFailures: polls in a row that refreshed nothing; 0 after
    ///     one that did. Sets the retry floor through `retryFloor`, without
    ///     which a failed poll leaves the anchor stale and the first condition
    ///     true forever, spawning a session on every scan tick.
    ///   - interval: from `interval(weeklyPercent:...)`.
    public static func shouldPoll(enabled: Bool,
                                  anchorAge: TimeInterval?,
                                  lastPollAt: Date?,
                                  consecutiveFailures: Int,
                                  interval: TimeInterval,
                                  now: Date) -> Bool {
        guard enabled else { return false }
        if let lastPollAt,
           now.timeIntervalSince(lastPollAt) < retryFloor(afterFailures: consecutiveFailures,
                                                         interval: interval) {
            return false
        }
        guard let anchorAge else { return true }
        return anchorAge > interval
    }
}
