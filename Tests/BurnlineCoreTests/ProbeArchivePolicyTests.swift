import Testing
@testable import BurnlineCore

// `BurnlineProbe` runs the launch fill — uncovered ranges, fill, commit — to
// measure what it costs on a real corpus. Against the live data directory that
// is a second writer on the archive while the app is running, which is the
// two-writer situation the single-instance guard exists to prevent. The fill
// is free to run against a scratch directory, and runs against live data only
// when asked for by name.

@Test func theFillRunsAgainstAScratchDataDirectory() {
    #expect(ProbeArchivePolicy.shouldFill(environment: [ApplicationSupport.overrideKey: "/tmp/x"]))
}

@Test func theFillIsSkippedAgainstLiveDataByDefault() {
    #expect(ProbeArchivePolicy.shouldFill(environment: [:]) == false)
    #expect(ProbeArchivePolicy.shouldFill(environment: [ApplicationSupport.overrideKey: ""]) == false)
}

@Test func theFillRunsAgainstLiveDataOnlyWhenAskedForByName() {
    #expect(ProbeArchivePolicy.shouldFill(environment: [ProbeArchivePolicy.fillKey: "1"]))
    #expect(ProbeArchivePolicy.shouldFill(environment: [ProbeArchivePolicy.fillKey: ""]) == false)
}
