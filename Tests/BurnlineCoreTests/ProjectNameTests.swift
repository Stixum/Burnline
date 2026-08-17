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
