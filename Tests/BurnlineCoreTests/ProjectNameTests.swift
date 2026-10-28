import Foundation
import Testing
@testable import BurnlineCore

/// A first naming of `workingDirectories` against an empty archive: what every
/// folder below is called the first time it is seen.
private func firstNames(_ workingDirectories: [String: Set<String>]) -> [String: String] {
    var projects = ProjectRegistry()
    return projects.names(for: workingDirectories, existing: { [] })
}

struct ProjectNameTests {
    @Test func projectNameIsTheBasename() {
        let names = firstNames(["-Users-me-Projects-Burnline": ["/Users/me/Projects/Burnline"]])
        #expect(names["-Users-me-Projects-Burnline"] == "Burnline")
    }

    @Test func collidingBasenamesGainOneParentComponent() {
        let names = firstNames([
            "-Users-me-work-Analyzer": ["/Users/me/work/Analyzer"],
            "-Users-me-personal-Analyzer": ["/Users/me/personal/Analyzer"],
        ])
        #expect(names["-Users-me-work-Analyzer"] == "work/Analyzer")
        #expect(names["-Users-me-personal-Analyzer"] == "personal/Analyzer")
    }

    @Test func degenerateDirectoryNameDoesNotCrash() {
        let names = firstNames(["": [], "-": ["/"]])
        #expect(names[""] != nil)
        #expect(names["-"] != nil)
    }
}

// MARK: - Names from the transcript's own working directory

// Claude Code encodes the project path by turning every character but a letter
// or digit into "-", which cannot be undone: `train-times` and `train/times`
// encode alike. Split on "-", a kebab-case project was named by its last word.
// The transcripts carry the real path as `cwd`, and the one whose encoding
// reproduces the folder name is the project root.

@Test func aHyphenatedProjectIsNamedFromItsOwnWorkingDirectory() {
    let names = firstNames(["-Users-me-Projects-train-times": ["/Users/me/Projects/train-times"]])
    #expect(names["-Users-me-Projects-train-times"] == "train-times")
}

@Test func hyphenatedProjectsSharingABasenameStayApart() {
    let names = firstNames([
        "-p-foo-x-api": ["/p/foo/x-api"],
        "-p-bar-x-api": ["/p/bar/x-api"],
    ])
    #expect(names["-p-foo-x-api"] == "foo/x-api")
    #expect(names["-p-bar-x-api"] == "bar/x-api")
}

/// A session that `cd`s into a subfolder names that subfolder too. Only the
/// path that encodes to the folder is the root; the rest are ignored.
@Test func aWorkingDirectoryThatIsNotTheRootIsIgnored() {
    let names = firstNames([
        "-Users-me-Projects-train-times": ["/Users/me/Projects/train-times/Sources",
                                           "/Users/me/Projects/train-times"],
        "-Users-me-Projects-other-app": ["/Users/me/Projects/other-app/Sources"],
    ])
    #expect(names["-Users-me-Projects-train-times"] == "train-times")
    // No root among them: the folder name, split as before.
    #expect(names["-Users-me-Projects-other-app"] == "app")
}

@Test func spacesAndDotsInAProjectNameSurvive() {
    let names = firstNames(["-Users-me-My-Project-v2": ["/Users/me/My Project.v2"]])
    #expect(names["-Users-me-My-Project-v2"] == "My Project.v2")
}

/// Claude Code encodes the path as it was typed, and the transcripts record it
/// as it is: `-Users-me-projects-…` against `/Users/me/Projects/…` on this Mac.
/// macOS volumes are case-insensitive by default, so case is no evidence of a
/// different folder — and without the match the name fell back to a guess.
@Test func aRootDifferingOnlyInCaseIsStillTheRoot() {
    let names = firstNames([
        "-Users-me-projects-ConcertTracker-iOS": ["/Users/me/Projects/ConcertTracker-iOS",
                                                  "/Users/me/Projects/ConcertTracker-iOS/.superpowers/b2b"],
    ])
    #expect(names["-Users-me-projects-ConcertTracker-iOS"] == "ConcertTracker-iOS")
}

/// The control: an exact match wins over one that differs only in case.
@Test func anExactRootIsPreferredOverOneDifferingInCase() {
    let names = firstNames(["-p-Api": ["/p/API", "/p/Api"]])
    #expect(names["-p-Api"] == "Api")
}
