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

        // ScanCache, TranscriptScanner and Weights are all Sendable, so the scan
        // hops off the main actor cleanly with no locking.
        let updated = await Task.detached(priority: .utility) {
            (try? scanner.scan(cache: current, now: now)) ?? current
        }.value

        cache = updated
        try? cacheStore.save(updated)
        lastRefresh = Date()
        isScanning = false
        rebuild()
    }

    /// Records a `/usage` reading as a calibration anchor.
    func calibrate(observedPercent: Double) {
        let now = Date()
        let window = WindowMath.window(for: storedSettings.resetSchedule, now: now)
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
        snapshot = SnapshotBuilder.build(cache: cache, settings: storedSettings,
                                         now: Date(), isScanning: isScanning)
    }
}
