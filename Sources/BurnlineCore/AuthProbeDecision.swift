import Foundation

/// Whether to ask Claude Code about its credentials right now.
///
/// 🔴 **A diagnosis, not a heartbeat.** The probe spawns a process, so it runs
/// only where there is already a symptom to explain or a block to try to
/// reopen. On a healthy, actively-used machine this answers `false` forever
/// after launch.
public enum AuthProbeDecision {

    /// The floor while nothing is wrong.
    ///
    /// The probe is ~0.17s, so this is not about cost — it is about a rebuild
    /// timer that ticks every 10 seconds. Without a floor a machine would spawn
    /// six processes a minute forever.
    public static let minimumInterval: TimeInterval = 15 * 60

    /// The floor while a block stands.
    ///
    /// 🔴 **A cadence for a timer is the wrong cadence for a person.** This was
    /// 15 minutes, shared with the healthy case, and it produced the defect this
    /// constant exists to fix: the user clicked `Sign in…`, signed in, came
    /// back — and the banner still said they were signed out, for up to a
    /// quarter of an hour, with nothing on screen able to hurry it.
    ///
    /// A blocked machine is already not working, so asking once a minute is
    /// proportionate; it also aligns with the 60s scan tick that hosts the
    /// check, so in practice this costs one extra process per scan while
    /// blocked and none at all otherwise.
    public static let blockedInterval: TimeInterval = 60

    /// - Parameters:
    ///   - anchorAge: how old the live capture is; `nil` when there is none,
    ///     which is the strongest symptom rather than the weakest.
    ///   - lastProbeAt: `nil` at launch, which is a trigger in itself.
    ///   - isBlocked: whether a block currently stands.
    public static func shouldProbe(anchorAge: TimeInterval?,
                                   lastProbeAt: Date?,
                                   isBlocked: Bool,
                                   now: Date) -> Bool {
        // Launch. The baseline is established once, before the user looks.
        guard let lastProbeAt else { return true }
        // ⚠️ The floor depends on the state, and picking the wrong one is how
        // recovery stalls. See `blockedInterval`.
        let floor = isBlocked ? blockedInterval : minimumInterval
        guard now.timeIntervalSince(lastProbeAt) >= floor else { return false }

        // 🔴 A standing block keeps probing, and this is the recovery path.
        // Every kind gates polling, so a poll can never be the proof; and a user
        // whose sessions publish no captures — the desktop-app case — has
        // nothing else that could reopen it. Without this the block is a trap.
        if isBlocked { return true }

        // Otherwise only when the figure has actually stopped moving. A fresh
        // anchor means something is publishing, which is its own answer.
        return CaptureAge.isStale(anchorAge) || anchorAge == nil
    }
}
