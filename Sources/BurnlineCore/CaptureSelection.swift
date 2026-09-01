import Foundation

/// Which of the loaded captures may be trusted, given the allowance epoch
/// currently open.
///
/// **Why this exists upstream of `RateLimitHighWater`.** Selection happens
/// first: every candidate is loaded, exactly one is chosen, and only that one is
/// handed to `reconcile`. So `reconcile` cannot defend against a candidate it is
/// never shown, and the demotion rule it enforces is bypassable in two ways
/// unless the choosing itself is filtered:
///
/// 1. **Pre-epoch.** An undated writer through the shared `rate-limits.json` —
///    an older build still in someone's bundle, the rollback script, or a
///    payload carrying no `session_id` — is stamped `Date()`, cannot be
///    transcript-dated, and is invisible to `correctedForRepublishing` until its
///    five-hour window expires. Its `capturedAt` therefore tracks *now* and beats
///    a proven-but-frozen `fetchedAtMs` on freshness. The proven reading never
///    reaches `best()` at all, and the display re-freezes.
/// 2. **Post-epoch.** With an epoch open, an idle session replaying the
///    pre-re-grant percentage arrives *higher* than the mark, and `best()`'s
///    higher branch carries no proof requirement — a higher reading is new
///    information by construction. It is accepted, and the mark returns to the
///    frozen figure with `regrant.startedAt` still pointing at the re-grant.
///
/// Both are the same defect: a reading that cannot possibly postdate the
/// re-grant being allowed to speak for the period after it. The rule is
/// therefore about eligibility to be *considered*, not about who wins.
public enum CaptureSelection {

    /// The capture to trust out of everything on disk.
    ///
    /// Pure, like `CaptureDirectory.freshest` — the caller loads and dates the
    /// candidates first, because both are file I/O and this must stay testable
    /// without either.
    ///
    /// - Parameter mark: the persisted high-water state, which is where an open
    ///   epoch lives. Passing `.empty` reduces this to `freshest` exactly.
    public static func select(_ candidates: [RateLimitCapture],
                              mark: RateLimitHighWater) -> RateLimitCapture? {
        if let picked = CaptureDirectory.freshest(of: eligible(candidates, mark: mark)) {
            return picked
        }
        return standIn(for: mark)
    }

    /// 🔴 The filter applies only while an epoch is open, and the discriminator
    /// is `regrant != nil` — never a percentage, for the reason recorded on
    /// `RateLimitHighWater.Regrant`.
    ///
    /// Before any epoch exists, selection is unchanged. Statusline captures
    /// carry no `provenAt` unless a transcript happened to date them, so an
    /// unconditional proof requirement would silently blind every machine that
    /// has never seen a re-grant — the overwhelming majority of the time.
    static func eligible(_ candidates: [RateLimitCapture],
                         mark: RateLimitHighWater) -> [RateLimitCapture] {
        guard let regrant = mark.sevenDay?.regrant else { return candidates }
        return candidates.filter { candidate in
            // An inferred date cannot clear this bar. `capturedAt` is an upper
            // bound on when a reading was minted, so "it was seen after the
            // re-grant" is not evidence that it was *produced* after it — which
            // is the only thing that makes a reading able to describe the new
            // allowance.
            guard let provenAt = candidate.provenAt else { return false }
            // 🔴 `>=`, not `>`. The epoch is dated by the `provenAt` of the very
            // reading that opened it (see `RateLimitHighWater.best`), so a
            // strict comparison would make that reading instantly ineligible —
            // refusing the one capture that reported the re-grant.
            return provenAt >= regrant.startedAt
        }
    }

    /// The mark, reconstituted as a capture, for when nothing survives.
    ///
    /// 🔴 Returning nil here is a worse regression than the bug being fixed.
    /// `SnapshotBuilder.build` reads `rateLimit: nil` as "no capture has ever
    /// existed": it reverts the window to `settings.resetSchedule` — the
    /// Thursday 09:00 placeholder that is never written back — and drops the
    /// source to calibrated or pace-only. The eligibility filter above makes an
    /// empty result routine rather than exceptional, so that path is now
    /// genuinely reachable.
    ///
    /// **The five-hour reading comes back too.** Eligibility excludes a whole
    /// *candidate*, and the five-hour block rides inside it — so without this,
    /// the popover's five-hour row blinks out for a reason that has nothing to
    /// do with the five-hour window.
    ///
    /// Nothing here is invented: `capturedAt` and `provenAt` are the mark's own,
    /// so the stand-in is as old as it really is and the popover's staleness
    /// styling still tells the truth. It carries no `regrant` field of its own
    /// and needs none — a capture equal to the mark re-confirms it, and
    /// `reconcile` carries the open epoch forward untouched.
    static func standIn(for mark: RateLimitHighWater) -> RateLimitCapture? {
        guard let sevenDay = mark.sevenDay else { return nil }
        var capture = RateLimitCapture(
            version: RateLimitCapture.currentVersion,
            capturedAt: sevenDay.capturedAt,
            sevenDay: .init(usedPercent: sevenDay.usedPercent, resetsAt: sevenDay.resetsAt),
            fiveHour: mark.fiveHour.map {
                .init(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
            })
        capture.provenAt = sevenDay.provenAt
        return capture
    }
}
