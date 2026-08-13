import Testing
import Foundation
@testable import BurnlineCore

private let home = "/Users/someone"

@Test func pathEntriesComeFirstInCandidateOrder() {
    let candidates = ClaudeExecutable.candidates(
        environment: ["PATH": "/usr/bin:/opt/mine/bin"], home: home)
    #expect(candidates.first == "/usr/bin/claude")
    #expect(candidates[1] == "/opt/mine/bin/claude")
}

@Test func theKnownLocationsAreAppendedAfterPath() {
    let candidates = ClaudeExecutable.candidates(environment: ["PATH": "/usr/bin"], home: home)
    // A Finder-launched app gets roughly /usr/bin:/bin:/usr/sbin:/sbin and never
    // sees Homebrew, which is the whole reason these fallbacks exist.
    #expect(candidates.contains("/opt/homebrew/bin/claude"))
    #expect(candidates.contains("/usr/local/bin/claude"))
    #expect(candidates.contains("\(home)/.claude/local/claude"))
    #expect(candidates.contains("\(home)/.local/bin/claude"))
}

@Test func candidatesSurviveAnAbsentPath() {
    let candidates = ClaudeExecutable.candidates(environment: [:], home: home)
    #expect(!candidates.isEmpty)
    #expect(candidates.contains("/opt/homebrew/bin/claude"))
}

@Test func candidatesAreDeduplicatedKeepingTheFirst() {
    // A user whose PATH already contains Homebrew shouldn't produce a list that
    // stats the same file twice.
    let candidates = ClaudeExecutable.candidates(
        environment: ["PATH": "/opt/homebrew/bin"], home: home)
    #expect(candidates.filter { $0 == "/opt/homebrew/bin/claude" }.count == 1)
}

@Test func emptyPathSegmentsAreIgnored() {
    // A trailing colon in PATH means "the current directory" to some shells.
    // Resolving ./claude from a Finder-launched app whose cwd is / is not
    // something to do quietly.
    let candidates = ClaudeExecutable.candidates(
        environment: ["PATH": "/usr/bin::"], home: home)
    #expect(!candidates.contains("/claude"))
    #expect(!candidates.contains("claude"))
}

// --- resolution ---

@Test func resolvePicksTheFirstExecutableCandidate() {
    let found = ClaudeExecutable.resolve(
        environment: ["PATH": "/nope:/usr/bin"], home: home,
        isExecutable: { $0 == "/usr/bin/claude" })
    #expect(found == "/usr/bin/claude")
}

@Test func resolveFallsThroughPathToAKnownLocation() {
    let found = ClaudeExecutable.resolve(
        environment: ["PATH": "/usr/bin"], home: home,
        isExecutable: { $0 == "/opt/homebrew/bin/claude" })
    #expect(found == "/opt/homebrew/bin/claude")
}

@Test func resolveReturnsNilWhenClaudeIsInstalledSomewhereUnknown() {
    // nvm, asdf, a custom prefix. The poll then does nothing, forever, and the
    // UI has to say so — this returning nil is the signal it uses.
    let found = ClaudeExecutable.resolve(
        environment: ["PATH": "/usr/bin"], home: home,
        isExecutable: { _ in false })
    #expect(found == nil)
}
