import Foundation

/// The `cachedUsageUtilization` block Claude Code keeps in `~/.claude.json`.
///
/// A second source of true subscription usage, and in three ways a better one
/// than the statusline payload:
///
/// 1. **`fetchedAtMs` is an explicit fetch timestamp.** Every dating heuristic in
///    this project — `correctedForRepublishing`, `TranscriptDating` — exists only
///    because the statusline payload carries no timestamp. This one does.
/// 2. It exposes the **per-model weekly limit** (`weekly_scoped`), which the
///    statusline payload omits entirely.
/// 3. It carries Anthropic's own **severity** grading rather than a threshold
///    this app invents.
///
/// **It is a peer, never a replacement.** It is an undocumented internal field
/// that can change shape or vanish in any Claude Code release, and it does not
/// self-refresh — measured frozen for 5+ minutes during continuous desktop-app
/// use, and refreshed by `/usage`. The statusline path is documented, free, and
/// automatic while working in a terminal. The two compete on age; fresher wins.
///
/// ⚠️ **`~/.claude.json` also holds hundreds of project paths** — for consultancy
/// work, client names. Only this block is ever read, and the raw file is never
/// copied, logged, or included in diagnostics.
public struct UsageUtilization: Sendable, Decodable {

    /// One window's reading. Constructed only with a reset instant: a percentage
    /// whose window boundary is unknown can never be judged still-valid, so it
    /// is worse than no reading — the same rule `StatuslinePayload` applies.
    public struct Reading: Equatable, Sendable {
        public let percent: Double
        public let resetsAt: Date
    }

    /// Anthropic's own start of the weekly window, paired with the reset it
    /// was reported beside: `seven_day_breakdown.window_started_at` and the
    /// weekly reading's `resets_at`, from the same fetch. Checked against the
    /// 168-hour rule by `SnapshotBuilder`; see `Snapshot.WindowStartCheck`.
    public struct ReportedWindowStart: Equatable, Sendable {
        public let startedAt: Date
        public let resetsAt: Date

        public init(startedAt: Date, resetsAt: Date) {
            self.startedAt = startedAt
            self.resetsAt = resetsAt
        }
    }

    /// The per-model weekly limit — `kind: "weekly_scoped"`.
    public struct ScopedLimit: Equatable, Sendable {
        public let percent: Double
        public let severity: String
        public let modelName: String
        /// This limit's own `resets_at`. Nil when the entry carried none, in
        /// which case nothing can place it in a window and it never notifies.
        public let resetsAt: Date?

        public init(percent: Double, severity: String, modelName: String, resetsAt: Date?) {
            self.percent = percent
            self.severity = severity
            self.modelName = modelName
            self.resetsAt = resetsAt
        }

        /// How the popover draws the row, from Anthropic's own grading.
        ///
        /// 🔴 **Why the row is graded at all.** On 2026-11-26 this limit
        /// (Fable) stood at 94% graded `critical` while the all-models figure
        /// Burnline tracks read 74% `normal`. The limit about to stop work was
        /// a grey row among grey rows.
        public enum Style: Equatable, Sendable {
            case plain
            /// Amber with a symbol.
            case warning
            /// Red with a symbol.
            case critical
        }

        /// The same rule as extra usage: anything but `normal` is raised, so a
        /// grade this build has never seen still draws attention. `critical`
        /// is the one grade drawn above a warning.
        public var rowStyle: Style {
            switch gradeWord {
            case nil: .plain
            case "critical": .critical
            default: .warning
            }
        }

        /// Anthropic's grade, lowercased, or nil when it is `normal` or blank.
        var gradeWord: String? {
            let word = severity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return word.isEmpty || word == "normal" ? nil : word
        }

        /// Assembled here like `FiveHourStatus.rowValue`, so no view body does
        /// formatting of its own. A raised grade is named in the value, because
        /// status is never colour alone.
        public var rowValue: String {
            let figure = "\(DisplayValue.whole(percent))%"
            return gradeWord.map { "\(figure) · \($0)" } ?? figure
        }

        /// The row's tooltip: what this limit is and why it can stop work
        /// while the weekly figure still has room.
        public var rowHelp: String {
            let grade = gradeWord.map { "Anthropic grades this limit \($0). " } ?? ""
            return grade + "This is \(modelName)'s own weekly limit, separate from the "
                + "all-models figure above: \(modelName) stops at its own limit even "
                + "while the weekly figure has room."
        }

        /// The popover row's label.
        ///
        /// The model name alone was the label, sitting in a column of rows
        /// whose labels name a *period* — `Day`, `Resets`, `Time left`,
        /// `5-hour` — so a bare `Opus` read as a heading rather than as a
        /// limit, and the row said nothing about which limit or over what
        /// span. The period is the missing word.
        public var rowLabel: String { "\(modelName) weekly" }
    }

    public let fetchedAt: TimeInterval
    public let accountUuid: String?
    public let sevenDay: Reading?
    public let fiveHour: Reading?
    public let scopedWeekly: ScopedLimit?
    /// `nil` when the field is absent or malformed, or when there is no weekly
    /// reading to pair it with. Absent changes nothing.
    public let weeklyWindowStart: ReportedWindowStart?
    /// Extra usage, when it is on or paused by Anthropic. See `ExtraUsage`.
    public let extraUsage: ExtraUsage?
    /// `oauthAccount.organizationRateLimitTier`, set by `UtilizationStore` —
    /// not by this decoder, because it lives outside this block. The one string
    /// read from `oauthAccount`; see `UtilizationStore`.
    public internal(set) var rateLimitTier: String?

    // MARK: - Decoding

    enum CodingKeys: String, CodingKey {
        case fetchedAtMs
        case accountUuid
        case utilization
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Milliseconds in the file; seconds everywhere in this codebase.
        let ms = (try? c.decodeIfPresent(Double.self, forKey: .fetchedAtMs)) ?? nil
        fetchedAt = (ms ?? 0) / 1000
        accountUuid = (try? c.decodeIfPresent(String.self, forKey: .accountUuid)) ?? nil

        let block = (try? c.decodeIfPresent(Block.self, forKey: .utilization)) ?? nil
        sevenDay = block?.sevenDay
        fiveHour = block?.fiveHour
        scopedWeekly = block?.scopedWeekly
        weeklyWindowStart = block?.sevenDay.flatMap { reading in
            UsageUtilization.date(from: block?.windowStartedAt).map {
                ReportedWindowStart(startedAt: $0, resetsAt: reading.resetsAt)
            }
        }
        extraUsage = ExtraUsage.resolve(spend: block?.spend, extra: block?.extraUsage,
                                        fetchedAt: fetchedAt)
        rateLimitTier = nil
    }

    /// Every property decoded independently. Most sibling keys are `null` today
    /// (`seven_day_opus`, `tangelo`, `cinder_cove`, …) and are presumably
    /// populated on other plans — one unknown shape must never cost the readings
    /// that did decode. `spend` and `extra_usage` carry extra usage — see
    /// `ExtraUsage`.
    private struct Block: Decodable {
        var sevenDay: Reading?
        var fiveHour: Reading?
        var scopedWeekly: ScopedLimit?
        var spend: ExtraUsage.RawSpend?
        var extraUsage: ExtraUsage.RawExtraUsage?
        /// `seven_day_breakdown.window_started_at`, unparsed.
        var windowStartedAt: String?

        enum CodingKeys: String, CodingKey {
            case sevenDay = "seven_day"
            case breakdown = "seven_day_breakdown"
            case fiveHour = "five_hour"
            case limits
            case spend
            case extraUsage = "extra_usage"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let limits = ((try? c.decodeIfPresent([RawLimit].self, forKey: .limits)) ?? nil) ?? []
            // 🔴 `seven_day` first, then the `weekly_all` entry in `limits`,
            // which carries the same account-wide figure. About thirty of
            // `seven_day`'s siblings were already null on 2026-11-21; if it
            // follows them and nothing else is read, every user drops to
            // pace-only with no error. Only `weekly_all` may stand in: a
            // session limit or a per-model one is a different quantity.
            sevenDay = ((try? c.decodeIfPresent(RawReading.self, forKey: .sevenDay)) ?? nil)?.resolved
                ?? limits.first { $0.kind == "weekly_all" }?.resolvedReading
            fiveHour = ((try? c.decodeIfPresent(RawReading.self, forKey: .fiveHour)) ?? nil)?.resolved
            scopedWeekly = limits.first { $0.kind == "weekly_scoped" }?.resolvedScoped
            spend = (try? c.decodeIfPresent(ExtraUsage.RawSpend.self, forKey: .spend)) ?? nil
            extraUsage = (try? c.decodeIfPresent(ExtraUsage.RawExtraUsage.self, forKey: .extraUsage)) ?? nil
            windowStartedAt = ((try? c.decodeIfPresent(RawBreakdown.self, forKey: .breakdown)) ?? nil)?
                .windowStartedAt
        }
    }

    /// Only the start is read. `rows` splits the figure by surface (Claude
    /// Code, chats, …) and is not used.
    private struct RawBreakdown: Decodable {
        var windowStartedAt: String?
        enum CodingKeys: String, CodingKey { case windowStartedAt = "window_started_at" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            windowStartedAt = (try? c.decodeIfPresent(String.self, forKey: .windowStartedAt)) ?? nil
        }
    }

    private struct RawReading: Decodable {
        var utilization: Double?
        var resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            utilization = (try? c.decodeIfPresent(Double.self, forKey: .utilization)) ?? nil
            resetsAt = (try? c.decodeIfPresent(String.self, forKey: .resetsAt)) ?? nil
        }

        /// `nil` unless both halves are present and the instant parses.
        /// `nimbus_quill` ships today as a percentage with `resets_at: null`.
        var resolved: Reading? {
            guard let utilization, let date = UsageUtilization.date(from: resetsAt) else { return nil }
            return Reading(percent: utilization, resetsAt: date)
        }
    }

    private struct RawLimit: Decodable {
        var kind: String?
        var percent: Double?
        var severity: String?
        var resetsAt: String?
        var scope: Scope?

        struct Scope: Decodable {
            var model: Model?
            struct Model: Decodable {
                var displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
                init(from decoder: any Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
                }
            }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                model = (try? c.decodeIfPresent(Model.self, forKey: .model)) ?? nil
            }
            enum CodingKeys: String, CodingKey { case model }
        }

        enum CodingKeys: String, CodingKey {
            case kind, percent, severity, scope
            case resetsAt = "resets_at"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
            percent = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? nil
            severity = (try? c.decodeIfPresent(String.self, forKey: .severity)) ?? nil
            resetsAt = (try? c.decodeIfPresent(String.self, forKey: .resetsAt)) ?? nil
            scope = (try? c.decodeIfPresent(Scope.self, forKey: .scope)) ?? nil
        }

        /// A scoped limit without a model name says nothing a user could read.
        /// This entry as a window reading. Like `RawReading.resolved`, a
        /// percentage with no reset instant cannot be placed in a window and
        /// is dropped.
        var resolvedReading: Reading? {
            guard let percent, let date = UsageUtilization.date(from: resetsAt) else { return nil }
            return Reading(percent: percent, resetsAt: date)
        }

        var resolvedScoped: ScopedLimit? {
            guard let percent, let name = scope?.model?.displayName else { return nil }
            return ScopedLimit(percent: percent, severity: severity ?? "normal", modelName: name,
                               resetsAt: UsageUtilization.date(from: resetsAt))
        }
    }

    /// ⚠️ **Two formatters, and both are required.** `resets_at` carries **six**
    /// fractional digits (`…:00.818653+00:00`), which only parses with
    /// `.withFractionalSeconds`; a bare `…Z` form only parses *without* it.
    /// Verified in Swift before this was written. A single formatter silently
    /// returns `nil` and the entire source goes dark with no error anywhere.
    ///
    /// Built per call rather than shared: `ISO8601DateFormatter` is not
    /// `Sendable`, and this decode is gated on the file changing.
    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    // MARK: - Into the existing pipeline

    /// The same `RateLimitCapture` shape the statusline produces, so this source
    /// flows through `CaptureLoader`, `CaptureSelection.resolve` and
    /// `RateLimitHighWater` with no changes to any of them.
    ///
    /// **`sessionId` and `transcriptPath` stay `nil` deliberately.** No session
    /// produced this reading, and `fetchedAt` is already exact — dating it from
    /// a transcript would replace a true timestamp with a guess.
    ///
    /// **`provenAt` is set to `fetchedAt`.** Not why this source is worth
    /// reading at all — the header above already gives three independent
    /// reasons, most of which have nothing to do with dating. This is
    /// narrower: it's what makes this source trustworthy enough to demote a
    /// high-water mark, rather than only an inferred upper bound — see
    /// `RateLimitCapture.provenAt`.
    public func asCapture() -> RateLimitCapture? {
        guard let sevenDay else { return nil }
        var capture = RateLimitCapture(
            version: RateLimitCapture.currentVersion,
            capturedAt: fetchedAt,
            sevenDay: .init(usedPercent: sevenDay.percent,
                            resetsAt: sevenDay.resetsAt.timeIntervalSince1970),
            fiveHour: fiveHour.map {
                .init(usedPercent: $0.percent, resetsAt: $0.resetsAt.timeIntervalSince1970)
            },
            sessionId: nil,
            transcriptPath: nil)
        capture.provenAt = fetchedAt
        return capture
    }
}
