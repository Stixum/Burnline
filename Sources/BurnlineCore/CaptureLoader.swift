import Foundation

/// Gathers every capture candidate, dated, off the main actor.
///
/// Three sources compete on age with no precedence between them: per-session
/// statusline captures, the shared `rate-limits.json`, and
/// `cachedUsageUtilization` from `~/.claude.json`. The shared file competes on
/// equal terms rather than being preferred or ignored — the rollback script
/// writes only it, and so does a payload carrying no `session_id`. The
/// utilization block carries its own explicit `fetchedAtMs` and no session,
/// so dating leaves it alone.
///
/// Dating happens here, not in the helper: reading a transcript is file I/O,
/// and the helper runs every 30s in every open session under a contract that
/// it never fails and never delays the user's prompt.
///
/// An **actor** because all of this is I/O — a directory listing, two file
/// reads, and a 256 KB transcript tail per dated candidate — and it runs every
/// ten seconds plus on every settings mutation. `UsageStore.rebuild()` used to
/// do it inline on the main actor, so a keystroke in a weights field read
/// transcripts on the UI thread. `UtilizationStore` is a non-`Sendable`
/// caching class, which the actor's isolation is what makes safe to hold.
public actor CaptureLoader {
    public struct Loaded: Sendable {
        /// Every candidate, dated. Order is deterministic (directory, shared,
        /// utilization) because `CaptureSelection` breaks ties on position.
        public let candidates: [RateLimitCapture]
        public let utilization: UsageUtilization?
    }

    private let directory: CaptureDirectory
    private let shared: RateLimitStore
    private let utilization: UtilizationStore

    public init(directory: URL = ApplicationSupport.directory(), configPath: URL? = nil) {
        self.directory = CaptureDirectory(directory: directory)
        self.shared = RateLimitStore(directory: directory)
        self.utilization = configPath.map { UtilizationStore(path: $0) } ?? UtilizationStore()
    }

    public func load() -> Loaded {
        let block = utilization.load()
        let candidates = (directory.load()
                          + [shared.load()].compactMap { $0 }
                          + [block?.asCapture()].compactMap { $0 })
            .map { $0.dated(using: TranscriptDating.mintedAt) }
        return Loaded(candidates: candidates, utilization: block)
    }
}
