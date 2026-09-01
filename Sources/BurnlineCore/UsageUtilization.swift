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

    /// The per-model weekly limit — `kind: "weekly_scoped"`.
    public struct ScopedLimit: Equatable, Sendable {
        public let percent: Double
        public let severity: String
        public let modelName: String

        /// Assembled here like `FiveHourStatus.rowValue`, so no view body does
        /// formatting of its own.
        public var rowValue: String { "\(DisplayValue.whole(percent))%" }
    }

    public let fetchedAt: TimeInterval
    public let accountUuid: String?
    public let sevenDay: Reading?
    public let fiveHour: Reading?
    public let scopedWeekly: ScopedLimit?

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
    }

    /// Every property decoded independently. Most sibling keys are `null` today
    /// (`seven_day_opus`, `tangelo`, `cinder_cove`, …) and are presumably
    /// populated on other plans — one unknown shape must never cost the readings
    /// that did decode.
    private struct Block: Decodable {
        var sevenDay: Reading?
        var fiveHour: Reading?
        var scopedWeekly: ScopedLimit?

        enum CodingKeys: String, CodingKey {
            case sevenDay = "seven_day"
            case fiveHour = "five_hour"
            case limits
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sevenDay = ((try? c.decodeIfPresent(RawReading.self, forKey: .sevenDay)) ?? nil)?.resolved
            fiveHour = ((try? c.decodeIfPresent(RawReading.self, forKey: .fiveHour)) ?? nil)?.resolved
            let limits = ((try? c.decodeIfPresent([RawLimit].self, forKey: .limits)) ?? nil) ?? []
            scopedWeekly = limits.first { $0.kind == "weekly_scoped" }?.resolvedScoped
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

        enum CodingKeys: String, CodingKey { case kind, percent, severity, scope }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
            percent = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? nil
            severity = (try? c.decodeIfPresent(String.self, forKey: .severity)) ?? nil
            scope = (try? c.decodeIfPresent(Scope.self, forKey: .scope)) ?? nil
        }

        /// A scoped limit without a model name says nothing a user could read.
        var resolvedScoped: ScopedLimit? {
            guard let percent, let name = scope?.model?.displayName else { return nil }
            return ScopedLimit(percent: percent, severity: severity ?? "normal", modelName: name)
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
    /// flows through `CaptureSelector.freshest` and `RateLimitHighWater` with no
    /// changes to either.
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
