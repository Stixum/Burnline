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

    public static func description(_ age: TimeInterval?) -> String {
        guard let age else { return "now" }
        if age < 90 { return "just now" }
        let minutes = Int(age / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h ago" : "\(hours / 24)d ago"
    }
}
