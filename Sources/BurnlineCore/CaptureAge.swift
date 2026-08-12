import Foundation

/// How old a live capture is, and whether that age still supports presenting
/// the figure as exact.
///
/// A capture is Anthropic's own number at the instant it lands, and account-wide
/// — it corrects for claude.ai, the desktop app and other machines all at once.
/// After that the app carries it forward from local token counts alone, which
/// see only Claude Code on this Mac. The longer that runs, the more the figure
/// is an extrapolation rather than a reading, and the UI has to say so.
///
/// Captures freeze whenever Claude Code isn't running, so an aged capture is the
/// ordinary overnight state rather than an error.
public enum CaptureAge {
    /// Past this, style the figure as extrapolated rather than live.
    public static let stalenessThreshold: TimeInterval = 3_600

    public static func isStale(_ age: TimeInterval?) -> Bool {
        guard let age else { return false }
        return age > stalenessThreshold
    }

    /// Why the figure has stopped moving, when it has. `nil` while captures are
    /// landing normally.
    ///
    /// **Only sessions that render a status line publish usage.** Verified
    /// 2026-08-11: with desktop-app sessions running, the statusline command was
    /// not invoked for 40 minutes — the helper's own atime sat still — and one
    /// turn in a terminal session produced a capture within seconds, moving the
    /// figure 69% → 74%. A headless session has no status line to draw, so it
    /// never runs the command, timer included.
    ///
    /// Quota burned in the desktop app is therefore real but invisible until a
    /// reporting session takes a turn. A frozen figure is the expected state, not
    /// a fault — and saying so is the difference between "my app is broken" and
    /// "nothing is reporting right now", which is exactly the confusion that
    /// started the 2026-08-11 investigation.
    public static func scarcityExplanation(_ age: TimeInterval?) -> String? {
        guard isStale(age), let age else { return nil }
        // `description` is phrased for a timestamp ("3h ago"); this is prose.
        let elapsed = description(age).replacingOccurrences(of: " ago", with: "")
        return "Carried forward for \(elapsed). Desktop sessions don't report usage — "
            + "a turn in a terminal session refreshes it."
    }

    public static func description(_ age: TimeInterval?) -> String {
        guard let age else { return "now" }
        if age < 90 { return "just now" }
        let minutes = DisplayValue.seconds(age) / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h ago" : "\(hours / 24)d ago"
    }
}
