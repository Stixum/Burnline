import Foundation
import Testing
@testable import BurnlineCore

struct ProjectNameTests {
    @Test func projectNameIsTheBasename() {
        let names = ProjectName.resolve(["-Users-seanmccauley-Projects-Burnline"])
        #expect(names["-Users-seanmccauley-Projects-Burnline"] == "Burnline")
    }

    @Test func collidingBasenamesGainOneParentComponent() {
        let names = ProjectName.resolve([
            "-Users-me-work-Analyzer",
            "-Users-me-personal-Analyzer",
        ])
        #expect(names["-Users-me-work-Analyzer"] == "work/Analyzer")
        #expect(names["-Users-me-personal-Analyzer"] == "personal/Analyzer")
    }

    @Test func degenerateDirectoryNameDoesNotCrash() {
        let names = ProjectName.resolve(["", "-"])
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
    let names = ProjectName.resolve(workingDirectories: [
        "-Users-me-Projects-train-times": ["/Users/me/Projects/train-times"],
    ])
    #expect(names["-Users-me-Projects-train-times"] == "train-times")
}

@Test func hyphenatedProjectsSharingABasenameStayApart() {
    let names = ProjectName.resolve(workingDirectories: [
        "-p-foo-x-api": ["/p/foo/x-api"],
        "-p-bar-x-api": ["/p/bar/x-api"],
    ])
    #expect(names["-p-foo-x-api"] == "foo/x-api")
    #expect(names["-p-bar-x-api"] == "bar/x-api")
}

/// A session that `cd`s into a subfolder names that subfolder too. Only the
/// path that encodes to the folder is the root; the rest are ignored.
@Test func aWorkingDirectoryThatIsNotTheRootIsIgnored() {
    let names = ProjectName.resolve(workingDirectories: [
        "-Users-me-Projects-train-times": ["/Users/me/Projects/train-times/Sources",
                                           "/Users/me/Projects/train-times"],
        "-Users-me-Projects-other-app": ["/Users/me/Projects/other-app/Sources"],
    ])
    #expect(names["-Users-me-Projects-train-times"] == "train-times")
    // No root among them: the folder name, split as before.
    #expect(names["-Users-me-Projects-other-app"] == "app")
}

@Test func spacesAndDotsInAProjectNameSurvive() {
    let names = ProjectName.resolve(workingDirectories: [
        "-Users-me-My-Project-v2": ["/Users/me/My Project.v2"],
    ])
    #expect(names["-Users-me-My-Project-v2"] == "My Project.v2")
}
