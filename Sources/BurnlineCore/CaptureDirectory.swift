import Foundation

public enum CaptureDirectoryError: Error, Equatable {
    /// No session id, so there is nothing to key a file on. The caller falls
    /// back to the shared `rate-limits.json`.
    case noSessionId
    /// A session id that would not survive being used as a filename.
    case unsafeSessionId(String)
}

/// `captures/<session_id>.json`, one file per Claude Code session.
///
/// **Why not one shared file.** Every session that renders a status line writes
/// on its own 30-second timer, blind to the others. With a single file the last
/// writer wins, and "last" has nothing to do with "freshest": two terminal
/// sessions, one active and one idle, and the idle one overwrites the active
/// one's reading twice a minute.
///
/// `RateLimitHighWater` keeps the correct *value* through that — a lower reading
/// is presumed staler.
///
/// ⚠️ That sentence read "usage inside a window is cumulative, so a lower
/// reading is always staler" until 2026-09-01, when Anthropic re-issued the
/// weekly allowance mid-window and the true figure went 51% → 0%. The
/// presumption is defeasible, and `RateLimitHighWater`'s header carries the
/// correction in full. It still holds against the idle session this file is
/// about, which is why the reasoning is kept rather than deleted.
///
/// What the mark cannot fix is the **age**: dating would pin to the idle
/// session's last turn and fire a "nothing is reporting" nudge while something
/// very much is.
///
/// A file per session removes the contention rather than defending against it.
/// Nothing is lost, so nothing needs arbitrating — only choosing, at read time.
public struct CaptureDirectory: Sendable {
    private let root: URL

    public init(directory: URL = ApplicationSupport.directory()) {
        root = directory.appendingPathComponent("captures", isDirectory: true)
    }

    /// Session ids are UUIDs in practice. Anything else is refused rather than
    /// sanitised: a path separator would write outside the directory, and a
    /// quietly-rewritten id could never be correlated back to its transcript.
    private static func isSafe(_ sessionId: String) -> Bool {
        !sessionId.isEmpty
            && sessionId.count <= 128
            && sessionId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    public func save(_ capture: RateLimitCapture) throws {
        guard let sessionId = capture.sessionId else { throw CaptureDirectoryError.noSessionId }
        guard Self.isSafe(sessionId) else {
            throw CaptureDirectoryError.unsafeSessionId(sessionId)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Atomic for the same reason the shared store is: the app re-reads on a
        // 10s timer and must never observe a partial write.
        try JSONEncoder().encode(capture).write(to: root.appendingPathComponent("\(sessionId).json"),
                                                options: .atomic)
    }

    /// Every readable, compatible capture. A corrupt or version-mismatched file
    /// is skipped rather than fatal — one bad file must not cost the others.
    public func load() -> [RateLimitCapture] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let capture = try? JSONDecoder().decode(RateLimitCapture.self, from: data),
                      capture.isCompatible
                else { return nil }
                return capture
            }
            .sorted { ($0.sessionId ?? "") < ($1.sessionId ?? "") }
    }

    /// Drops captures observed before `cutoff` — callers pass the current
    /// window's start. A capture from a previous window describes a period that
    /// no longer exists and can never win selection again. Without this, files
    /// accumulate one per session forever.
    public func prune(before cutoff: TimeInterval) {
        for capture in load() where capture.capturedAt < cutoff {
            guard let sessionId = capture.sessionId else { continue }
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent("\(sessionId).json"))
        }
    }

    /// The capture to trust. Pure — callers date the inputs first, since dating
    /// is file I/O and this must stay testable without it.
    ///
    /// ⚠️ **Ties break on provenance, never on magnitude.** This used to read
    /// "the higher percentage: same instant and cumulative usage means the
    /// larger figure is the later one". Anthropic re-issued the weekly allowance
    /// inside an unchanged window on 2026-09-01 and the true figure went
    /// 51% → 0%, so usage is not monotonic within a window and magnitude says
    /// nothing about order. Worse, a magnitude tie-break is the second place —
    /// after `RateLimitHighWater` — where a frozen high reading beats the truth.
    ///
    /// A reading whose date is PROVEN (`RateLimitCapture.provenAt`: an explicit
    /// `fetchedAtMs`, or an exact `TranscriptDating.mintedAt`) therefore wins
    /// over one whose age is merely inferred. Beyond that the FIRST of the
    /// equals wins — `max(by:)` replaces only on a strict increase — so the
    /// caller's order decides, and every caller's order is deterministic:
    /// `CaptureDirectory.load` sorts by session id and `UsageStore` appends the
    /// other sources in a fixed order.
    ///
    /// Note that eligibility is decided upstream in `CaptureSelection` — this
    /// only ranks what it is given.
    ///
    /// 🔴 **`internal`, and the narrowing is the point.** `BurnlineProbe` is a
    /// separate target, so it cannot reach this and must go through
    /// `CaptureSelection.resolve` like the app does. Wiring only `UsageStore`
    /// when the per-session capture files landed left the probe disagreeing
    /// with the app in exactly the case the feature existed for, and a
    /// diagnostic that reports something other than the app is worse than no
    /// diagnostic because it is trusted. Making it `public` again turns that
    /// compile error back into a comment someone has to read.
    static func freshest(of captures: [RateLimitCapture]) -> RateLimitCapture? {
        freshestIndex(of: captures, among: Array(captures.indices)).map { captures[$0] }
    }

    /// `freshest` as a POSITION rather than a value, restricted to `admissible`.
    ///
    /// 🔴 The index is what lets a caller correlate the winner back to the file
    /// it was loaded from. Correlating by content cannot work: `sessionId` is
    /// `nil` on the shared `rate-limits.json`, on the `cachedUsageUtilization`
    /// capture and on `CaptureSelection`'s stand-in, so `first { $0.sessionId ==
    /// winner.sessionId }` returns whichever of those was loaded first.
    /// `BurnlineProbe` did precisely that and named the wrong source.
    ///
    /// Ranking is written once, here, so `freshest` and the filtered pick can
    /// never rank differently. `max(by:)` replaces only on a strict increase and
    /// `admissible` is ascending, so the FIRST of the equals still wins — the
    /// caller's order decides, exactly as before.
    static func freshestIndex(of captures: [RateLimitCapture],
                              among admissible: [Int]) -> Int? {
        admissible.max {
            (captures[$0].capturedAt, captures[$0].provenAt != nil ? 1 : 0)
                < (captures[$1].capturedAt, captures[$1].provenAt != nil ? 1 : 0)
        }
    }
}
