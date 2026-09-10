import Foundation

/// Whether to ask Claude Code about its credentials right now.
///
/// 🔴 **A diagnosis, not a heartbeat.** The probe spawns a process, so it runs
/// only where there is already a symptom to explain or a block to try to
/// reopen. On a healthy, actively-used machine this answers `false` forever
/// after launch.
public enum AuthProbeDecision {

    /// Never more often than this, whatever else is true.
    ///
    /// The probe is ~0.17s, so the floor is not about cost — it is about a
    /// rebuild timer that ticks every 10 seconds. Without it a blocked machine
    /// would spawn six processes a minute for as long as it stayed blocked.
    public static let minimumInterval: TimeInterval = 15 * 60

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
        guard now.timeIntervalSince(lastProbeAt) >= minimumInterval else { return false }

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
