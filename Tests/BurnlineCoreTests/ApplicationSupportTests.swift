import Testing
import Foundation
@testable import BurnlineCore

// The override exists to make the capture path safely testable. Every rule
// below is chosen so a mistake lands somewhere harmless rather than falling
// back to the live data directory — a guard that fails open is worse than no
// guard, because it reports success while writing the file it was meant to
// protect.

private func scratchDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-datadir-\(UUID().uuidString)")
}

private func withOverride(_ path: String) -> [String: String] {
    [ApplicationSupport.overrideKey: path]
}

@Test func dataDirectoryFallsBackToApplicationSupportWhenOverrideAbsent() {
    let url = ApplicationSupport.resolve(environment: [:])
    #expect(url.lastPathComponent == "Burnline")
    #expect(url.deletingLastPathComponent().lastPathComponent == "Application Support")
}

/// Unset and empty mean the same thing. The accident being defended against is
/// "I forgot to export it", not "I deliberately exported nothing".
@Test func dataDirectoryFallsBackToApplicationSupportWhenOverrideIsEmpty() {
    let url = ApplicationSupport.resolve(environment: withOverride(""))
    #expect(url.deletingLastPathComponent().lastPathComponent == "Application Support")
}

@Test func dataDirectoryUsesAnAbsoluteOverrideVerbatim() {
    let scratch = scratchDirectory()
    #expect(ApplicationSupport.resolve(environment: withOverride(scratch.path)).path == scratch.path)
}

/// Shells expand an unquoted tilde, but `env BURNLINE_DATA_DIR='~/x'` does not —
/// and creating a literal `~` directory in the cwd is a confusing way to fail.
@Test func dataDirectoryExpandsTildeInOverride() {
    let url = ApplicationSupport.resolve(environment: withOverride("~/burnline-tilde-scratch"))
    #expect(url.path == NSHomeDirectory() + "/burnline-tilde-scratch")
}

/// A relative path is honoured against the cwd rather than rejected. Rejecting
/// it would mean falling back to the live directory — the exact fail-open this
/// whole override exists to remove.
@Test func dataDirectoryResolvesARelativeOverrideRatherThanFallingBackToLiveData() {
    let url = ApplicationSupport.resolve(environment: withOverride("burnline-relative-scratch"))
    #expect(url.lastPathComponent == "burnline-relative-scratch")
    #expect(url != ApplicationSupport.resolve(environment: [:]))
}

/// The probe prints this so an export can be confirmed *before* anything runs
/// the helper. A wrong branch here would report "sandboxed" while live.
@Test func overrideIsReportedActiveOnlyWhenItApplies() {
    #expect(ApplicationSupport.isOverridden(environment: [:]) == false)
    #expect(ApplicationSupport.isOverridden(environment: withOverride("")) == false)
    #expect(ApplicationSupport.isOverridden(environment: withOverride("/tmp/x")) == true)
}

@Test func dataDirectoryCreatesTheOverrideDirectoryOnDemand() {
    let scratch = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    #expect(FileManager.default.fileExists(atPath: scratch.path) == false)

    let url = ApplicationSupport.directory(environment: withOverride(scratch.path))
    #expect(FileManager.default.fileExists(atPath: url.path))
}

/// Pins the consumer, not just the producer: resolving the right URL proves
/// nothing if the stores don't end up writing there.
@Test func storesWriteIntoTheOverrideDirectoryRatherThanLiveData() throws {
    let scratch = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let directory = ApplicationSupport.directory(environment: withOverride(scratch.path))

    let capture = RateLimitCapture(version: RateLimitCapture.currentVersion,
                                   capturedAt: 1_000,
                                   sevenDay: .init(usedPercent: 42, resetsAt: 2_000),
                                   fiveHour: nil)
    try RateLimitStore(directory: directory).save(capture)
    try HighWaterStore(directory: directory).save(.init(sevenDay: .init(resetsAt: 2_000,
                                                                       usedPercent: 42,
                                                                       capturedAt: 1_000)))

    let files = FileManager.default.fileExists(atPath:)
    #expect(files(scratch.appendingPathComponent("rate-limits.json").path))
    #expect(files(scratch.appendingPathComponent("rate-limit-highwater.json").path))
    #expect(RateLimitStore(directory: directory).load() == capture)
}
