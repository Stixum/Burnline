import Testing
import Foundation

// ⚠️ Source-text pins, the first in this repo, and deliberately few.
//
// `Sources/Burnline` has no test target, so the repo's rule is to move every
// decision into Core, and the History reload's decisions are there
// (`HistoryReload`, `HistoryFreshness`, `HistoryWriter.revision`). What cannot
// move is the wiring: the window keying `.task(id:)` on the store's archive
// key, the store building that key with the revision, and the store publishing
// the revision after each write. A review of the first version showed that
// breaking any of those puts the 2026-11-26 bug (a window that never re-reads)
// straight back with every test green. These read the app's source and fail if
// a wire is cut. They pin call sites, not formatting: whitespace is collapsed
// before matching.

private func appSource(_ file: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BurnlineCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
    let text = try String(contentsOf: root.appendingPathComponent("Sources/Burnline/\(file)"),
                          encoding: .utf8)
    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@Test func theHistoryWindowReloadsOnTheStoresArchiveKey() throws {
    let window = try appSource("HistoryWindow.swift")
    #expect(window.contains("let archive: HistoryReload.ArchiveKey"))
    #expect(window.contains(".task(id: LoadKey(dimension: dimension, range: range, archive: store.historyArchiveKey))"))
}

@Test func theStoreBuildsTheArchiveKeyWithTheRevision() throws {
    let store = try appSource("UsageStore.swift")
    #expect(store.contains("var historyArchiveKey: HistoryReload.ArchiveKey { HistoryReload.ArchiveKey(fill: historyFillState.reloadPhase, weights: settings.weights, archiveRevision: historyRevision.revision) }"))
}

@Test func theStorePublishesTheRevisionAfterEveryKindOfWrite() throws {
    let store = try appSource("UsageStore.swift")
    // Through the Core rule, so an unchanged revision is not restamped.
    #expect(store.contains("HistoryReload.publish(writerRevision: revision, over: historyRevision,"))
    // After the 60-second flush.
    #expect(store.contains("await flushHistory(cache: updated, observation: currentObservation, now: now) await syncHistoryRevision()"))
    // After a new reading reaches the archive.
    #expect(store.contains("await writer.observe(entry) await self?.syncHistoryRevision()"))
    // After the launch fill, before the phase that also reloads.
    #expect(store.contains("await self?.syncHistoryRevision() await self?.finishHistoryFill(failure: failure)"))
}

@Test func theLoaderReusesAReadOnlyThroughTheCoreRule() throws {
    let loader = try appSource("HistoryLoader.swift")
    #expect(loader.contains("if let cached, HistoryReload.mayReuse(cachedRevision: cached.revision, cachedAt: cached.loadedAt, revision: revision, now: now) { return cached }"))
    // No second path back to the cached read.
    #expect(loader.components(separatedBy: "return cached").count == 2)
}
