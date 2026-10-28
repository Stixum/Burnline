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
    cache.files["a.jsonl"] = FileState(
        modifiedAt: Date(timeIntervalSince1970: 5), size: 10, offset: 10,
        cells: ["42": ["claude-sonnet-5": TokenCounts(input: 7, output: 3,
                                                      cacheWrite: 1, cacheRead: 900)]])
    try store.save(cache)
    #expect(store.load() == cache)
}

@Test func cacheFromAnOlderVersionIsDiscarded() throws {
    let directory = tempDirectory()
    // Decodable as a v2 body, so the version gate is what discards it rather
    // than a decode failure that would mask a missing gate.
    try Data(#"{"version":1,"files":{"a":{"modifiedAt":0,"size":1,"offset":1,"cells":{}}}}"#.utf8)
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

// Model multipliers are not editable in Settings, so a stored list identical
// to an old default is the old default, not a choice. Without this, a price
// update to `Weights.default` never reaches an existing install — every
// settings.json written before it carries the old list forward forever.
private func settingsJSON(multipliers: String) -> String {
    """
    {"resetSchedule":{"weekday":6,"hour":2,"minute":0,"timeZoneIdentifier":"America/Chicago"},
     "weights":{"input":1,"cacheWrite":1.25,"cacheRead":0.1,"output":5,"defaultMultiplier":1,
                "modelMultipliers":\(multipliers)},
     "calibrationAnchors":[],"launchAtLogin":true}
    """
}

@Test func legacyDefaultModelMultipliersMigrateToCurrentDefaults() throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Byte-for-byte the list every install before 2026-09-22 saved.
    let legacy = #"[{"match":"opus","multiplier":5},{"match":"sonnet","multiplier":1},{"match":"haiku","multiplier":0.27}]"#
    try settingsJSON(multipliers: legacy).write(to: dir.appendingPathComponent("settings.json"),
                                                atomically: true, encoding: .utf8)

    let loaded = SettingsStore(directory: dir).load()
    #expect(loaded.weights.modelMultipliers == Weights.default.modelMultipliers)
    // Positive control: the file decoded, rather than falling back to .default.
    #expect(loaded.launchAtLogin == true)
    #expect(loaded.resetSchedule.weekday == 6)
}

@Test func handEditedModelMultipliersAreKept() throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let custom = #"[{"match":"opus","multiplier":3},{"match":"sonnet","multiplier":1}]"#
    try settingsJSON(multipliers: custom).write(to: dir.appendingPathComponent("settings.json"),
                                                atomically: true, encoding: .utf8)

    let loaded = SettingsStore(directory: dir).load()
    #expect(loaded.weights.modelMultipliers == [ModelMultiplier(match: "opus", multiplier: 3),
                                                ModelMultiplier(match: "sonnet", multiplier: 1)])
}

// A missing key already fell back, but a key with a value this version does not
// know threw — `decodeIfPresent` throws on an unknown raw value — and
// `SettingsStore.load` then returned `.default`: every setting gone, and the
// next save wrote the defaults over the file. A refresh interval of 10, a menu
// bar mode a later version added, or a downgrade all did it.
@Test func anUnknownValueFallsBackForItsFieldAloneAndKeepsTheRest() throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let json = """
    {"resetSchedule":{"weekday":6,"hour":2,"minute":0,"timeZoneIdentifier":"America/Chicago"},
     "weights":{"input":1,"cacheWrite":1.25,"cacheRead":0.1,"output":7,"defaultMultiplier":1,
                "modelMultipliers":[{"match":"opus","multiplier":3}]},
     "calibrationAnchors":[{"id":"6F1C2C1E-0000-4000-8000-000000000001","timestamp":0,
                            "observedPercent":40,"unitsInWindow":4000}],
     "launchAtLogin":true,
     "usageRefreshInterval":10, "menuBarMode":"sparkline", "targetMode":"tomorrow",
     "dayBoundary":"lunar", "notifications":"loud",
     "refreshesUsageAutomatically":"yes", "hasSeenOnboarding":true}
    """
    try json.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

    let loaded = SettingsStore(directory: dir).load()
    // Kept: everything the file says that this version understands.
    #expect(loaded.weights.output == 7)
    #expect(loaded.calibrationAnchors.map(\.observedPercent) == [40])
    #expect(loaded.resetSchedule.weekday == 6)
    #expect(loaded.launchAtLogin == true)
    #expect(loaded.hasSeenOnboarding == true)
    // Fallen back, one field at a time.
    #expect(loaded.usageRefreshInterval == .fortyFive)
    #expect(loaded.menuBarMode == .usedOverTarget)
    #expect(loaded.targetMode == .realTime)
    #expect(loaded.dayBoundary == .windowDay)
    #expect(loaded.notifications == .default)
    #expect(loaded.refreshesUsageAutomatically == false)
}
