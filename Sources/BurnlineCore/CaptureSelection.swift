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
    /// Ranking is `freshest`'s: latest `capturedAt`, then a proven date over an
    /// inferred one, then first-listed wins. `select` takes any array, so that
    /// last clause is the caller's contract too — pass candidates in a
    /// deterministic order.
    ///
    /// - Parameter mark: the persisted high-water state, which is where an open
    ///   epoch lives. Passing `.empty` reduces this to `freshest` exactly.
    public static func select(_ candidates: [RateLimitCapture],
                              mark: RateLimitHighWater) -> RateLimitCapture? {
        picked(candidates, mark: mark) ?? standIn(for: mark)
    }

    /// The eligible winner, or nil when nothing on disk survives the filter.
    ///
    /// `select`'s first half, split out because `resolve` needs to tell the two
    /// outcomes APART and `select` deliberately hides which happened: a real
    /// candidate must be reconciled against the mark, while the stand-in must
    /// not be — it IS the mark, and reconciling it fabricates dates. See
    /// `resolve`.
    static func picked(_ candidates: [RateLimitCapture],
                       mark: RateLimitHighWater) -> RateLimitCapture? {
        CaptureDirectory.freshest(of: eligible(candidates, mark: mark))
    }

    /// 🔴 The filter applies only while an epoch is open, and the discriminator
    /// is `regrant != nil` — never a percentage, for the reason recorded on
    /// `RateLimitHighWater.Regrant`.
    ///
    /// While no epoch is open every candidate is eligible, so any non-empty
    /// input is ranked exactly as `freshest` alone would rank it. (Selection as
    /// a whole is not unchanged: an EMPTY input now yields the stand-in rather
    /// than nil — see `standIn`.) Statusline captures carry no `provenAt` unless
    /// a transcript happened to date them, so an unconditional proof requirement
    /// would silently blind every machine that has never seen a re-grant, which
    /// is the overwhelming majority of the time.
    static func eligible(_ candidates: [RateLimitCapture],
                         mark: RateLimitHighWater) -> [RateLimitCapture] {
        guard let sevenDay = mark.sevenDay, let regrant = sevenDay.regrant else {
            return candidates
        }
        return candidates.filter { candidate in
            // An epoch belongs to one window, and this rule exists to refuse
            // REPLAYS of that window's pre-re-grant reading. A candidate
            // describing a different window cannot be one, so refusing it would
            // discard live information — and, since the stand-in is the mark
            // from the window that just ended, freeze the app on a dead window
            // until some proven source happens to report. An all-undated machine
            // — the "older build still in someone's bundle" — would never
            // recover at all.
            //
            // ⚠️ **This is the one comparison in this type where the 60s
            // tolerance belongs.** Window identity is exactly what it was
            // introduced for: the statusline reports whole epoch seconds
            // (`1786690800`) while `cachedUsageUtilization` reports
            // `…06:59:59.424563Z` for the same boundary, 0.58s apart, and exact
            // equality silently gives each source its own view. It would be
            // wrong on `provenAt` below: those are instants of two different API
            // calls, not two spellings of one instant, and slack there is slack
            // in the bar a replay has to clear.
            guard abs(candidate.sevenDay.resetsAt - sevenDay.resetsAt)
                    <= RateLimitHighWater.sameWindowTolerance
            else { return true }
            // An inferred date cannot clear this bar. `capturedAt` is an upper
            // bound on when a reading was minted, so "it was seen after the
            // re-grant" is not evidence that it was *produced* after it — which
            // is the only thing that makes a reading able to describe the new
            // allowance.
            guard let provenAt = candidate.provenAt else { return false }
            // 🔴 `>=` against `regrant.startedAt`, and all three parts matter.
            //
            // `>=` and not `>`: the epoch is dated by the `provenAt` of the very
            // reading that opened it (see `RateLimitHighWater.best`), so a
            // strict comparison would make that reading instantly ineligible —
            // refusing the one capture that reported the re-grant.
            //
            // `startedAt` and not `sevenDay.capturedAt` or `sevenDay.provenAt`,
            // which are same-typed siblings that compile just as happily. This
            // is the hazard `RateLimitHighWater.best` documents for its own
            // parameters, one level up. Those two advance on every equal-or-
            // higher confirmation while `startedAt` stays fixed for the life of
            // the epoch, so either substitution silently ratchets the bar up
            // behind the readings that have to clear it. The fixtures make all
            // three differ for exactly this reason.
            return provenAt >= regrant.startedAt
        }
    }

    /// Everything one rebuild needs out of the captures on disk.
    public struct Resolution: Equatable, Sendable {
        /// The freshest reading actually in a file, whether or not it was
        /// eligible. This is what the user's own terminal status line is
        /// showing, and the only honest answer to "what does the file say".
        public let onDisk: RateLimitCapture?
        /// The capture to trust: the eligible winner reconciled against the
        /// mark, or the mark standing in when nothing on disk survived.
        ///
        /// 🔴 Named for its ROLE, not its type. `onDisk` is a
        /// `RateLimitCapture?` too, so `build(rateLimit: resolution.onDisk)`
        /// compiles and quietly shows the reading this unit just refused —
        /// and `UsageStore` has no test target to catch it.
        public let trusted: RateLimitCapture?
        /// The mark to persist.
        public let highWater: RateLimitHighWater
        /// Set only when `onDisk` and `trusted` disagree.
        public let rejected: RateLimitHighWater.RejectedReading?

        /// The open allowance epoch, if any. Both call sites reach through the
        /// same two levels; this is the one place that spelling lives.
        public var regrant: RateLimitHighWater.Regrant? { highWater.sevenDay?.regrant }
    }

    /// Select, then reconcile, then report — in that order, once.
    ///
    /// 🔴 **The order is the feature, and it is written here rather than at the
    /// call site because `UsageStore` lives in an executable target with no
    /// tests of its own.** Composed inline there, both of the following would
    /// pass the entire suite:
    ///
    /// - *Filtering after reconciliation.* `reconcile` is handed the unfiltered
    ///   freshest, an ineligible replay reaches `best()`, and both bypasses
    ///   documented at the top of this file are back — the filter then discards
    ///   a mark that has already been corrupted.
    /// - *Reporting the rejection from the selected capture.* With a stand-in,
    ///   `onDisk` and `resolved` are the same object and `rejection` is `nil`.
    ///   The terminal shows 51%, the app shows 7%, and the row that exists to
    ///   explain exactly that disagreement never fires — the "looks like a
    ///   broken app" failure, reintroduced by its own fix.
    ///
    /// Pure, and it persists nothing: the caller writes `highWater` (and
    /// `BurnlineProbe` deliberately does not, so a diagnostic run never mints a
    /// mark).
    public static func resolve(_ candidates: [RateLimitCapture],
                               against highWater: RateLimitHighWater) -> Resolution {
        // Unfiltered, deliberately: this is the file's own claim, and it is
        // needed whether or not the file's claim survives selection.
        let onDisk = CaptureDirectory.freshest(of: candidates)

        func reported(_ trusted: RateLimitCapture?) -> RateLimitHighWater.RejectedReading? {
            guard let trusted, let onDisk else { return nil }
            return RateLimitHighWater.rejection(onDisk: onDisk, resolved: trusted)
        }

        // 🔴 The stand-in is NOT reconciled, and this is not an optimisation.
        //
        // `standIn` reconstitutes one capture from a mark that holds TWO
        // independently-dated readings, stamping the seven-day mark's
        // `capturedAt`/`provenAt` on the whole thing — there is nowhere else for
        // them to come from. Send that through `reconcile` and the five-hour
        // reading, equal in value to its own mark, takes the equal-value branch:
        // `max(capturedAt, mark.capturedAt)` and `laterProof(…)` then advance
        // the FIVE-HOUR mark's dates to the seven-day's. The two diverge
        // routinely — a seven-day climb accepted while a lower unproven
        // five-hour reading was refused — and `UsageStore` persists any mark
        // that differs, so a confirmation the five-hour reading never earned is
        // written to disk. That is the exact class `best()` refuses for itself:
        // "a clamped value is a fabricated proof written to disk".
        //
        // There is also nothing to reconcile. The stand-in IS the mark; passing
        // the mark through untouched is the whole of the correct answer.
        guard let incoming = picked(candidates, mark: highWater) else {
            let standIn = standIn(for: highWater)
            return Resolution(onDisk: onDisk, trusted: standIn,
                              highWater: highWater, rejected: reported(standIn))
        }
        let (resolved, mark) = RateLimitHighWater.reconcile(incoming, against: highWater)
        return Resolution(onDisk: onDisk, trusted: resolved, highWater: mark,
                          rejected: reported(resolved))
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
