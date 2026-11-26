import Foundation

/// When the History window reads the archive again.
///
/// 🔴 **Why this is in Core.** The window shipped reading the archive once and
/// never again while it stayed open (2026-11-26: a curve ending at 41% a day
/// after the archive held 74%). The fix is three small decisions, and while
/// they lived in `Sources/Burnline`, which has no test target, a mutation that
/// put the bug straight back left every test green. Each decision is here, and
/// the app only calls it.
public enum HistoryReload {

    /// Everything outside the window's own pickers that a read depends on.
    ///
    /// The window keys `.task(id:)` on this plus its picker values, so a change
    /// in any field re-reads. `UsageStore.historyArchiveKey` is the one place
    /// it is built from the store's values.
    public struct ArchiveKey: Equatable, Sendable {
        /// The launch fill's phase. Moves until the fill finishes, then never.
        public let fill: HistoryFillState.ReloadPhase
        /// A weight edit restates every unit figure.
        public let weights: Weights
        /// 🔴 `HistoryWriter.revision` as the store last published it: the
        /// only field that moves while an open window sits on a finished fill.
        public let archiveRevision: Int

        public init(fill: HistoryFillState.ReloadPhase, weights: Weights, archiveRevision: Int) {
            self.fill = fill
            self.weights = weights
            self.archiveRevision = archiveRevision
        }
    }

    /// How long a read may answer a picker change without going back to disk.
    public static let cacheLifetime: TimeInterval = 15

    /// Whether a cached read may answer this request.
    ///
    /// 🔴 **Never across a revision.** The key change that brought the window
    /// here exists because the archive moved; answering it from a read taken
    /// before that write is the original bug, for up to `cacheLifetime`. Age
    /// alone only spares the disk on a picker change.
    public static func mayReuse(cachedRevision: Int, cachedAt: Date,
                                revision: Int, now: Date) -> Bool {
        cachedRevision == revision && now.timeIntervalSince(cachedAt) < cacheLifetime
    }

    /// The revision as the store publishes it, and when it was first seen.
    public struct Published: Equatable, Sendable {
        public let revision: Int
        public let changedAt: Date?

        public init(revision: Int, changedAt: Date?) {
            self.revision = revision
            self.changedAt = changedAt
        }
    }

    /// What the store should publish after reading the writer's revision, or
    /// nil when nothing changed.
    ///
    /// ⚠️ **`changedAt` is when the revision first arrived, not when it was
    /// last read back.** The store reads the revision after every flush; a
    /// busy Mac flushes every minute. Restamping an unchanged revision would
    /// keep pushing `changedAt` forward, so `HistoryFreshness` could never see
    /// a write go unread for its grace, and the amber line that catches a stuck
    /// window would never show.
    public static func publish(writerRevision: Int, over current: Published,
                               now: Date) -> Published? {
        guard writerRevision != current.revision else { return nil }
        return Published(revision: writerRevision, changedAt: now)
    }
}
