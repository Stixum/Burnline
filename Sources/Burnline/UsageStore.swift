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
            withMutation(keyPath: \.settings) { storedSettings = newValue }
            try? settingsStore.save(newValue)
            rebuild()
        }
    }

    @ObservationIgnored private var cache: ScanCache
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let cacheStore = CacheStore()
    @ObservationIgnored private let rateLimitStore = RateLimitStore()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh = Date.distantPast

    /// How often the timer fires, and the floor between popover-triggered refreshes.
    private static let refreshInterval: Duration = .seconds(60)
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
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: UsageStore.refreshInterval)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Called when the popover opens. Debounced so repeated clicks don't rescan.
    func refreshIfStale() {
        guard Date().timeIntervalSince(lastRefresh) > Self.manualRefreshFloor else { return }
        Task { await refresh() }
    }

    func refresh() async {
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
        snapshot = SnapshotBuilder.build(cache: cache, settings: storedSettings,
                                         rateLimit: rateLimitStore.load(),
                                         now: Date(), isScanning: isScanning)
    }
}
