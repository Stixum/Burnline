import Testing
import Foundation
@testable import BurnlineCore

private func tempDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-persist-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func settingsRoundTrip() throws {
    let store = SettingsStore(directory: tempDirectory())
    var settings = BurnlineSettings.default
    settings.resetSchedule = ResetSchedule(weekday: 3, hour: 14, minute: 30)
    settings.calibrationAnchors = [CalibrationAnchor(timestamp: Date(timeIntervalSince1970: 1),
                                                     observedPercent: 42, unitsInWindow: 4200)]
    try store.save(settings)
    #expect(store.load() == settings)
}

@Test func missingSettingsFileYieldsDefaults() {
    let store = SettingsStore(directory: tempDirectory())
    #expect(store.load() == BurnlineSettings.default)
}

@Test func corruptSettingsFileYieldsDefaults() throws {
    let directory = tempDirectory()
    try Data("{ not json".utf8).write(to: directory.appendingPathComponent("settings.json"))
    #expect(SettingsStore(directory: directory).load() == BurnlineSettings.default)
}

@Test func cacheRoundTrip() throws {
    let store = CacheStore(directory: tempDirectory())
    var cache = ScanCache()
    cache.files["a.jsonl"] = FileState(modifiedAt: Date(timeIntervalSince1970: 5),
                                       size: 10, offset: 10, buckets: ["42": 3.5])
    try store.save(cache)
    #expect(store.load() == cache)
}

@Test func cacheFromAnOlderVersionIsDiscarded() throws {
    let directory = tempDirectory()
    try Data(#"{"version":0,"files":{"a":{"modifiedAt":0,"size":1,"offset":1,"buckets":{}}}}"#.utf8)
        .write(to: directory.appendingPathComponent("scan-cache.json"))
    #expect(CacheStore(directory: directory).load().files.isEmpty)
}

@Test func missingCacheFileYieldsEmptyCache() {
    #expect(CacheStore(directory: tempDirectory()).load().files.isEmpty)
}

/// Off by default, and a settings file written before the flag existed must
/// decode to off rather than silently start spawning Claude Code sessions.
@Test func settingsWithoutTheRefreshFlagDecodeToItBeingOff() throws {
    let json = """
    {"resetSchedule":{"weekday":5,"hour":9,"minute":0,"timeZoneIdentifier":"America/Chicago"},
     "weights":\(String(data: try JSONEncoder().encode(Weights.default), encoding: .utf8)!),
     "calibrationAnchors":[],"launchAtLogin":false}
    """
    let decoded = try JSONDecoder().decode(BurnlineSettings.self, from: Data(json.utf8))
    #expect(decoded.refreshesUsageAutomatically == false)
    #expect(BurnlineSettings.default.refreshesUsageAutomatically == false)
}

// Onboarding was added after settings.json had been in use for a while. Every
// existing file lacks the key, and a decode that threw on it would silently
// reset the user's whole configuration — SettingsStore.load falls back to
// defaults on any failure, so the loss would be invisible.
@Test func settingsPredatingOnboardingStillDecode() throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Copied from the shape a real pre-onboarding settings.json has on disk:
    // no hasSeenOnboarding, no usageRefreshInterval, no refreshesUsageAutomatically.
    let legacy = """
    {"resetSchedule":{"weekday":6,"hour":2,"minute":0,"timeZoneIdentifier":"America/Chicago"},
     "weights":{"input":1,"cacheWrite":1.25,"cacheRead":0.1,"output":5,
                "defaultMultiplier":1,
                "modelMultipliers":[{"match":"opus","multiplier":5}]},
     "calibrationAnchors":[],
     "launchAtLogin":true,
     "menuBarMode":"delta"}
    """
    try legacy.write(to: dir.appendingPathComponent("settings.json"),
                     atomically: true, encoding: .utf8)

    let loaded = SettingsStore(directory: dir).load()
    #expect(loaded.hasSeenOnboarding == false)
    // The positive control: proves we actually decoded the file rather than
    // falling back to .default, which would also report hasSeenOnboarding false.
    #expect(loaded.launchAtLogin == true)
    #expect(loaded.menuBarMode == .delta)
}

@Test func hasSeenOnboardingSurvivesASaveLoadRoundTrip() throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SettingsStore(directory: dir)

    var settings = BurnlineSettings.default
    settings.hasSeenOnboarding = true
    try store.save(settings)

    #expect(store.load().hasSeenOnboarding == true)
}
