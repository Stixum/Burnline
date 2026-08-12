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
    /// Refresh **before** the UI would call the figure stale.
    ///
    /// This was originally equal to `CaptureAge.stalenessThreshold`, on the
    /// reasoning that the app should never spawn a session while still calling
    /// the figure live. The side effect was worse than the thing avoided: the
    /// anchor had to actually go stale before anything refreshed it, so in
    /// normal hourly operation the footer flipped to amber and the menu bar grew
    /// a tilde for the ~30s the poll took. Every hour, for nothing.
    ///
    /// With headroom the figure simply stays live, and those two signals become
    /// what they are for — evidence the refresh itself failed.
    ///
    /// 45 minutes is the largest value that still leaves room for one retry
    /// before the hour is up (`staleAfter + minimumInterval <= 3600`), which is
    /// pinned by a test.
    public static let staleAfter: TimeInterval = 45 * 60

    /// Backstop. If a poll fails to refresh anything — Claude Code missing, not
    /// signed in, the command renamed — the anchor stays stale and the condition
    /// above stays true forever. Without a floor that spawns a session every
    /// scan tick.
    public static let minimumInterval: TimeInterval = 15 * 60

    /// - Parameters:
    ///   - anchorAge: seconds since the freshest usable reading; `nil` when
    ///     there is none, which is the strongest case for polling rather than
    ///     the weakest.
    ///   - lastPollAt: when this app last spawned a poll, successful or not.
    public static func shouldPoll(enabled: Bool,
                                  anchorAge: TimeInterval?,
                                  lastPollAt: Date?,
                                  now: Date) -> Bool {
        guard enabled else { return false }
        if let lastPollAt, now.timeIntervalSince(lastPollAt) < minimumInterval { return false }
        guard let anchorAge else { return true }
        return anchorAge > staleAfter
    }
}
