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
