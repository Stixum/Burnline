import Foundation

/// The highest reading seen inside a given window, so a stale capture can't drag
/// the figure backwards.
///
/// **Why this is needed.** Several Claude Code sessions can be open at once, and
/// every one of them runs the statusline script on its own `refreshInterval`
/// timer, writing the same `rate-limits.json`. Nothing coordinates them: the
/// last writer wins, and "last" has nothing to do with "freshest". Each session
/// carries the `rate_limits` block from *its own* last API response, so a
/// session sitting idle for an hour clobbers a current reading with an old one
/// twice a minute. Observed 2026-08-11 with five sessions open, two of them
/// ~5 hours old.
///
/// **Why the maximum is the default.** Usage inside a fixed window is
/// cumulative: it cannot go down *by consumption*. So a reading lower than one
/// already observed in the same window is *presumed* staler rather than a
/// correction.
///
/// ⚠️ **That presumption is defeasible, and it was defeated on 2026-09-01.**
/// This comment used to call a mid-window downward revision "not a thing
/// cumulative usage does". Anthropic re-issued the weekly allowance without
/// moving `resets_at`; the true figure went 51% → 0% and the app displayed 51%
/// for hours while blaming a stale session. So the rule is now falsifiable: a
/// lower reading demotes the mark when — and only when — its date is *proven*
/// (`RateLimitCapture.provenAt`) rather than inferred, and later than the
/// evidence behind the mark. An undated reading still cannot demote anything,
/// which is what keeps the idle-session defence intact.
public struct RateLimitHighWater: Equatable, Sendable, Codable {

    /// A reading on disk that the high-water mark overrode, kept so the popover
    /// can say so.
    ///
    /// Without this the app silently disagrees with the user's own terminal
    /// status line — which reads as a broken app rather than as the protection
    /// it is. `BurnlineProbe` has always printed it; the UI never did.
    public struct RejectedReading: Equatable, Sendable {
        public let reportedPercent: Double
        public let usingPercent: Double
        /// Set when the refused reading describes a weekly window that has
        /// already reset, rather than a rival claim about the current one.
        ///
        /// Reachable, and it was reachable silently: with an epoch open and the
        /// window then rolling, `CaptureSelection.eligible` refuses an undated
        /// replay of the old window while admitting a proven capture of the new
        /// one — so `onDisk` and `trusted` end up describing different windows.
        /// Without this the row explained that with the re-grant story, which
        /// says "inside this window" about a reading that is not in it.
        ///
        /// 🔴 Only the EARLIER direction is claimed, because only it is
        /// checkable from what `rejection` is handed and only it is the case
        /// that actually occurs. A refused reading from a *later* window would
        /// mean the shown figure is the dead one, a different defect entirely,
        /// and it falls through to the direction branches rather than being
        /// mislabelled here.
        public let isFromAnEarlierWindow: Bool

        public init(reportedPercent: Double, usingPercent: Double,
                    isFromAnEarlierWindow: Bool = false) {
            self.reportedPercent = reportedPercent
            self.usingPercent = usingPercent
            self.isFromAnEarlierWindow = isFromAnEarlierWindow
        }

        /// Assembled here, like `FiveHourStatus.rowValue`, so no view body does
        /// formatting of its own.
        public var rowValue: String {
            "said \(DisplayValue.whole(reportedPercent))%, kept \(DisplayValue.whole(usingPercent))%"
        }

        /// The popover row's label, which has to branch for the same reason
        /// `explanation` does.
        ///
        /// 🔴 **`Stale session` was unconditional and is wrong on two of the
        /// three branches.** `explanation`'s own note says a re-grant refusal
        /// covers a candidate with *no proven date at all* — the shared file
        /// with no `session_id`, the rollback script, an older build — and that
        /// reading "may be perfectly live". Labelling its session stale states
        /// as fact the one thing this type explicitly cannot check.
        ///
        /// Only the earlier-window branch names a fact about time, and it is
        /// the one branch that has checked one: `isFromAnEarlierWindow` is
        /// computed from the two reset instants. Everything else says what
        /// actually happened — the reading was ignored — and leaves the reason
        /// to the tooltip, which has room for it.
        public var rowLabel: String {
            isFromAnEarlierWindow ? "Earlier window" : "Reading ignored"
        }

        /// Why the two figures differ — for the reason they actually differ.
        ///
        /// ⚠️ The popover used to state one reason unconditionally: "usage
        /// inside a window cannot go down, so the lower reading is always the
        /// older one". That is the exact axiom a re-grant falsifies, so over a
        /// re-grant refusal it explained the disagreement with a sentence the
        /// disagreement disproves. Branching is decided here rather than in the
        /// view, like `rowValue`, so the wording stays test-covered.
        ///
        /// 🔴 **Every branch claims only what this type can support.** It holds
        /// two percentages and one checked fact about the two windows — not the
        /// candidate, not its dates — so no branch may name a reason it cannot
        /// check:
        ///
        /// - The re-grant branch must NOT say the reading "predates" the
        ///   re-issue. `CaptureSelection.eligible` refuses two kinds of
        ///   candidate: one proven to predate the epoch, **and one with no
        ///   proven date at all** — the shared file with no `session_id`, the
        ///   rollback script, an older build still in someone's bundle. That
        ///   second kind may be perfectly live. Telling its owner their terminal
        ///   is showing a pre-re-grant number would be false at the exact moment
        ///   they are comparing the two. "Could not be shown to postdate it" is
        ///   the claim the filter actually makes.
        /// - ⚠️ **The overridden-from-below branch names the missing PROOF, not
        ///   the axiom** (changed 2026-09-01, with the tests that pinned the old
        ///   wording). It used to read "usage inside a window cannot go down by
        ///   consumption, so the lower reading is presumed older — an idle
        ///   session republishing what it cached". The axiom sentence is true
        ///   and it is not the reason: `best()` refuses a lower reading purely
        ///   because its date could not be shown to be later than the evidence
        ///   behind the mark. An allowance re-issue is not consumption, so a
        ///   GENUINE re-grant that happened to arrive undated lands in this
        ///   branch too — and was told, in the app's own words, that what it
        ///   reported cannot happen. The idle session stays in the copy as the
        ///   likely cause it is, never as the deduction it was.
        /// - The earlier-window branch is the one place a date is named, and it
        ///   rests on `isFromAnEarlierWindow`, which `rejection` computes from
        ///   the two reset instants. Do not fire it on direction: a rejected
        ///   reading can be higher or lower than the shown one, and a re-grant
        ///   and a rolled window look identical through the percentages alone.
        public var explanation: String {
            let said = DisplayValue.whole(reportedPercent)
            let kept = DisplayValue.whole(usingPercent)
            if isFromAnEarlierWindow {
                return """
                       Another Claude Code session reported \(said)%, but that reading is from \
                       the previous weekly window, which has already reset, so it was ignored. \
                       The \(kept)% shown is measured against the current window.
                       """
            }
            if usingPercent > reportedPercent {
                return """
                       Another Claude Code session reported \(said)%, which is lower than the \
                       \(kept)% already seen this window and could not be shown to have been \
                       taken later, so it was ignored. Usually that is an idle session \
                       republishing what it cached — but a reading whose time can be proven \
                       replaces this one whichever way it moves the figure.
                       """
            }
            return """
                   Another Claude Code session reported \(said)%, but the weekly limit was \
                   re-granted inside this window and that reading could not be shown to \
                   postdate it, so it was ignored. The \(kept)% shown is measured against the \
                   new limit.
                   """
        }
    }

    /// What the file said versus what is being shown, when the two differ.
    ///
    /// `nil` in the ordinary case — this surfaces as an exceptions-only row, per
    /// the portfolio status-chip standard.
    ///
    /// ⚠️ **Both directions, not just an override upwards.** This guard was
    /// `using > reported`, on the reasoning that only the high-water mark could
    /// ever disagree with the file and it only ever disagrees upwards. Once an
    /// allowance epoch is open, `CaptureSelection` refuses a pre-re-grant replay
    /// outright and what is shown is *lower* than what the file says — the
    /// terminal reads 51%, the app reads 7%, and one-way meant the row that
    /// exists to explain that went silent for precisely the case it was built
    /// for. Equality still reports nothing; a disagreement is a disagreement in
    /// either direction.
    ///
    /// 🔴 `onDisk` means the freshest reading *actually in a file*, so callers
    /// must pass the UNFILTERED candidate — see `CaptureSelection.resolve`,
    /// which is the only place that composition should be written. The selected
    /// capture may be a stand-in that was never on disk at all, and passing that
    /// makes both sides the same object and the answer always `nil`.
    public static func rejection(onDisk: RateLimitCapture,
                                 resolved: RateLimitCapture) -> RejectedReading? {
        let reported = onDisk.sevenDay.usedPercent
        let using = resolved.sevenDay.usedPercent
        guard using != reported else { return nil }
        // The one fact beyond the two percentages that this comparison can
        // establish, and the row is wrong without it: once the window rolls
        // under an open epoch, the freshest reading on disk can be a replay of
        // the window that just ended while the trusted one describes the new
        // one.
        //
        // 🔴 Routed through `isSameWindow` rather than spelling the tolerance
        // out a second time, so "same window" has ONE definition in this file
        // and this site cannot answer the strict/non-strict question differently
        // from `CaptureSelection.eligible`, which asks it about the same 60
        // seconds. Written as `resetsAt < other - sameWindowTolerance` the two
        // read as a `<`/`<=` mismatch that a later reader has to adjudicate —
        // and one of the two would then look like a typo. A difference of
        // exactly 60s is the SAME window at both sites; the tolerance exists
        // because the statusline reports whole epoch seconds while
        // `cachedUsageUtilization` reports microseconds, 0.58s apart.
        let earlier = !isSameWindow(onDisk.sevenDay.resetsAt, resolved.sevenDay.resetsAt)
            && onDisk.sevenDay.resetsAt < resolved.sevenDay.resetsAt
        return RejectedReading(reportedPercent: reported, usingPercent: using,
                               isFromAnEarlierWindow: earlier)
    }

    /// A re-grant: the allowance re-issued inside an unchanged window.
    ///
    /// Anthropic sometimes re-issues the weekly allowance *inside* a window
    /// without moving the reset instant, which is a second way an epoch can
    /// end besides the window itself resetting. `startedAt` is the opening
    /// reading's `provenAt` and `startPercent` is the value it opened at.
    ///
    /// 🔴 The OPTIONAL on `Mark.regrant` is the discriminator for "is a
    /// re-grant open?" — never a percentage. The observed 2026-09-01 event
    /// re-granted to 0%, identical to the ordinary window-start value, so any
    /// test of `startPercent` itself would silently disable this for exactly
    /// the case it exists for.
    public struct Regrant: Equatable, Sendable, Codable {
        public var startedAt: TimeInterval
        public var startPercent: Double

        public init(startedAt: TimeInterval, startPercent: Double) {
            self.startedAt = startedAt
            self.startPercent = startPercent
        }
    }

    /// A high-water mark for one reading, scoped to the allowance epoch it was
    /// taken in — not merely the window. An epoch ends at a window reset *or*
    /// at a re-grant; `regrant`, when set, records the latter.
    public struct Mark: Equatable, Sendable, Codable {
        public var resetsAt: TimeInterval
        public var usedPercent: Double
        public var capturedAt: TimeInterval
        /// The instant this mark's reading can be PROVEN to have been minted,
        /// carried over from `RateLimitCapture.provenAt`.
        ///
        /// 🔴 Unlike `RateLimitCapture.provenAt` — deliberately excluded from
        /// Codable because a decoded capture is never re-saved — `Mark` IS
        /// persisted every rebuild, so this MUST survive a decode or the
        /// demotion rule (Task 4) silently weakens on every app launch.
        public var provenAt: TimeInterval?
        /// Set when this epoch opened via a re-grant rather than a window
        /// reset. `nil` for an ordinary mark, including every five-hour mark
        /// — no five-hour figure is ever extrapolated, so there is nothing
        /// for an epoch to re-base there.
        public var regrant: Regrant?

        public init(resetsAt: TimeInterval, usedPercent: Double, capturedAt: TimeInterval,
                    provenAt: TimeInterval? = nil, regrant: Regrant? = nil) {
            self.resetsAt = resetsAt
            self.usedPercent = usedPercent
            self.capturedAt = capturedAt
            self.provenAt = provenAt
            self.regrant = regrant
        }
    }

    /// Bump when the *meaning* of a stored mark changes, not merely its shape.
    ///
    /// Marks written before capture dating existed hold a `capturedAt` taken
    /// straight from `Date()` — a republished reading stamped as fresh. Since a
    /// mark ties on percentage, the "equal re-confirmation takes the later date"
    /// rule then preserves that stale timestamp for the rest of the window. The
    /// only symptom is a figure that looks fresher than it is, which is exactly
    /// the class of bug this file exists to prevent.
    ///
    /// Same treatment as `ScanCache`: discard, never migrate. This is derived
    /// state and rebuilds from the next capture.
    ///
    /// v2 (2026-09-01): `Mark` gained `provenAt` and `regrant`, scoping the
    /// mark to an allowance epoch rather than only a window. A v1 file has
    /// neither field and no way to earn them retroactively — discard rather
    /// than migrate, same as the v1 bump above.
    public static let currentVersion = 2

    public var version: Int
    public var sevenDay: Mark?
    public var fiveHour: Mark?

    public init(version: Int = RateLimitHighWater.currentVersion,
                sevenDay: Mark? = nil, fiveHour: Mark? = nil) {
        self.version = version
        self.sevenDay = sevenDay
        self.fiveHour = fiveHour
    }

    public var isCompatible: Bool { version == Self.currentVersion }

    public static let empty = RateLimitHighWater()

    /// Returns the capture to trust, and the mark to persist.
    ///
    /// The seven-day and five-hour readings carry independent reset instants and
    /// are reconciled separately — a five-hour window rolls several times inside
    /// one weekly window, so one says nothing about the other.
    public static func reconcile(_ capture: RateLimitCapture,
                                 against highWater: RateLimitHighWater)
    -> (capture: RateLimitCapture, highWater: RateLimitHighWater) {

        let (sevenDay, sevenMark) = best(capture.sevenDay,
                                         capturedAt: capture.capturedAt,
                                         provenAt: capture.provenAt,
                                         against: highWater.sevenDay,
                                         opensEpochs: true)

        var fiveHour: RateLimitCapture.Reading?
        var fiveMark: Mark?
        if let reading = capture.fiveHour {
            let (resolved, mark) = best(reading, capturedAt: capture.capturedAt,
                                        provenAt: capture.provenAt,
                                        against: highWater.fiveHour,
                                        opensEpochs: false)
            fiveHour = resolved
            fiveMark = mark
        }
        // A capture with no five-hour block must not resurrect an earlier one:
        // the plan may simply not report it.

        // The seven-day reading is the one the headline figure comes from, so it
        // owns the capture's age. Reporting a rejected reading's timestamp would
        // present a stale number as having just landed.
        let resolved = RateLimitCapture(version: capture.version,
                                        capturedAt: sevenMark.capturedAt,
                                        sevenDay: sevenDay,
                                        fiveHour: fiveHour)

        return (resolved, RateLimitHighWater(sevenDay: sevenMark, fiveHour: fiveMark))
    }

    /// Equal counts as fresh: re-reporting the same percentage is a new
    /// confirmation of it, so the age moves even though the value doesn't — but
    /// only ever *forwards*. Timestamps stopped being monotonic once a
    /// republished payload started being dated by its own expired five-hour
    /// window (see `RateLimitCapture.correctedForRepublishing`), so a replay of
    /// a value already confirmed more recently must not pull the age backwards.
    ///
    /// A strictly *higher* reading keeps its own date even when that date is
    /// older, because it is new information and the figure is only as fresh as
    /// the moment it was actually learned.
    /// Two sources describe the same window to different precision: the
    /// statusline reports whole epoch seconds (`1786690800`), while
    /// `cachedUsageUtilization` reports `2026-08-14T06:59:59.424563+00:00` — the
    /// same instant, 0.58s earlier. Found against real data 2026-08-12.
    ///
    /// Exact equality would treat those as different windows, so each source
    /// would keep its own mark and the protection would silently degrade
    /// whenever they alternate. Real windows are five hours or seven days apart,
    /// so a minute of tolerance cannot merge two of them.
    static let sameWindowTolerance: TimeInterval = 60

    private static func isSameWindow(_ a: TimeInterval, _ b: TimeInterval) -> Bool {
        abs(a - b) <= sameWindowTolerance
    }

    /// How far a reading must fall, in percentage points, before the drop is
    /// read as a re-grant rather than as noise.
    ///
    /// "The mark is falsifiable" and "a re-grant happened" are different claims
    /// and are decided separately. A 51 → 50 flicker is far more likely a
    /// rounding difference between two sources than a re-issued allowance, and
    /// a spuriously opened epoch corrupts the extrapolation denominator — it
    /// divides by a tiny `(unitsAtCapture − unitsAtEpochStart)`. So any
    /// qualifying lower reading is still ACCEPTED; only the epoch is withheld.
    ///
    /// A property of the data source rather than a preference, so it is a
    /// constant and not a setting.
    public static let materialDropPoints: Double = 2

    /// The later of two proofs, where either may be absent.
    ///
    /// 🔴 An absent incoming proof leaves the existing one alone. `capturedAt`
    /// moves on any equal-or-higher confirmation; `provenAt` moves only on
    /// evidence. Letting an undated replayer creep this forward would let it
    /// outrun a frozen proven date indefinitely, which silently restores the
    /// bug this whole rule exists to fix.
    private static func laterProof(_ existing: TimeInterval?,
                                   _ incoming: TimeInterval?) -> TimeInterval? {
        guard let incoming else { return existing }
        guard let existing else { return incoming }
        return max(existing, incoming)
    }

    /// - Parameter opensEpochs: whether a material drop here may open a
    ///   `Regrant`. False for the five-hour reading: no five-hour figure is
    ///   ever extrapolated, so there is nothing for an epoch to re-base, and a
    ///   populated field would be read by consumers that only ever mean the
    ///   weekly window. The demotion rule itself still applies to both.
    private static func best(_ reading: RateLimitCapture.Reading,
                             capturedAt: TimeInterval,
                             provenAt: TimeInterval?,
                             against mark: Mark?,
                             opensEpochs: Bool) -> (RateLimitCapture.Reading, Mark) {
        guard let mark, isSameWindow(mark.resetsAt, reading.resetsAt) else {
            return (reading, Mark(resetsAt: reading.resetsAt,
                                  usedPercent: reading.usedPercent,
                                  capturedAt: capturedAt,
                                  provenAt: provenAt))
        }

        if reading.usedPercent < mark.usedPercent {
            // The demotion basis: the latest instant the mark's reading is
            // known to have been current. A mark with no proof falls back to
            // `capturedAt`, an UPPER bound on when it was minted — so an
            // unproven mark is HARDER to demote, never easier. A reading with
            // no proof of its own cannot demote at all.
            //
            // 🔴 Binding `provenAt` here rather than testing `?? -.infinity`
            // is load-bearing below — but only HALF of it is enforced by the
            // compiler, and the difference matters to anyone editing this.
            //
            // Structural: revert this to the optional form and
            // `Regrant(startedAt: provenAt` stops compiling, so the `??`
            // fallback cannot come back without a visible decision at the
            // construction site. "Only a proven reading can open an epoch" is
            // therefore a fact about the types.
            //
            // NOT structural: `capturedAt` is a sibling parameter of the same
            // type, so `startedAt: capturedAt` compiles silently while writing
            // an INFERRED date as a proven one. Nothing but
            // `theEpochStartsAtTheOpeningReadingsProvenDateNotItsCapturedAt`
            // and `aMaterialDropInsideAnOpenEpochRebasesIt` stands between
            // that edit and a corrupted extrapolation denominator.
            let basis = mark.provenAt ?? mark.capturedAt
            guard let provenAt, provenAt > basis else {
                return (RateLimitCapture.Reading(usedPercent: mark.usedPercent,
                                                 resetsAt: mark.resetsAt),
                        mark)
            }
            // Proven to have been minted after everything backing the mark, so
            // it is a correction rather than a replay. `provenAt` is already
            // later than the mark's, by the guard above.
            let isMaterial = mark.usedPercent - reading.usedPercent >= materialDropPoints

            // A material drop means the allowance was re-issued, so an epoch
            // opens — dated by the instant this reading was PROVEN minted,
            // never detection wall-clock and never `capturedAt`. Both wrong
            // answers put the epoch start AFTER the reading that opened it,
            // which makes the opening capture instantly ineligible under the
            // selection rule and measures `unitsAtEpochStart` at the wrong
            // instant.
            //
            // 🔴 A material drop inside an ALREADY-OPEN epoch REPLACES the
            // `Regrant` wholesale rather than keeping the first one. An epoch
            // ends at a window reset *or* at a re-grant, and a second re-grant
            // is the second of those. Do not "fix" this by adding
            // `mark.regrant == nil &&` — on 51 → 0, a climb to 20, then 0
            // again, keeping the first epoch leaves `unitsAtEpochStart` stale
            // by the whole first epoch's consumption, which is the same
            // denominator error this feature exists to fix, one level down.
            // Task 8's extrapolation depends on this; only
            // `aMaterialDropInsideAnOpenEpochRebasesIt` pins it.
            //
            // Below the threshold the value still comes down and only the
            // epoch is withheld — any epoch already open is carried unchanged.
            let regrant: Regrant? = opensEpochs && isMaterial
                ? Regrant(startedAt: provenAt, startPercent: reading.usedPercent)
                : mark.regrant

            return (reading, Mark(resetsAt: reading.resetsAt,
                                  usedPercent: reading.usedPercent,
                                  capturedAt: capturedAt,
                                  provenAt: provenAt,
                                  regrant: regrant))
        }

        let confirmedAt = reading.usedPercent == mark.usedPercent
            ? max(capturedAt, mark.capturedAt)
            : capturedAt
        // `provenAt` is evidence about the value the mark HOLDS. An equal
        // reading re-confirms that same value, so the two proofs describe one
        // thing and the later one wins. A higher reading replaces the value, so
        // the evidence for it is that reading's own — or none. Carrying the old
        // proof forward instead would block a genuinely newer proof using
        // evidence about a value the mark no longer holds.
        //
        // 🔴 Deliberately NOT clamped up to `mark.capturedAt` when the mark is
        // unproven. A clamp would make such a mark harder to demote, but
        // `Mark.provenAt` is PERSISTED, is reconstituted into a stand-in
        // capture, and is printed by the probe — so a clamped value is a
        // fabricated proof written to disk. It would also make the result
        // order-dependent. Honest and defeasible beats conservative and false.
        let confirmedProof = reading.usedPercent == mark.usedPercent
            ? laterProof(mark.provenAt, provenAt)
            : provenAt
        return (reading, Mark(resetsAt: reading.resetsAt,
                              usedPercent: reading.usedPercent,
                              capturedAt: confirmedAt,
                              provenAt: confirmedProof,
                              regrant: mark.regrant))
    }
}

public struct HighWaterStore: Sendable {
    private let url: URL

    public init(directory: URL = ApplicationSupport.directory()) {
        url = directory.appendingPathComponent("rate-limit-highwater.json")
    }

    /// A mark with no version, or a version this build doesn't know, is
    /// discarded. A pre-versioning file has no `version` key at all, so the
    /// decode itself fails — which is the intended migration, not an accident.
    public func load() -> RateLimitHighWater {
        guard let data = try? Data(contentsOf: url),
              let mark = try? JSONDecoder().decode(RateLimitHighWater.self, from: data),
              mark.isCompatible
        else { return .empty }
        return mark
    }

    public func save(_ mark: RateLimitHighWater) throws {
        try JSONEncoder().encode(mark).write(to: url, options: .atomic)
    }
}
