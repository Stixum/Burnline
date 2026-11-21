import Foundation

/// Whether this launch should stand down because another copy is already
/// running.
///
/// ## Why this exists
///
/// Observed 2026-09-11: `/Applications/Burnline.app` and the `build/Burnline.app`
/// staging bundle `build.sh` leaves behind were running at the same time, started
/// 14 seconds apart at login. They carry the **same `CFBundleIdentifier`**, so
/// `ApplicationSupport.directory()` resolves to the same folder for both and
/// neither knows the other exists.
///
/// What that races: `rate-limit-highwater.json` — the mark defending the
/// percentage against stale replays — plus `scan-cache.json` and `settings.json`,
/// all last-writer-wins. And the history archive: `HistoryWriter` is a serial
/// actor, but serial **within a process**, so two processes have no arbitration
/// at all. Two pollers also mean two `claude` sessions on the poll cadence, and
/// two notification evaluators mean duplicate banners.
///
/// The incumbent wins. A newcomer exits rather than trying to take over: there
/// is no safe handover of a directory both are already writing.
public enum SingleInstance {

    public enum Verdict: Equatable, Sendable {
        case run
        case standDown
    }

    /// - Parameters:
    ///   - bundleIdentifier: `Bundle.main.bundleIdentifier`. **Nil outside a
    ///     bundle**, which is the case this rule bends for.
    ///   - otherInstances: how many *other* processes share that identifier —
    ///     the caller must already have excluded itself.
    public static func verdict(bundleIdentifier: String?, otherInstances: Int) -> Verdict {
        // 🔴 **No identifier means the debug binary, and it must always run.**
        // `.build/debug/Burnline` has no `Info.plist`, so `NSRunningApplication`
        // cannot find peers for it and whatever count the caller derived is
        // meaningless rather than zero. Exiting here would silently kill the
        // screenshot harness, the poll harness and every manual run from a
        // terminal — and the installed app is usually up while those run, so it
        // would fire nearly every time. Same guard shape as `Notifier` and
        // `Updater.startAtLaunch()`.
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return .run }

        // ⚠️ Fails OPEN on an impossible count. A negative means the caller did
        // not exclude itself or miscounted, and refusing to launch with no other
        // copy running — silently, with no window to explain it — is a far worse
        // outcome than the duplicate this guard exists to prevent.
        guard otherInstances > 0 else { return .run }

        return .standDown
    }

    /// One running copy, identified by when its process started and its pid.
    public struct Instance: Equatable, Sendable {
        public let startedAt: TimeInterval?
        public let pid: Int32

        public init(startedAt: TimeInterval?, pid: Int32) {
            self.startedAt = startedAt
            self.pid = pid
        }
    }

    /// The same question, with a tie-break: **the oldest copy runs.**
    ///
    /// Counting alone has a race. Two copies launched together (login item plus
    /// a click) each see the other and both stand down, leaving none. Ordering
    /// them by process start time, then pid, gives both sides the same answer
    /// and exactly one survivor.
    ///
    /// 🔴 Fails to the safe side. Two writers on the history archive is the
    /// outcome this guard exists to prevent, and no copy running is only an
    /// inconvenience — so when any start time is unknown the ordering is not
    /// trusted and the count rule applies: another copy exists, stand down.
    public static func verdict(bundleIdentifier: String?,
                               mine: Instance, others: [Instance]) -> Verdict {
        guard verdict(bundleIdentifier: bundleIdentifier,
                      otherInstances: others.count) == .standDown else { return .run }
        guard let myStart = mine.startedAt else { return .standDown }

        for other in others {
            guard let theirStart = other.startedAt else { return .standDown }
            if (theirStart, other.pid) < (myStart, mine.pid) { return .standDown }
        }
        return .run
    }
}
