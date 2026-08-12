import Testing
import Foundation
@testable import BurnlineCore

private func settingsScratch() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func readsAMissingSettingsFileAsNil() throws {
    let dir = try settingsScratch(); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(try ClaudeSettingsFile(directory: dir).read() == nil)
}

@Test func readsAnExistingSettingsFile() throws {
    let dir = try settingsScratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = ClaudeSettingsFile(directory: dir)
    try #"{"theme":"dark"}"#.write(to: file.url, atomically: true, encoding: .utf8)
    #expect(try file.read()?["theme"] as? String == "dark")
}

@Test func malformedSettingsThrowRatherThanReadingAsEmpty() throws {
    // Reading a broken file as `nil` would be indistinguishable from "no file",
    // and we would then write a fresh settings.json straight over it.
    let dir = try settingsScratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = ClaudeSettingsFile(directory: dir)
    try "{ not json".write(to: file.url, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try file.read() }
}

@Test func aJsonArrayAtTheRootIsAlsoAnError() throws {
    // Valid JSON, wrong shape. Same reasoning as malformed: do not treat it as
    // absent and overwrite it.
    let dir = try settingsScratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = ClaudeSettingsFile(directory: dir)
    try "[1,2,3]".write(to: file.url, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try file.read() }
}

@Test func writingBacksUpTheOriginalFirst() throws {
    let dir = try settingsScratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = ClaudeSettingsFile(directory: dir)
    try #"{"theme":"dark"}"#.write(to: file.url, atomically: true, encoding: .utf8)

    try file.write(["theme": "light"], backupSuffix: "test")

    let backup = dir.appendingPathComponent("settings.json.burnline-backup-test")
    let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any]
    #expect(restored?["theme"] as? String == "dark")
    #expect(try file.read()?["theme"] as? String == "light")
}

@Test func writingWithNoOriginalMakesNoBackup() throws {
    let dir = try settingsScratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = ClaudeSettingsFile(directory: dir)
    try file.write(["theme": "light"], backupSuffix: "test")
    let backup = dir.appendingPathComponent("settings.json.burnline-backup-test")
    #expect(!FileManager.default.fileExists(atPath: backup.path))
}

@Test func nestedSettingsStructuresSurviveARoundTrip() throws {
    let dir = try settingsScratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = ClaudeSettingsFile(directory: dir)
    let original = #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"x"}]}]},"env":{"A":"1"}}"#
    try original.write(to: file.url, atomically: true, encoding: .utf8)

    let read = try #require(try file.read())
    try file.write(StatuslineWiring.merged(into: read, helperPath: "/h"), backupSuffix: "test")

    let after = try #require(try file.read())
    let hooks = try #require(after["hooks"] as? [String: Any])
    let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
    #expect(preToolUse.first?["matcher"] as? String == "Bash")
    #expect((after["env"] as? [String: Any])?["A"] as? String == "1")
    #expect((after["statusLine"] as? [String: Any])?["command"] as? String == "/h")
}

@Test func writingCreatesTheDirectoryIfClaudeHasNeverRun() throws {
    let parent = try settingsScratch(); defer { try? FileManager.default.removeItem(at: parent) }
    let missing = parent.appendingPathComponent("never-created", isDirectory: true)
    let file = ClaudeSettingsFile(directory: missing)
    try file.write(["statusLine": ["type": "command"]], backupSuffix: "test")
    #expect(try file.read()?["statusLine"] != nil)
}

// --- directory resolution ---

@Test func theDefaultDirectoryIsDotClaudeInTheHomeDirectory() {
    let resolved = ClaudeSettingsFile.resolveDirectory(environment: [:])
    #expect(resolved.lastPathComponent == ".claude")
}

@Test func anOverrideRedirectsTheSettingsDirectory() {
    let resolved = ClaudeSettingsFile.resolveDirectory(
        environment: [ClaudeSettingsFile.overrideKey: "/tmp/burnline-claude-test"]
    )
    #expect(resolved.path == "/tmp/burnline-claude-test")
}

@Test func anEmptyOverrideMeansTheRealDirectory() {
    // Same convention as BURNLINE_DATA_DIR: unset and empty are the same thing,
    // and there is no validation to fail — rejecting a malformed value and
    // falling back to the real ~/.claude would fail open, which is the whole
    // class of accident the override exists to prevent.
    let resolved = ClaudeSettingsFile.resolveDirectory(
        environment: [ClaudeSettingsFile.overrideKey: ""]
    )
    #expect(resolved.lastPathComponent == ".claude")
}

@Test func anOverrideExpandsATilde() {
    let resolved = ClaudeSettingsFile.resolveDirectory(
        environment: [ClaudeSettingsFile.overrideKey: "~/burnline-claude-test"]
    )
    #expect(!resolved.path.contains("~"))
    #expect(resolved.lastPathComponent == "burnline-claude-test")
}
