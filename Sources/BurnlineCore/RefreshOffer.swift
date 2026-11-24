import Foundation

/// What the user has said about automatic refresh.
///
/// The setting itself is a `Bool`, and "off" used to mean two things: nobody
/// has asked, and the user said no. The offer below is only ever for the first.
public enum RefreshChoice: Equatable, Sendable {
    /// Off, and the user has never been asked or answered.
    case neverChose
    /// On. It is confirmed before it is enabled, so on is always a choice.
    case on
    /// Off because the user said so.
    case off
}

public extension BurnlineSettings {
    var refreshChoice: RefreshChoice {
        if refreshesUsageAutomatically { return .on }
        return hasAnsweredRefreshOffer ? .off : .neverChose
    }

    /// The one way the setting is changed by a person: the popover's offer, the
    /// Settings switch, or its confirmation. Either answer is recorded, so
    /// nobody who has answered is asked again.
    mutating func chooseAutomaticRefresh(_ on: Bool) {
        refreshesUsageAutomatically = on
        hasAnsweredRefreshOffer = true
    }
}

/// The popover's offer to turn on automatic refresh, when it has one to make.
///
/// **Why it exists.** The status line helper runs only in terminal sessions.
/// Someone who works only in the desktop app has a correctly configured helper
/// that never runs, and the refresh that would stand in for it is off by
/// default, so the figure goes stale and then, at the next reset, disappears.
/// Measured 2026-11-21: on the Mac this was written on the helper had last
/// written nineteen days earlier, and the figure was current only because the
/// refresh had been turned on by hand.
///
/// **Why it is an offer and not a new default.** The refresh starts real Claude
/// Code sessions, which contact Anthropic. That is a different kind of act from
/// reading files, so it stays off until someone says yes, and the yes still
/// goes through the confirmation in Settings.
///
/// Exceptions-only, like every other amber or violet row in the popover: absent
/// unless the figure has gone a day without a reading and nobody has answered.
public enum RefreshOffer: Equatable, Sendable {
    /// A figure is on screen, and its last reading is at least a day old.
    case stale(age: TimeInterval)
    /// No figure at all, and the helper has not written for a day, or ever.
    case noReading

    /// A whole day. An evening away or a night asleep is the ordinary state of
    /// every install, and the footer already says "Extrapolated" from the first
    /// hour; this is the point at which it is worth asking a question.
    public static let threshold: TimeInterval = 86_400

    /// - Parameters:
    ///   - figureAge: age of the live reading on screen; `nil` when there is
    ///     none (pace only, or hand calibration).
    ///   - helper: the status line helper's report; `nil` until the first
    ///     capture load, when nothing is known yet.
    ///   - isAuthBlocked: the auth banner is showing. Every refresh is gated
    ///     while it stands, so the banner's own button is the only remedy.
    public static func resolve(choice: RefreshChoice,
                               figureAge: TimeInterval?,
                               helper: StatuslineReport?,
                               isScanning: Bool,
                               claudeFound: Bool,
                               isAuthBlocked: Bool) -> RefreshOffer? {
        guard choice == .neverChose, claudeFound, !isAuthBlocked else { return nil }

        // A figure on screen: its own age decides, whatever the helper is
        // doing. An idle terminal republishes the reading it started with
        // every 30 seconds, so "the helper is reporting" and "the figure is
        // two days old" are routinely both true.
        if let figureAge {
            // Whole seconds, never negative, like `StatuslineReport`.
            let age = max(0, figureAge.rounded())
            return age >= threshold ? .stale(age: age) : nil
        }

        // No figure. The helper's last write is the only clock there is: if it
        // wrote within the day a terminal session is in use and a figure is on
        // its way (the morning after a reset). Unknown is not "never".
        guard !isScanning, let helper else { return nil }
        switch helper {
        case .never: return .noReading
        case .quiet(let age): return age >= threshold ? .noReading : nil
        case .reporting: return nil
        }
    }

    /// The same rule, read off the snapshot the popover is drawing.
    public static func resolve(choice: RefreshChoice, snapshot: Snapshot,
                               helper: StatuslineReport?,
                               claudeFound: Bool) -> RefreshOffer? {
        resolve(choice: choice, figureAge: snapshot.liveAge, helper: helper,
                isScanning: snapshot.isScanning, claudeFound: claudeFound,
                isAuthBlocked: snapshot.isAuthBlocked)
    }

    // The words. Here rather than in the view, like `AuthBlockCopy`: the
    // `Burnline` target has no tests, so a string assembled there is a string
    // nothing can check.

    /// The setting's own verb, as a question. The age is not repeated here: in
    /// the stale state the amber line directly above and the footer both carry
    /// it already.
    public var title: String { "Refresh automatically?" }

    /// What is wrong, what turning it on would do, and that nothing has been
    /// turned on. "A brief Claude Code session" is the phrase Settings and the
    /// Refresh control already use for the same act.
    public var detail: String {
        let session = "Burnline can run /usage in a brief Claude Code session"
        let body: String
        switch self {
        case .stale:
            body = "The desktop app never reports usage, so the figure goes stale. "
                + session + " to keep it current."
        case .noReading:
            body = "The desktop app never reports usage, so no figure arrives from it. "
                + session + " to fetch one."
        }
        return body + " Nothing runs until you turn it on."
    }

    /// ⚠️ The ellipsis is the platform's promise that this opens something and
    /// asks more, which is what happens: Settings, with its confirmation.
    public static let acceptLabel = "Turn on…"
    public static let declineLabel = "No thanks"
    public static let acceptHelp = "Opens Settings and asks you to confirm. "
        + "Nothing is turned on until you do."
    public static let declineHelp = "Leaves it off and stops asking. "
        + "The switch stays in Settings, under General."
}
