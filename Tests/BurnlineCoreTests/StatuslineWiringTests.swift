import Testing
import Foundation
@testable import BurnlineCore

private let helper = "/Applications/Burnline.app/Contents/MacOS/burnline-statusline"

@Test func noFileMeansNotConfigured() {
    #expect(StatuslineWiring.state(settings: nil, helperPath: helper) == .noSettingsFile)
}

@Test func fileWithoutStatusLineMeansNotConfigured() {
    let settings: [String: Any] = ["theme": "dark"]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .notConfigured)
}

@Test func ourHelperAtTheCurrentPathIsConfigured() {
    let settings: [String: Any] = ["statusLine": ["type": "command", "command": helper, "refreshInterval": 30]]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .configured)
}

@Test func ourHelperAtAnotherPathIsStale() {
    let old = "/Users/someone/Downloads/Burnline.app/Contents/MacOS/burnline-statusline"
    let settings: [String: Any] = ["statusLine": ["type": "command", "command": old]]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .stalePath(current: old))
}

@Test func theOldBashScriptCountsAsOurs() {
    // Upgraders from the pre-1.0 hand-installed script must be migrated, not
    // treated as a foreign statusline we have to refuse.
    let script = "/Users/someone/.claude/burnline-statusline.sh"
    let settings: [String: Any] = ["statusLine": ["type": "command", "command": script]]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .stalePath(current: script))
}

@Test func someoneElsesStatusLineIsAConflict() {
    let settings: [String: Any] = ["statusLine": ["type": "command", "command": "~/bin/my-prompt.sh"]]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .conflict(command: "~/bin/my-prompt.sh"))
}

@Test func aConflictWithNoCommandStringStillConflicts() {
    let settings: [String: Any] = ["statusLine": ["type": "command"]]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .conflict(command: ""))
}

@Test func aNonDictionaryStatusLineIsAConflict() {
    // Don't guess at a shape we don't recognise — refuse and let the user look.
    let settings: [String: Any] = ["statusLine": "some-command"]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .conflict(command: "some-command"))
}

// A path ending in our binary's name but belonging to someone else is still
// ours by this rule. That is deliberate: the alternative is refusing to repair
// a user's own moved bundle, and the cost of being wrong here is repointing a
// command that already named `burnline-statusline`.
@Test func anyPathEndingInOurBinaryNameCountsAsOurs() {
    let odd = "/opt/custom/burnline-statusline"
    let settings: [String: Any] = ["statusLine": ["type": "command", "command": odd]]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .stalePath(current: odd))
}

@Test func onlyTheAutomaticallyFixableStatesOfferTheButton() {
    #expect(StatuslineWiring.State.noSettingsFile.isAutomaticallyFixable)
    #expect(StatuslineWiring.State.notConfigured.isAutomaticallyFixable)
    #expect(StatuslineWiring.State.stalePath(current: "/x").isAutomaticallyFixable)
    #expect(!StatuslineWiring.State.configured.isAutomaticallyFixable)
    #expect(!StatuslineWiring.State.conflict(command: "/x").isAutomaticallyFixable)
    // The one property `.unreadable` shares with `.conflict`, and the reason it
    // was borrowed from it for so long: Burnline must not write to this file.
    #expect(!StatuslineWiring.State.unreadable.isAutomaticallyFixable)
}

// --- what each state is called ---

/// 🔴 The defect `.unreadable` was added for. A file that could not be parsed
/// was reported as `.conflict`, so both windows announced somebody else's status
/// line over a file whose contents nothing had read. The two states must not be
/// able to say the same thing.
@Test func anUnreadableSettingsFileIsNotDescribedAsSomebodyElsesStatusLine() {
    let unreadable = StatuslineWiring.State.unreadable.title
    #expect(unreadable == "Settings file could not be read")
    #expect(unreadable != StatuslineWiring.State.conflict(command: "").title)
}

/// Settings and Onboarding both render `title`, so a state that described itself
/// two ways would put the app's own name for it in doubt.
@Test func everyStateHasItsOwnWording() {
    let states: [StatuslineWiring.State] = [
        .noSettingsFile, .notConfigured, .configured,
        .stalePath(current: "/x"), .conflict(command: "/x"), .unreadable
    ]
    let titles = states.map(\.title)
    #expect(titles.allSatisfy { !$0.isEmpty })
    // `noSettingsFile` and `notConfigured` are deliberately the same words —
    // "no file" and "a file with no statusLine key" are one thing to a reader.
    #expect(Set(titles).count == states.count - 1)
    #expect(StatuslineWiring.State.noSettingsFile.title
            == StatuslineWiring.State.notConfigured.title)
}

/// The wiring state is what the "Set up" affordance keys off, so `configured`
/// has to read as *done* rather than as another instruction.
@Test func theConfiguredStateReadsAsFinished() {
    #expect(StatuslineWiring.State.configured.title == "Connected")
}

// --- the merge itself ---

@Test func mergeAddsStatusLineAndPreservesEverythingElse() throws {
    let existing: [String: Any] = ["theme": "dark", "hooks": ["PreToolUse": ["x"]]]
    let merged = StatuslineWiring.merged(into: existing, helperPath: helper)

    let statusLine = try #require(merged["statusLine"] as? [String: Any])
    #expect(statusLine["type"] as? String == "command")
    #expect(statusLine["command"] as? String == helper)
    #expect(statusLine["refreshInterval"] as? Int == 30)

    #expect(merged["theme"] as? String == "dark")
    #expect((merged["hooks"] as? [String: Any])?["PreToolUse"] != nil)
}

@Test func mergeIntoNothingProducesOnlyStatusLine() {
    let merged = StatuslineWiring.merged(into: [:], helperPath: helper)
    #expect(merged.count == 1)
    #expect(merged["statusLine"] != nil)
}

@Test func mergeReplacesOnlyTheCommandOnAStalePath() throws {
    // A user who set their own refreshInterval keeps it.
    let existing: [String: Any] = [
        "statusLine": ["type": "command", "command": "/old/path", "refreshInterval": 10]
    ]
    let merged = StatuslineWiring.merged(into: existing, helperPath: helper)
    let statusLine = try #require(merged["statusLine"] as? [String: Any])
    #expect(statusLine["command"] as? String == helper)
    #expect(statusLine["refreshInterval"] as? Int == 10)
}

// The merge must be usable as the input to a real write, so it has to survive
// JSONSerialization. A dictionary holding a non-plist type would throw at the
// point of writing the user's file, which is the worst possible place to find
// out.
@Test func mergeProducesSomethingJsonSerializable() throws {
    let merged = StatuslineWiring.merged(into: ["theme": "dark"], helperPath: helper)
    #expect(JSONSerialization.isValidJSONObject(merged))
    let data = try JSONSerialization.data(withJSONObject: merged)
    let round = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((round["statusLine"] as? [String: Any])?["command"] as? String == helper)
}

@Test func theSnippetNamesTheResolvedHelperAndTheInterval() {
    let snippet = StatuslineWiring.snippet(helperPath: helper)
    #expect(snippet.contains(helper))
    #expect(snippet.contains("\"refreshInterval\": 30"))
    #expect(snippet.contains("\"type\": \"command\""))
}
