import AppKit
import BurnlineCore

/// Exits at launch if another copy of Burnline is already running.
///
/// `SingleInstance` — pure, in Core — owns the decision; this only counts.
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
        var others = 0
        if let identifier, !identifier.isEmpty {
            // Compare pids rather than the objects: identity on
            // `NSRunningApplication` is not the obvious thing, and getting it
            // wrong would count *this* process and exit every launch.
            let me = ProcessInfo.processInfo.processIdentifier
            others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { $0.processIdentifier != me }
                .count
        }

        guard SingleInstance.verdict(bundleIdentifier: identifier,
                                     otherInstances: others) == .standDown else { return }

        // Nothing on screen: the incumbent already owns the menu bar item, and a
        // dialog from a copy the user did not knowingly launch explains less
        // than it interrupts. `exit` rather than `NSApp.terminate` because there
        // is no NSApp yet at this point in launch.
        exit(0)
    }
}
