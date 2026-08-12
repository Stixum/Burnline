import Testing
import Foundation
@testable import BurnlineCore

// ⚠️ Every test here writes its own temp config. NONE may read the real
// ~/.claude.json — it holds hundreds of project paths, which for consultancy
// work are client names.

private func configScratch(_ contents: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-config-\(UUID().uuidString).json")
    try? Data(contents.utf8).write(to: url)
    return url
}

private let configWithBlock = """
{"numStartups":42,
 "projects":{"/Users/x/SomeClient":{"lastCost":1.0}},
 "cachedUsageUtilization":{"fetchedAtMs":1786542556418,
   "utilization":{"seven_day":{"utilization":75,"resets_at":"2026-08-14T07:00:00.818653+00:00"},
                  "five_hour":{"utilization":3,"resets_at":"2026-08-12T16:10:00.818605+00:00"}}}}
"""

@Test func readsTheUtilizationBlockOutOfAClaudeConfig() {
    let store = UtilizationStore(path: configScratch(configWithBlock))
    #expect(store.load()?.sevenDay?.percent == 75)
}

/// Claude Code rewrites this file underneath us, so a read can land mid-write.
/// That must degrade to nothing, never throw into the UI.
@Test func aTruncatedConfigYieldsNoUtilization() {
    #expect(UtilizationStore(path: configScratch("{\"cachedUsageUtil")).load() == nil)
}

@Test func aConfigWithoutTheBlockYieldsNoUtilization() {
    #expect(UtilizationStore(path: configScratch("{\"numStartups\":42}")).load() == nil)
}

/// Older Claude Code, or a different machine. Absent means the statusline path
/// carries on untouched.
@Test func aMissingConfigYieldsNoUtilization() {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-absent-\(UUID().uuidString).json")
    #expect(UtilizationStore(path: missing).load() == nil)
}

/// The rebuild runs every 10 seconds and this file is 160 KB. Re-parsing an
/// unchanged file forever is pure waste.
@Test func anUnchangedFileIsNotReparsed() {
    let store = UtilizationStore(path: configScratch(configWithBlock))
    _ = store.load()
    _ = store.load()
    _ = store.load()
    #expect(store.parseCount == 1)
}

/// The harder case on purpose: the replacement is the SAME LENGTH, so size
/// cannot distinguish it. If the cache key ever degrades to size alone, or to a
/// whole-second mtime, this catches it — and a stale usage figure that never
/// updates is exactly the bug class this project keeps hitting.
@Test func aChangedFileIsReparsedEvenWhenItsSizeIsIdentical() throws {
    let url = configScratch(configWithBlock)
    let store = UtilizationStore(path: url)
    #expect(store.load()?.sevenDay?.percent == 75)

    let changed = configWithBlock.replacingOccurrences(of: "\"utilization\":75",
                                                       with: "\"utilization\":88")
    #expect(changed.utf8.count == configWithBlock.utf8.count)
    try Data(changed.utf8).write(to: url)

    #expect(store.load()?.sevenDay?.percent == 88)
    #expect(store.parseCount == 2)
}

// MARK: - Making the real config avoidable

// ⚠️ `NSHomeDirectory()` IGNORES $HOME — verified 2026-08-12, exactly like
// `FileManager.urls(for:in:)`, which is why BURNLINE_DATA_DIR exists. Without an
// explicit override there is no way to exercise this source, or screenshot the
// per-model row, without reading the user's own ~/.claude.json.

@Test func theConfigPathFallsBackToTheRealHomeWhenUnset() {
    let url = UtilizationStore.defaultPath(environment: [:])
    #expect(url.lastPathComponent == ".claude.json")
    #expect(url.deletingLastPathComponent().path == NSHomeDirectory())
}

@Test func theConfigPathHonoursTheOverride() {
    let url = UtilizationStore.defaultPath(
        environment: [UtilizationStore.overrideKey: "/tmp/elsewhere/.claude.json"])
    #expect(url.path == "/tmp/elsewhere/.claude.json")
    #expect(url.path != NSHomeDirectory() + "/.claude.json")
}

@Test func theConfigPathExpandsATildeAndIgnoresAnEmptyOverride() {
    #expect(UtilizationStore.defaultPath(
        environment: [UtilizationStore.overrideKey: "~/somewhere.json"]).path
        == NSHomeDirectory() + "/somewhere.json")
    #expect(UtilizationStore.defaultPath(
        environment: [UtilizationStore.overrideKey: ""]).lastPathComponent == ".claude.json")
}
