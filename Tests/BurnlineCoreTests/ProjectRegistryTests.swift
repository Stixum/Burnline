import Testing
import Foundation
@testable import BurnlineCore

// A project's name used to be derived again on every flush and fill, from
// whichever folders that path happened to hold: a parent was added only on a
// basename collision, so the name flipped as the set changed. Measured on a
// copy of the real archive, `ConcertTracker/iOS` and `iOS` were one project,
// and a bucket written twice across a flip was counted twice — dedupe keys on
// the name. The registry assigns a name once and never derives it again.

private func registry(_ names: [String: String] = [:]) -> ProjectRegistry {
    ProjectRegistry(names: names)
}

// MARK: - Write-once

@Test func aRegisteredNameNeverChangesWhenAnotherFolderSharesItsBasename() {
    var projects = registry()
    let first = projects.names(for: ["-p-foo-iOS": ["/p/foo/iOS"]], existing: { [] })
    #expect(first["-p-foo-iOS"] == "iOS")

    let second = projects.names(for: ["-p-foo-iOS": ["/p/foo/iOS"], "-p-bar-iOS": ["/p/bar/iOS"]],
                                existing: { [] })
    #expect(second["-p-foo-iOS"] == "iOS")
    #expect(second["-p-bar-iOS"] == "bar/iOS")
}

/// Contested within one batch, nobody wins the bare name arbitrarily: both
/// step up a level, as the old collision rule did.
@Test func foldersContestingOneNameInTheSameBatchBothStepUp() {
    var projects = registry()
    let names = projects.names(for: ["-a-iOS": ["/a/iOS"], "-b-iOS": ["/b/iOS"]], existing: { ["iOS"] })
    #expect(names["-a-iOS"] == "a/iOS")
    #expect(names["-b-iOS"] == "b/iOS")
}

// MARK: - Seeding from the archive

/// The rehearsal's regression: the cwd fix took `ConcertTracker/iOS` (3.16B
/// tokens of history) down to `iOS`. A folder seen for the first time keeps
/// the most specific name the archive already files its path under.
@Test func aNewFolderInheritsTheMostSpecificNameTheArchiveUsesForItsPath() {
    var projects = registry()
    let names = projects.names(
        for: ["-Users-me-projects-ConcertTracker-iOS": ["/Users/me/projects/ConcertTracker/iOS"]],
        existing: { ["iOS", "ConcertTracker/iOS", "Burnline"] })
    #expect(names["-Users-me-projects-ConcertTracker-iOS"] == "ConcertTracker/iOS")
}

/// The control: only a name that is a suffix of the real path is inherited.
/// The old split named worktrees by their last word and `TrainTimes-iOS` as
/// `TrainTimes/iOS`; carrying those forward would undo the cwd fix.
@Test func anArchivedNameThatIsNotASuffixOfThePathIsNotInherited() {
    var projects = registry()
    let worktree = "-Users-me-p--claude-worktrees-gallant-swanson-584f92"
    let names = projects.names(
        for: [worktree: ["/Users/me/p/.claude/worktrees/gallant-swanson-584f92"],
              "-Users-me-p-TrainTimes-iOS": ["/Users/me/p/TrainTimes-iOS"]],
        existing: { ["584f92", "TrainTimes/iOS", "iOS"] })
    #expect(names[worktree] == "gallant-swanson-584f92")
    #expect(names["-Users-me-p-TrainTimes-iOS"] == "TrainTimes-iOS")
}

// MARK: - Folders with no root, and plain names

/// No `cwd` re-encodes to the folder, so the name is a guess from the folder
/// alone — used, but not registered, so a later `cwd` can still correct it.
@Test func aFolderWithNoMatchingWorkingDirectoryIsNamedButNotRegistered() {
    var projects = registry()
    let guess = projects.names(for: ["-Users-me-p-train-times": []], existing: { [] })
    #expect(guess["-Users-me-p-train-times"] == "times")
    #expect(projects.names.isEmpty)

    let named = projects.names(for: ["-Users-me-p-train-times": ["/Users/me/p/train-times"]],
                               existing: { [] })
    #expect(named["-Users-me-p-train-times"] == "train-times")
    #expect(projects.names == ["-Users-me-p-train-times": "train-times"])
}

/// The guess does not depend on the set either: the longest archived name the
/// folder split ends with, else its last word.
@Test func anUnregisteredFolderKeepsAnArchivedNameItsSplitEndsWith() {
    var projects = registry()
    let names = projects.names(for: ["-Users-me-projects-ConcertTracker-iOS": [],
                                     "-Users-me-other-iOS": []],
                               existing: { ["iOS", "ConcertTracker/iOS"] })
    #expect(names["-Users-me-projects-ConcertTracker-iOS"] == "ConcertTracker/iOS")
    #expect(names["-Users-me-other-iOS"] == "iOS")
}

/// Anything without the leading `-` of an encoded absolute path is already a
/// name. Split on `-`, `web-app` would be renamed `app`.
@Test func aStringThatIsNotAnEncodedFolderIsAlreadyAName() {
    var projects = registry()
    let names = projects.names(for: ["web-app": []], existing: { [] })
    #expect(names["web-app"] == "web-app")
    #expect(projects.names.isEmpty)
}

/// Reading every cell file is the expensive part: only a folder that needs a
/// new name may cause it.
@Test func theArchiveIsReadOnlyWhenAFolderNeedsANewName() {
    var projects = registry(["-p-Burnline": "Burnline"])
    var reads = 0
    _ = projects.names(for: ["-p-Burnline": ["/p/Burnline"], "plain": []], existing: { reads += 1; return [] })
    #expect(reads == 0)
}
