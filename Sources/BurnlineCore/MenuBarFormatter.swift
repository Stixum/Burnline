import Foundation

/// The menu bar string. Deliberately free of color — macOS renders this
/// against a light or dark bar depending on the user's wallpaper, so the
/// label must survive both. All color lives in the popover.
public enum MenuBarFormatter {
    private static let displayCeiling: Double = 999
    /// Shown when the selected format has nothing to say. Never substitute
    /// another number for it — at four characters wide, an unlabelled figure in
    /// the wrong format reads as the right one.
    private static let empty = "—"

    /// Marks a figure that is no longer a reading but an extrapolation.
    ///
    /// **It cannot be colour.** macOS tints menu bar content against a light or
    /// dark bar depending on the user's wallpaper, so a hardcoded colour is
    /// unreadable on one of them — see the popover, which owns all colour. A
    /// tilde carries it in one character, and reads as "approximately"
    /// everywhere.
    ///
    /// Added 2026-08-12: the bar showed a confident `75` for 2h18m while the
    /// true figure had moved to 76. The popover said so; the bar is what gets
    /// looked at.
    private static let approximate = "~"

    /// Marks a figure that has stopped moving for a reason the user must act on
    /// — signed out, keychain locked, sign-in expired.
    ///
    /// **It cannot be colour either**, and for the same reason as `approximate`
    /// above: the bar is light or dark by the user's wallpaper, so a hardcoded
    /// red is unreadable on one of them. An exclamation mark carries "something
    /// needs you" in the one character this label can spare.
    ///
    /// ⚠️ **It REPLACES the tilde, never joins it.** A figure that will be
    /// corrected by the next capture and one that can never be corrected are the
    /// same defect at two severities, and only the worse one is worth saying:
    /// `~!64/65` spends six characters saying it twice.
    private static let blocked = "!"

    /// `!` when the app can no longer update at all, `~` when the figure is
    /// merely being carried forward. Never both.
    ///
    /// ⚠️ **The two marks obey opposite rules about the pace target, and the
    /// rule this comment used to state alone is still true — of `~`, and only of
    /// `~`:** *only a usage figure can be stale; the pace target is calendar
    /// arithmetic and exact, so marking it would claim an uncertainty that never
    /// exists.* That is why the tilde is gated on `estimatedPercent != nil`.
    ///
    /// 🔴 **`!` is not a claim about the number at all — it is a claim about
    /// Burnline**, which has been cut off from Anthropic's figure and will not
    /// update *anything* until the user fixes it. That is as true of a bare pace
    /// target as of a ratio, so `!` ignores `estimatedPercent` entirely. And
    /// pace-only is the LONGEST-LIVED blocked state, not an edge case:
    /// `SnapshotBuilder` drops to `.paceOnly` once the dead capture's window
    /// passes and stays there, so a `!` gated like `~` would go silent exactly
    /// when it matters most and leave the bar reading a confident bare `65` for
    /// the rest of the week.
    ///
    /// Driven off `visibleAuthBlock`, never `authBlock`: a block is suppressed
    /// while the anchor is still fresh, and the bar has to obey the same rule as
    /// the popover or the two contradict each other on screen.
    private static func mark(_ text: String, _ snapshot: Snapshot) -> String {
        if snapshot.isAuthBlocked { return blocked + text }
        guard snapshot.estimatedPercent != nil,
              CaptureAge.isStale(snapshot.liveAge) else { return text }
        return approximate + text
    }

    /// `!` only.
    ///
    /// For the branches whose text is not an extrapolation from local token
    /// counts and so can never earn a tilde: the bare pace target, the em dash,
    /// and the five-hour figure — which is read straight out of a capture and is
    /// deliberately never carried forward.
    ///
    /// ⚠️ **Not a cheaper `mark`.** Anything that *can* be carried forward must
    /// go through `mark`, or it silently loses its tilde and a two-hour-old
    /// figure reads as a reading again.
    private static func markBlocked(_ text: String, _ snapshot: Snapshot) -> String {
        snapshot.isAuthBlocked ? blocked + text : text
    }

    public static func text(for snapshot: Snapshot,
                            target: TargetMode = .realTime,
                            display: MenuBarMode = .usedOverTarget) -> String {
        // Outranks every mark, block included: mid-first-scan there is not yet a
        // figure for a mark to qualify, and `!…` would qualify the wait instead.
        if snapshot.isScanning && snapshot.estimatedPercent == nil { return "…" }

        switch display {
        case .usedOverTarget:
            let pace = whole(snapshot.activeTarget(target))
            // Pace-only is a valid state for this format specifically: the clock
            // target alone is the app this started as. Still takes `!` — the
            // target is exact, and Burnline being cut off is a fact about
            // Burnline rather than about the target.
            guard let estimated = snapshot.estimatedPercent else {
                return markBlocked("\(pace)", snapshot)
            }
            return mark("\(whole(estimated))/\(pace)", snapshot)

        case .delta:
            // `Snapshot.delta` is target - estimate, so positive means under.
            // Inverted here: on a usage meter a leading + reads as overspent.
            guard let delta = snapshot.delta(target) else { return markBlocked(empty, snapshot) }
            let over = whole(-delta)
            return mark(over > 0 ? "+\(over)" : "\(over)", snapshot)

        case .projection:
            guard let projected = snapshot.projectedPercent else { return markBlocked(empty, snapshot) }
            return mark("\(whole(projected))%", snapshot)

        case .fiveHour:
            // Both branches take `markBlocked` and neither takes `mark`: this
            // figure is a capture's own number and is never extrapolated, so it
            // has no tilde to earn — but it is frozen by a block like everything
            // else, and within five hours of one it is `—` anyway.
            guard let fiveHour = snapshot.fiveHour else { return markBlocked(empty, snapshot) }
            return markBlocked("\(whole(fiveHour.usedPercent))%", snapshot)

        case .used:
            guard let estimated = snapshot.estimatedPercent else { return markBlocked(empty, snapshot) }
            return mark("\(whole(estimated))%", snapshot)
        }
    }

    /// Stays comprehensive whichever format is on screen. The visual is four
    /// characters wide; the spoken version has no such limit, so abbreviating it
    /// would lose information for no reason.
    public static func accessibilityLabel(for snapshot: Snapshot,
                                          target: TargetMode = .realTime,
                                          display: MenuBarMode = .usedOverTarget) -> String {
        let pace = whole(snapshot.activeTarget(target))
        let frame = target == .endOfDay ? "allowed by the end of today" : "through the weekly window"

        var label: String
        if let estimated = snapshot.estimatedPercent {
            let delta = abs(snapshot.delta(target) ?? 0)
            let direction = (snapshot.isUnder(target) ?? true) ? "ahead of pace" : "behind pace"
            label = "Burnline: \(whole(estimated)) percent used, \(pace) percent \(frame), "
                + "\(DisplayValue.points(delta)) \(direction)"
        } else {
            label = "Burnline: \(pace) percent \(frame), no usage figure yet"
        }

        // A tilde is invisible to a screen reader, so the spoken label has to
        // carry the same fact in words — and an exclamation mark is invisible
        // twice over, being punctuation most voices simply don't announce.
        //
        // `else if`, mirroring the drawn label: `!` replaces `~` there, so a
        // listener must not hear both. "Carried forward for 2h" would in any
        // case describe the lesser half of the problem — the figure will not be
        // corrected at all until the block is cleared. Appending after both
        // branches means the pace-only phrasing gains the reason too, so "no
        // usage figure yet" stops sounding like a wait and starts naming a fix.
        if let block = snapshot.visibleAuthBlock {
            label += ", not updating: \(spoken(block.kind))"
        } else if snapshot.estimatedPercent != nil, CaptureAge.isStale(snapshot.liveAge) {
            label += ", carried forward from local token counts for "
                + CaptureAge.description(snapshot.liveAge)
        }

        if display == .fiveHour, let fiveHour = snapshot.fiveHour {
            label += ". 5-hour window \(whole(fiveHour.usedPercent)) percent used, "
                + "\(fiveHour.remainingDescription) left"
        }
        return label
    }

    /// The block in words, one phrasing per kind.
    ///
    /// ⚠️ **Three distinct sentences, not one shared "authentication problem".**
    /// The three kinds have three different remedies — sign in, unlock the login
    /// keychain, sign in again — and a listener who is told only that something
    /// is wrong has been told the one thing they already knew from the figure
    /// standing still.
    private static func spoken(_ kind: AuthBlock.Kind) -> String {
        switch kind {
        case .signedOut:      return "Claude Code is signed out"
        case .keychainLocked: return "the login keychain is locked"
        case .signInExpired:  return "the Claude Code sign-in has expired"
        }
    }

    private static func whole(_ value: Double) -> Int { DisplayValue.whole(value) }
}
