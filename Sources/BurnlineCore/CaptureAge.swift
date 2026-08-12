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

    /// Why the anchor has stopped moving, when it has. `nil` while captures are
    /// landing normally.
    ///
    /// **Only sessions that render a status line publish a capture.** Verified
    /// 2026-08-11: with desktop-app sessions running, the statusline command was
    /// not invoked for 40 minutes — the helper's own atime sat still — and one
    /// turn in a terminal session produced a capture within seconds, moving the
    /// figure 69% → 74%. A headless session has no status line to draw, so it
    /// never runs the command, timer included.
    ///
    /// ⚠️ **This is about the anchor, not the usage.** Desktop-app sessions still
    /// write transcripts to `~/.claude/projects`, so their tokens *are* counted —
    /// this very session accounted for 100M weighted units in the scan cache.
    /// What a stale capture costs is the correction: the true percentage that
    /// re-anchors the estimate and folds in usage this Mac cannot see (claude.ai
    /// in a browser, another machine) plus any drift in the local weighting.
    /// Measured on the 2026-08-11 incident, that drift was ~2 points over 3
    /// hours — the estimate read 72% against a true 74%.
    ///
    /// An earlier version of this copy said desktop sessions "don't report
    /// usage", which reads as *their usage isn't counted*. It is.
    public static func scarcityExplanation(_ age: TimeInterval?) -> String? {
        guard isStale(age), let age else { return nil }
        // `description` is phrased for a timestamp ("3h ago"); this is prose.
        let elapsed = description(age).replacingOccurrences(of: " ago", with: "")
        return "Carried forward for \(elapsed) from this Mac's token counts. "
            + "Only a terminal session re-anchors it to Anthropic's own figure."
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
