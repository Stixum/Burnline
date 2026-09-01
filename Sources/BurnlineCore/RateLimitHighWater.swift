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

        public init(reportedPercent: Double, usingPercent: Double) {
            self.reportedPercent = reportedPercent
            self.usingPercent = usingPercent
        }

        /// Assembled here, like `FiveHourStatus.rowValue`, so no view body does
        /// formatting of its own.
        public var rowValue: String {
            "said \(DisplayValue.whole(reportedPercent))%, kept \(DisplayValue.whole(usingPercent))%"
        }
    }

    /// What the file said versus what is being shown, when the two differ.
    ///
    /// `nil` in the ordinary case — this surfaces as an exceptions-only row, per
    /// the portfolio status-chip standard.
    public static func rejection(onDisk: RateLimitCapture,
                                 resolved: RateLimitCapture) -> RejectedReading? {
        let reported = onDisk.sevenDay.usedPercent
        let using = resolved.sevenDay.usedPercent
        guard using > reported else { return nil }
        return RejectedReading(reportedPercent: reported, usingPercent: using)
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
                                         against: highWater.sevenDay)

        var fiveHour: RateLimitCapture.Reading?
        var fiveMark: Mark?
        if let reading = capture.fiveHour {
            let (resolved, mark) = best(reading, capturedAt: capture.capturedAt,
                                        provenAt: capture.provenAt,
                                        against: highWater.fiveHour)
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

    private static func best(_ reading: RateLimitCapture.Reading,
                             capturedAt: TimeInterval,
                             provenAt: TimeInterval?,
                             against mark: Mark?) -> (RateLimitCapture.Reading, Mark) {
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
            let basis = mark.provenAt ?? mark.capturedAt
            guard (provenAt ?? -.infinity) > basis else {
                return (RateLimitCapture.Reading(usedPercent: mark.usedPercent,
                                                 resetsAt: mark.resetsAt),
                        mark)
            }
            // Proven to have been minted after everything backing the mark, so
            // it is a correction rather than a replay. `provenAt` is already
            // later than the mark's, by the guard above.
            return (reading, Mark(resetsAt: reading.resetsAt,
                                  usedPercent: reading.usedPercent,
                                  capturedAt: capturedAt,
                                  provenAt: provenAt,
                                  regrant: mark.regrant))
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
