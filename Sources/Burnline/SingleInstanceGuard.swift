import AppKit
import BurnlineCore

/// Exits at launch if another copy of Burnline is already running.
///
/// `SingleInstance` — pure, in Core — owns the decision; this only gathers the
/// other copies and when each started.
///
/// 🔴 **Must run before `UsageStore()` is constructed.** That initialiser reads
/// `settings.json` and the scan cache and builds a `HistoryStore`, which creates
/// the history directory — so a duplicate that gets as far as constructing the
/// store has already touched the very files this guard exists to keep one writer
/// on. `BurnlineApp` therefore calls this from an explicit `init()` before
/// assigning `_store`, rather than letting a property default run first.
enum SingleInstanceGuard {

    static func standDownIfAnotherIsRunning() {
        let identifier = Bundle.main.bundleIdentifier

        // ⚠️ Only ask AppKit when there is an identifier to ask about. Outside a
        // bundle the question is meaningless, and `SingleInstance.verdict`
        // returns `.run` for that case regardless — but computing a count here
        // anyway would invite someone to "simplify" the guard by trusting it.
        var others: [SingleInstance.Instance] = []
        let me = ProcessInfo.processInfo.processIdentifier
        if let identifier, !identifier.isEmpty {
            // Compare pids rather than the objects: identity on
            // `NSRunningApplication` is not the obvious thing, and getting it
            // wrong would count *this* process and exit every launch.
            others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .map(\.processIdentifier)
                .filter { $0 != me }
                .map { SingleInstance.Instance(startedAt: processStart($0), pid: $0) }
        }

        // The oldest copy runs. Both sides read the same kernel start times, so
        // two copies launched together agree on which one that is, instead of
        // each seeing the other and both exiting. An unreadable start time
        // falls back to standing down — see `SingleInstance.verdict`.
        let mine = SingleInstance.Instance(startedAt: processStart(me), pid: me)
        guard SingleInstance.verdict(bundleIdentifier: identifier,
                                     mine: mine, others: others) == .standDown else { return }

        // Nothing on screen: the incumbent already owns the menu bar item, and a
        // dialog from a copy the user did not knowingly launch explains less
        // than it interrupts. `exit` rather than `NSApp.terminate` because there
        // is no NSApp yet at this point in launch.
        exit(0)
    }

    /// When the kernel started `pid`, or nil if it cannot be read. The kernel's
    /// figure for every process, this one included, so both copies in a race
    /// compare the same two numbers. `NSRunningApplication.launchDate` is not
    /// used: it can be nil for a process this early in its own launch.
    private static func processStart(_ pid: pid_t) -> TimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        guard started.tv_sec > 0 else { return nil }
        return TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
    }
}
