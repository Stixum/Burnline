import Foundation

/// One archived cell. `bucket` is the bucket START in epoch SECONDS — not the
/// quarter-hour index `Bucket.key(for:)` returns. Coverage uses the same units;
/// mixed, a containment check silently never matches.
public struct HistoryRow: Equatable, Sendable, Codable {
    public var bucket: Int
    public var project: String
    public var model: String
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int

    public init(bucket: Int, project: String, model: String, counts: TokenCounts) {
        self.bucket = bucket
        self.project = project
        self.model = model
        self.input = counts.input
        self.output = counts.output
        self.cacheWrite = counts.cacheWrite
        self.cacheRead = counts.cacheRead
    }

    public var counts: TokenCounts {
        TokenCounts(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
    }

    /// The dedupe identity. Deliberately has NO file component: rows are summed
    /// across transcript files before they are written.
    public struct Key: Hashable, Sendable {
        public let bucket: Int
        public let project: String
        public let model: String

        public init(bucket: Int, project: String, model: String) {
            self.bucket = bucket
            self.project = project
            self.model = model
        }
    }

    public var key: Key { Key(bucket: bucket, project: project, model: model) }
}

/// Where a window row's bounds came from. Three genuinely different levels of
/// confidence — collapsing `observed` and `extrapolated` overstates provenance.
public enum BoundsSource: String, Equatable, Sendable, Codable {
    /// This window's own reset was seen while it was live. Ground truth.
    case observed
    /// Rolled back from a later observed reset. Correct unless the anchor moved.
    case extrapolated
    /// No capture has ever been seen on this machine.
    case schedule
}

public struct WindowRow: Equatable, Sendable, Codable {
    public var start: Date
    public var end: Date
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    /// Anthropic's own figure, or nil. Never an estimate, never a calibration.
    public var finalPercent: Double?
    public var finalPercentAt: Date?
    public var finalPercentSource: String?
    public var boundsSource: BoundsSource
    public var observedResetsAt: Date?

    /// A re-grant seen inside one archived window: when it was first
    /// observed, at what reading, and how many the window held.
    ///
    /// One value rather than three fields, because the three are only ever
    /// meaningful together — see `regrant`.
    public struct RegrantAnnotation: Equatable, Sendable, Codable {
        /// The first OBSERVATION after the allowance was re-granted.
        ///
        /// 🔴 **Not the re-grant itself, which is unrecoverable.** On the live
        /// 2026-09-01 event the readings either side were 51% and 3%,
        /// ninety-seven minutes apart; the re-grant happened somewhere inside
        /// that gap and nothing recorded where. This is the earliest instant it
        /// is known to have ALREADY happened, and it can only ever be late.
        ///
        /// ⚠️ Whole seconds, and it arrives that way. `tracking.json` is
        /// written through `.iso8601`, and `writeCompletedWindows` loads it
        /// back from disk — so every `at` the ledger sees has already been
        /// truncated, and nothing is lost again on the way into this row.
        /// Anything matching this against another instant still wants
        /// `WindowLedger.sameResetTolerance` rather than equality.
        public var at: Date
        /// The reading at `at` — **the first figure seen after the re-grant,
        /// not zero.** The live event's was 3%: the reporting gap had already
        /// been burned through by the time anything reported again.
        public var percent: Double
        /// How many re-grants were observed in this window — at least 1.
        ///
        /// 🔴 Present so the row never claims there was exactly one. `at` and
        /// `percent` describe the LAST of them, because `finalPercent` is the
        /// climb since that one and only the last pairs with it to describe a
        /// single stretch of the week. Without this count a two-re-grant week
        /// would read as a one-re-grant week, and a window row is written once.
        ///
        /// "Observed" is the honest word: a re-grant whose next reading still
        /// landed above the previous one leaves no drop to see, and this
        /// archive labels what it knows rather than what it assumes — the same
        /// rule as `CoverageRecord.truncated` and `verified`.
        public var observed: Int

        public init(at: Date, percent: Double, observed: Int) {
            self.at = at
            self.percent = percent
            self.observed = observed
        }
    }

    /// Set only when this window's readings show the allowance being re-granted
    /// mid-window — Anthropic re-issuing it without moving `resets_at`.
    ///
    /// 🔴 **The optional IS the discriminator**, the idiom
    /// `RateLimitHighWater.Mark.regrant` and `Snapshot.regrant` already use.
    /// Three independent optionals were the first shape here, and they could
    /// spell `observed: 2` with no instant: `windows.jsonl` is append-only and
    /// `decodeLines` keeps any line that decodes, so an invariant enforced only
    /// at the one construction site is an invariant the ARCHIVE does not have.
    /// Nested, a half-written annotation cannot be written down at all.
    ///
    /// Absent from every row written before this existed, and absent from every
    /// ordinary week after it — an absent key decodes to nil, so old rows load
    /// unchanged and nothing grows a key it has nothing to say with.
    public var regrant: RegrantAnnotation?

    public init(start: Date, end: Date, counts: TokenCounts, finalPercent: Double?,
                finalPercentAt: Date?, finalPercentSource: String?,
                boundsSource: BoundsSource, observedResetsAt: Date?,
                regrant: RegrantAnnotation? = nil) {
        self.start = start
        self.end = end
        self.input = counts.input
        self.output = counts.output
        self.cacheWrite = counts.cacheWrite
        self.cacheRead = counts.cacheRead
        self.finalPercent = finalPercent
        self.finalPercentAt = finalPercentAt
        self.finalPercentSource = finalPercentSource
        self.boundsSource = boundsSource
        self.observedResetsAt = observedResetsAt
        self.regrant = regrant
    }

    public var counts: TokenCounts {
        TokenCounts(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
    }
}

/// A range of buckets known to be archived. Bucket-start epoch seconds,
/// inclusive of both ends.
public struct CoverageRecord: Equatable, Sendable, Codable {
    public var from: Int
    public var through: Int
    public var filledBy: String
    /// The fill could not reach `from` because transcripts were already
    /// deleted. This is what makes a permanent gap *knowable* rather than
    /// merely absent.
    public var truncated: Bool
    /// False when this range was reconstructed after `coverage.jsonl` was lost.
    /// Such a range cannot distinguish a gap from an idle week.
    public var verified: Bool

    public init(from: Int, through: Int, filledBy: String,
                truncated: Bool = false, verified: Bool = true) {
        self.from = from
        self.through = through
        self.filledBy = filledBy
        self.truncated = truncated
        self.verified = verified
    }

    private enum CodingKeys: String, CodingKey {
        case from, through, filledBy, truncated, verified
    }

    // Absent `truncated`/`verified`/`filledBy` decode to sensible defaults
    // rather than throwing — old or hand-edited rows must still load.
    //
    // ⚠️ Absent `filledBy` is "unknown", never "scan". A record whose
    // provenance was not recorded did not thereby come from the forward flush,
    // and this design labels what it knows rather than assuming the common
    // case — the same rule as `boundsSource`, `verified` and `truncated`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(Int.self, forKey: .from)
        through = try container.decode(Int.self, forKey: .through)
        filledBy = try container.decodeIfPresent(String.self, forKey: .filledBy) ?? "unknown"
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? true
    }
}

/// A capture observation. Matched to a window later by CONTAINMENT of `at` —
/// never by comparing window starts.
public struct TrackingEntry: Equatable, Sendable, Codable {
    public var percent: Double
    public var at: Date
    public var resetsAt: Date

    public init(percent: Double, at: Date, resetsAt: Date) {
        self.percent = percent
        self.at = at
        self.resetsAt = resetsAt
    }
}

public struct TrackingFile: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var entries: [TrackingEntry]

    public init(version: Int = TrackingFile.currentVersion, entries: [TrackingEntry] = []) {
        self.version = version
        self.entries = entries
    }

    public var isCompatible: Bool { version == Self.currentVersion }
}

public struct HistoryManifest: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int
    /// The anchor past window bounds roll back from. Never cleared by a nil
    /// observation.
    public var lastObservedReset: Date?

    public init(version: Int = HistoryManifest.currentVersion, lastObservedReset: Date? = nil) {
        self.version = version
        self.lastObservedReset = lastObservedReset
    }

    public var isCompatible: Bool { version == Self.currentVersion }
}
