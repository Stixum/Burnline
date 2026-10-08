import Foundation

/// Whether the statusline helper is actually reporting — as distinct from
/// `StatuslineWiring.State.configured`, which only says the settings name it.
///
/// 🔴 **Configured is not reporting.** The helper runs only in sessions that
/// draw a status line, and the desktop app's sessions never do (verified
/// 2026-08-11). Someone working there has a correctly configured helper that
/// never runs, and "Connected" with a green tick said otherwise: on the Mac
/// this was written on, the last write was six days old.
///
/// Dated by the helper's last WRITE, not by any capture's stamp: a replay's
/// `capturedAt` is pulled back to the window it describes, so the stamp can be
/// hours older than the moment the helper last ran. Running is the question.
public enum StatuslineReport: Equatable, Sendable {
    /// Wrote within `CaptureAge.stalenessThreshold`.
    case reporting(age: TimeInterval)
    /// Has written, but not for longer than that.
    case quiet(age: TimeInterval)
    /// Nothing the helper writes exists.
    case never

    /// Whole seconds, never negative: a clock stepped backwards reads as now.
    public init(lastWrote: Date?, now: Date) {
        guard let lastWrote else {
            self = .never
            return
        }
        let age = max(0, now.timeIntervalSince(lastWrote).rounded())
        // The popover's own staleness threshold, so the two surfaces cannot
        // disagree about when a report has gone quiet.
        self = CaptureAge.isStale(age) ? .quiet(age: age) : .reporting(age: age)
    }

    public var isQuiet: Bool {
        if case .reporting = self { return false }
        return true
    }

    /// Replaces `State.title` while configured. "Connected" stays first: the
    /// wiring is genuinely in place, and the rest of the line says whether
    /// anything is coming through it.
    public var title: String {
        switch self {
        case .reporting(let age): "Connected · reported \(CaptureAge.description(age))"
        case .quiet(let age): "Connected · last report \(CaptureAge.description(age))"
        case .never: "Connected · no report yet"
        }
    }

    /// Why a configured helper is quiet, and what to do about it. Nil while it
    /// is reporting.
    ///
    /// With the `/usage` refresh on, the figure is fine and the line only
    /// explains where it is coming from — naming a remedy for a problem the
    /// user does not have would read as an error.
    public func explanation(pollEnabled: Bool) -> String? {
        guard isQuiet else { return nil }
        let cause = "Only terminal Claude Code sessions run a status line; the desktop app never does."
        return pollEnabled
            ? cause + " The figure is coming from the /usage refresh instead."
            : cause + " Send a message in a terminal session, or turn on Refresh usage automatically."
    }
}
