import Foundation
import Observation
import BurnlineCore

@MainActor
@Observable
final class UsageStore {
    private(set) var snapshot: Snapshot
    private(set) var isScanning = false

    /// Written through to disk on every mutation, so SwiftUI bindings in the
    /// settings window persist without any explicit save step.
    @ObservationIgnored private var storedSettings: BurnlineSettings
    var settings: BurnlineSettings {
        get {
            access(keyPath: \.settings)
            return storedSettings
        }
        set {
            // Single choke point for validation, so a hand-edited settings.json
            // is covered as well as the Settings text fields.
            var sanitized = newValue
            sanitized.weights = newValue.weights.sanitized()
            withMutation(keyPath: \.settings) { storedSettings = sanitized }
            try? settingsStore.save(sanitized)
            rebuild()
        }
    }

    @ObservationIgnored private var cache: ScanCache
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let cacheStore = CacheStore()
    @ObservationIgnored private let rateLimitStore = RateLimitStore()
    @ObservationIgnored private let captureDirectory = CaptureDirectory()
    @ObservationIgnored private let utilizationStore = UtilizationStore()
    @ObservationIgnored private let poller = UsagePoller()
    @ObservationIgnored private var lastPollAt: Date?
    @ObservationIgnored private let highWaterStore = HighWaterStore()
    @ObservationIgnored private var highWater = HighWaterStore().load()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var isRefreshing = false

    /// The transcript scan — the expensive half, 36ms warm and ~6s cold.
    private static let scanInterval: Duration = .seconds(60)
    /// Re-reading the capture: 141 bytes and a pure rebuild. It used to be
    /// welded to the scan, so a capture landing just after a tick sat unread for
    /// most of a minute even though the statusline writes every 30s.
    private static let captureInterval: Duration = .seconds(10)
    /// Floor between popover-triggered refreshes.
    private static let manualRefreshFloor: TimeInterval = 5

    init() {
        let loadedSettings = settingsStore.load()
        let loadedCache = cacheStore.load()
        storedSettings = loadedSettings
        cache = loadedCache
        // A cold cache means the first scan is a few seconds; say so in the label.
        snapshot = SnapshotBuilder.build(cache: loadedCache, settings: loadedSettings,
                                         now: Date(), isScanning: loadedCache.files.isEmpty)
    }

    func start() {
        guard scanTask == nil else { return }

        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: UsageStore.scanInterval)
            }
        }

        // Decoupled from the scan on purpose. Rebuilding is a 141-byte read and
        // a pure snapshot build, so pacing it to the cost of the scan was
        // wasting most of a minute of freshness for nothing. It also makes the
        // pace target advance smoothly instead of stepping once a minute.
        // Sleeps first: `refresh()` above already rebuilds at launch.
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: UsageStore.captureInterval)
                guard !Task.isCancelled else { return }
                // No `await`: `Task {}` inherits this class's MainActor
                // isolation, so `rebuild()` is already on the right actor.
                self?.rebuild()
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        captureTask?.cancel()
        captureTask = nil
    }

    /// Called when the popover opens. Debounced so repeated clicks don't rescan.
    func refreshIfStale() {
        guard Date().timeIntervalSince(lastRefresh) > Self.manualRefreshFloor else { return }
        Task { await refresh() }
    }

    func refresh() async {
        // `lastRefresh` isn't set until a scan finishes, so during a cold scan
        // the debounce above lets every popover open start another one. One at a
        // time: a second scan of the same tree would only repeat the work.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        isScanning = true
        rebuild()

        let scanner = TranscriptScanner(weights: storedSettings.weights)
        let current = cache
        let now = Date()
        let store = cacheStore

        // ScanCache, TranscriptScanner, Weights and CacheStore are all Sendable,
        // so the scan hops off the main actor cleanly with no locking. Persisting
        // goes with it: the cache is a few hundred KB and encoding it has no
        // business on the UI thread.
        let updated = await Task.detached(priority: .utility) {
            guard let scanned = try? scanner.scan(cache: current, now: now) else { return current }
            // Only when something actually moved. The timer fires every 60s
            // whether or not Claude Code ran, and an idle machine would otherwise
            // rewrite the whole cache overnight for no change at all.
            if scanned != current { try? store.save(scanned) }
            return scanned
        }.value

        cache = updated
        lastRefresh = Date()
        isScanning = false
        rebuild()

        // On the 60s scan path, not the 10s rebuild: this is directory I/O plus
        // deletes. Placed after `rebuild()` so `snapshot.window` is the current
        // one — pruning from inside `rebuild()` would, for one tick after a
        // reset, prune against the previous window and delete the very capture
        // proving the new one had started.
        captureDirectory.prune(before: snapshot.window.start.timeIntervalSince1970)

        // Last, and only when the anchor has actually gone stale. Nothing else
        // on this Mac will move it: an idle session republishes its cached
        // reading forever, and a desktop session never publishes at all.
        // Adaptive: the tighter the pressure on any limit, the more often the
        // anchor is worth 3.5 CPU-seconds and a ~27s process.
        let interval = PollDecision.interval(
            weeklyPercent: snapshot.estimatedPercent,
            fiveHourPercent: snapshot.fiveHour?.usedPercent,
            projectedPercent: snapshot.projectedPercent,
            ceiling: storedSettings.usageRefreshInterval)

        if PollDecision.shouldPoll(enabled: storedSettings.refreshesUsageAutomatically,
                                   anchorAge: snapshot.liveAge,
                                   lastPollAt: lastPollAt,
                                   interval: interval,
                                   now: Date()) {
            lastPollAt = Date()
            await poller.poll()
            // The poll refreshed ~/.claude.json, not our own files.
            rebuild()
        }
    }

    /// Records a `/usage` reading as a calibration anchor. Only a fallback now —
    /// a live capture takes precedence over anchors.
    func calibrate(observedPercent: Double) {
        let now = Date()
        // Anchor against the window actually on screen, which may have come
        // from a live capture rather than the configured schedule.
        let window = snapshot.window
        let units = cache.units(from: window.start, to: window.end)
        var updated = storedSettings
        updated.calibrationAnchors.append(
            CalibrationAnchor(timestamp: now, observedPercent: observedPercent, unitsInWindow: units)
        )
        // Prune on write. `validAnchors` only filters what the fit may use, so
        // without this the stored list — and the Settings display — grows forever.
        updated.calibrationAnchors = Calibration.retained(updated.calibrationAnchors, now: now)
        settings = updated
    }

    func removeAnchor(_ anchor: CalibrationAnchor) {
        var updated = storedSettings
        updated.calibrationAnchors.removeAll { $0.id == anchor.id }
        settings = updated
    }

    private func rebuild() {
        // Re-read every time: the statusline script rewrites this file from
        // another process whenever Claude Code produces a response.
        //
        // Reconcile against the high-water mark before trusting it. Every open
        // Claude Code session writes this same file on its own timer, and an idle
        // one keeps publishing the stale rate_limits snapshot it started with —
        // so the last writer is routinely not the freshest.
        //
        // Dating happens here, not in the helper: reading a transcript is file
        // I/O, and the helper runs every 30s in every open session under a
        // contract that it never fails and never delays the user's prompt.
        // Per-session files plus the shared one, all dated, freshest wins. The
        // shared file competes on equal terms rather than being preferred or
        // ignored: the rollback script writes only it, and so does a payload
        // that carries no session_id.
        // Three sources now, competing on age with no precedence between them:
        // per-session statusline captures, the shared statusline file, and
        // `cachedUsageUtilization` from ~/.claude.json. The last carries its own
        // explicit `fetchedAtMs` and no session, so dating leaves it alone.
        let utilization = utilizationStore.load()
        let dated = (captureDirectory.load()
                     + [rateLimitStore.load()].compactMap { $0 }
                     + [utilization?.asCapture()].compactMap { $0 })
            .map { loaded in
                loaded.dated(mintedAt: loaded.transcriptPath.flatMap {
                    TranscriptDating.mintedAt(transcriptPath: $0, observedAt: loaded.capturedAt)
                })
            }
        var capture = CaptureDirectory.freshest(of: dated)
        // Kept so the popover can say the file was overridden. Silently
        // disagreeing with the user's own terminal status line reads as a broken
        // app rather than as the protection it is.
        var rejected: RateLimitHighWater.RejectedReading?
        if let incoming = capture {
            let (resolved, mark) = RateLimitHighWater.reconcile(incoming, against: highWater)
            rejected = RateLimitHighWater.rejection(onDisk: incoming, resolved: resolved)
            capture = resolved
            if mark != highWater {
                highWater = mark
                try? highWaterStore.save(mark)
            }
        }

        snapshot = SnapshotBuilder.build(cache: cache, settings: storedSettings,
                                         rateLimit: capture,
                                         now: Date(), isScanning: isScanning,
                                         rejected: rejected,
                                         scopedWeekly: utilization?.scopedWeekly)
    }
}
