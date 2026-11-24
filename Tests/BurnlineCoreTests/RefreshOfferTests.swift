import Testing
import Foundation
@testable import BurnlineCore

// A default install goes stale for anyone who works only in the desktop app:
// the status line helper runs only in terminal sessions, and the one thing that
// would refresh the figure without it is off by default. These tests pin the
// cause, then the offer that answers it, one state at a time: never chose,
// chose on, chose off, and stale.

private let hour: TimeInterval = 3_600
private let day: TimeInterval = 86_400

private func settingsJSON(extra: String = "") -> String {
    """
    {"resetSchedule":{"weekday":6,"hour":2,"minute":0,"timeZoneIdentifier":"America/Chicago"},
     "weights":{"input":1,"cacheWrite":1.25,"cacheRead":0.1,"output":5,"defaultMultiplier":1,
                "modelMultipliers":[{"match":"opus","multiplier":5}]},
     "calibrationAnchors":[],"launchAtLogin":true\(extra)}
    """
}

private func decoded(_ json: String) throws -> BurnlineSettings {
    try JSONDecoder().decode(BurnlineSettings.self, from: Data(json.utf8))
}

/// A live figure captured `age` ago, in a week that has not reset.
private func liveSnapshot(age: TimeInterval, block: AuthBlock.Kind? = nil) -> Snapshot {
    let now = Date()
    let start = now.addingTimeInterval(-4 * day)
    let window = Window(start: start, end: start.addingTimeInterval(7 * day), now: now)
    return Snapshot(window: window, targetPercent: 57, estimatedPercent: 40,
                    capturedPercent: 38, projectedPercent: nil, unitsInWindow: 0,
                    calibrationAge: nil, source: .live(capturedAt: now.addingTimeInterval(-age)),
                    isScanning: false,
                    authBlock: block.map { AuthBlock(kind: $0, detectedAt: now) })
}

private func paceOnlySnapshot(isScanning: Bool = false) -> Snapshot {
    let now = Date()
    let start = now.addingTimeInterval(-4 * day)
    let window = Window(start: start, end: start.addingTimeInterval(7 * day), now: now)
    return Snapshot(window: window, targetPercent: 57, estimatedPercent: nil,
                    projectedPercent: nil, unitsInWindow: 0, calibrationAge: nil,
                    source: .paceOnly, isScanning: isScanning)
}

private func quietHelper(for age: TimeInterval) -> StatuslineReport {
    let now = Date()
    return StatuslineReport(lastWrote: now.addingTimeInterval(-age), now: now)
}

// MARK: - The cause

/// The measured finding: with the settings a new install gets, nothing ever
/// refreshes the figure, however old it is. This stays true on purpose (the
/// refresh starts real Claude Code sessions, so it is never on unasked); the
/// offer below is what a user gets instead of silence.
@Test func aDefaultInstallNeverRefreshesHoweverOldTheFigureGets() {
    let now = Date()
    for age in [2 * hour, 3 * day, 22 * day] {
        #expect(!PollDecision.shouldPoll(
            enabled: BurnlineSettings.default.refreshesUsageAutomatically,
            anchorAge: age, lastPollAt: nil, consecutiveFailures: 0,
            interval: PollDecision.relaxed, now: now))
    }
    // No figure at all is the strongest case for a refresh, and still nothing.
    #expect(!PollDecision.shouldPoll(
        enabled: BurnlineSettings.default.refreshesUsageAutomatically,
        anchorAge: nil, lastPollAt: nil, consecutiveFailures: 0,
        interval: PollDecision.relaxed, now: now))
    // Positive control: the same ages do refresh once the setting is on.
    #expect(PollDecision.shouldPoll(enabled: true, anchorAge: 3 * day, lastPollAt: nil,
                                    consecutiveFailures: 0,
                                    interval: PollDecision.relaxed, now: now))
}

// MARK: - What the user has said

@Test func aNewInstallHasNeverChosen() {
    #expect(BurnlineSettings.default.refreshChoice == .neverChose)
    #expect(BurnlineSettings.default.refreshesUsageAutomatically == false)
}

/// Every settings file written before the offer existed lacks the answer. One
/// with the refresh off is treated as never asked: the setting is left exactly
/// as it is, and the offer may be shown once.
@Test func anExistingInstallWithRefreshOffHasNeverChosen() throws {
    let before = try decoded(settingsJSON(extra: #","refreshesUsageAutomatically":false"#))
    #expect(before.refreshChoice == .neverChose)
    #expect(before.refreshesUsageAutomatically == false)
    // Positive control: the file decoded rather than falling back.
    #expect(before.launchAtLogin == true)

    let older = try decoded(settingsJSON())
    #expect(older.refreshChoice == .neverChose)
}

/// The refresh is confirmed before it is ever enabled, so a file that has it on
/// is someone who chose it. They keep it, and are never asked.
@Test func anExistingInstallWithRefreshOnChoseOnAndKeepsIt() throws {
    let settings = try decoded(settingsJSON(extra: #","refreshesUsageAutomatically":true"#))
    #expect(settings.refreshChoice == .on)
    #expect(settings.refreshesUsageAutomatically == true)
}

@Test func choosingOnTurnsTheRefreshOnAndRecordsTheAnswer() {
    var settings = BurnlineSettings.default
    settings.chooseAutomaticRefresh(true)
    #expect(settings.refreshesUsageAutomatically == true)
    #expect(settings.refreshChoice == .on)
}

@Test func choosingOffLeavesTheRefreshOffAndRecordsTheAnswer() {
    var settings = BurnlineSettings.default
    settings.chooseAutomaticRefresh(false)
    #expect(settings.refreshesUsageAutomatically == false)
    #expect(settings.refreshChoice == .off)
}

/// On, then off again in Settings: that is an answer too, not a return to
/// "never asked".
@Test func turningTheRefreshOffAfterHavingItOnIsChoosingOff() {
    var settings = BurnlineSettings.default
    settings.chooseAutomaticRefresh(true)
    settings.chooseAutomaticRefresh(false)
    #expect(settings.refreshChoice == .off)
}

/// The answer has to outlive a relaunch, or "No thanks" means "ask me again
/// tomorrow".
@Test func theAnswerSurvivesASaveLoadRoundTrip() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("burnline-refresh-offer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SettingsStore(directory: directory)

    var declined = BurnlineSettings.default
    declined.chooseAutomaticRefresh(false)
    try store.save(declined)
    #expect(store.load().refreshChoice == .off)

    var accepted = BurnlineSettings.default
    accepted.chooseAutomaticRefresh(true)
    try store.save(accepted)
    #expect(store.load().refreshChoice == .on)
}

/// A value this version cannot read falls back for that field alone, like every
/// other optional setting: it must not reset the file.
@Test func anUnreadableAnswerFallsBackToNeverAskedAndKeepsTheRest() throws {
    let settings = try decoded(settingsJSON(extra: #","hasAnsweredRefreshOffer":"later""#))
    #expect(settings.refreshChoice == .neverChose)
    #expect(settings.launchAtLogin == true)
}

// MARK: - Never chose: when the offer appears

/// The stale state. A reading a day or more old, nothing set to refresh it, and
/// nobody has been asked.
@Test func aDayOldFigureIsOfferedARefreshWhenNobodyHasChosen() {
    let offer = RefreshOffer.resolve(choice: .neverChose, snapshot: liveSnapshot(age: 3 * day),
                                     helper: quietHelper(for: 22 * day), claudeFound: true)
    #expect(offer == .stale(age: 3 * day))
}

/// The threshold is a whole day: an evening away, or a night, is the ordinary
/// state of every install and is not worth a prompt.
@Test func aFigureUnderADayOldIsNotOfferedARefresh() {
    #expect(RefreshOffer.resolve(choice: .neverChose, figureAge: 23 * hour,
                                 helper: quietHelper(for: 23 * hour), isScanning: false,
                                 claudeFound: true, isAuthBlocked: false) == nil)
    #expect(RefreshOffer.resolve(choice: .neverChose, figureAge: RefreshOffer.threshold,
                                 helper: quietHelper(for: 23 * hour), isScanning: false,
                                 claudeFound: true, isAuthBlocked: false)
            == .stale(age: RefreshOffer.threshold))
}

/// An idle terminal republishes the reading it started with every 30 seconds,
/// forever, so the helper can be "reporting" while the figure is days old. The
/// offer follows the figure's age, not the helper's.
@Test func aStaleFigureIsOfferedARefreshEvenWhileAnIdleSessionKeepsReporting() {
    #expect(RefreshOffer.resolve(choice: .neverChose, figureAge: 2 * day,
                                 helper: quietHelper(for: 20), isScanning: false,
                                 claudeFound: true, isAuthBlocked: false) == .stale(age: 2 * day))
}

/// No figure at all, and the helper has never written: a new install used only
/// from the desktop app, which would otherwise wait for a report that never
/// comes.
@Test func noFigureAndAHelperThatNeverReportedIsOfferedARefresh() {
    let offer = RefreshOffer.resolve(choice: .neverChose, snapshot: paceOnlySnapshot(),
                                     helper: .never, claudeFound: true)
    #expect(offer == .noReading)
}

/// The same state a week later: the old reading died with its window, and the
/// helper has been quiet for more than a day.
@Test func noFigureAndAHelperQuietForADayIsOfferedARefresh() {
    #expect(RefreshOffer.resolve(choice: .neverChose, figureAge: nil,
                                 helper: quietHelper(for: 3 * day), isScanning: false,
                                 claudeFound: true, isAuthBlocked: false) == .noReading)
}

/// The morning after a reset, before the first response of the new week: the
/// helper wrote yesterday, so a terminal session is in use and a figure is on
/// its way. Not worth a prompt.
@Test func noFigureButAHelperThatReportedWithinTheDayIsNotOffered() {
    #expect(RefreshOffer.resolve(choice: .neverChose, figureAge: nil,
                                 helper: quietHelper(for: 15 * hour), isScanning: false,
                                 claudeFound: true, isAuthBlocked: false) == nil)
    #expect(RefreshOffer.resolve(choice: .neverChose, figureAge: nil,
                                 helper: quietHelper(for: 30), isScanning: false,
                                 claudeFound: true, isAuthBlocked: false) == nil)
}

/// Before the first capture load the helper's state is unknown, and during the
/// first scan the popover says "Scanning". Neither is "no reading".
@Test func nothingIsOfferedBeforeTheFirstLoadOrDuringTheFirstScan() {
    #expect(RefreshOffer.resolve(choice: .neverChose, figureAge: nil, helper: nil,
                                 isScanning: false, claudeFound: true,
                                 isAuthBlocked: false) == nil)
    #expect(RefreshOffer.resolve(choice: .neverChose, snapshot: paceOnlySnapshot(isScanning: true),
                                 helper: .never, claudeFound: true) == nil)
}

/// Turning it on would do nothing without Claude Code; Settings already says
/// where it looked.
@Test func nothingIsOfferedWhenClaudeCodeCannotBeFound() {
    #expect(RefreshOffer.resolve(choice: .neverChose, snapshot: liveSnapshot(age: 3 * day),
                                 helper: .never, claudeFound: false) == nil)
    #expect(RefreshOffer.resolve(choice: .neverChose, snapshot: paceOnlySnapshot(),
                                 helper: .never, claudeFound: false) == nil)
}

/// While Claude Code is signed out every refresh is gated, and the banner's
/// button is the one thing that helps. An offer beside it would send the user
/// to turn on something that cannot run.
@Test func nothingIsOfferedWhileAnAuthBlockIsShowing() {
    let blocked = liveSnapshot(age: 3 * day, block: .signedOut)
    #expect(blocked.isAuthBlocked)
    #expect(RefreshOffer.resolve(choice: .neverChose, snapshot: blocked,
                                 helper: .never, claudeFound: true) == nil)
}

// MARK: - Chose on, chose off: never asked

/// Positive control first, so the two refusals below are refusing something.
@Test func someoneWhoChoseOnIsNeverOffered() {
    let stale = liveSnapshot(age: 3 * day)
    #expect(RefreshOffer.resolve(choice: .neverChose, snapshot: stale,
                                 helper: .never, claudeFound: true) != nil)
    #expect(RefreshOffer.resolve(choice: .on, snapshot: stale,
                                 helper: .never, claudeFound: true) == nil)
    #expect(RefreshOffer.resolve(choice: .on, snapshot: paceOnlySnapshot(),
                                 helper: .never, claudeFound: true) == nil)
}

/// Declining is an answer. The figure may be a month old; the switch is in
/// Settings and the popover does not bring it up again.
@Test func someoneWhoChoseOffIsNeverOfferedAgain() {
    #expect(RefreshOffer.resolve(choice: .off, snapshot: liveSnapshot(age: 30 * day),
                                 helper: .never, claudeFound: true) == nil)
    #expect(RefreshOffer.resolve(choice: .off, snapshot: paceOnlySnapshot(),
                                 helper: .never, claudeFound: true) == nil)
}

// MARK: - Stale: what the app says

/// An old number is never dressed as a current one. Past the hour the footer
/// stops saying "Live" and gives the age; the menu bar marks the figure; the
/// amber line says how long it has been carried forward.
@Test func aStaleFigureSaysSoWithItsAge() {
    let stale = liveSnapshot(age: 3 * day)

    #expect(CaptureAge.sourceLabel(stale.liveAge) == "Extrapolated · 3d ago")
    #expect(stale.scarcityExplanation?.contains("Carried forward for 3d") == true)
    let menuBar = MenuBarFormatter.text(for: stale, target: .realTime, display: .usedOverTarget)
    #expect(menuBar.hasPrefix("~"), "the menu bar marks a figure that is no longer a reading")

    // Control: a fresh reading carries none of it.
    let fresh = liveSnapshot(age: 5 * 60)
    #expect(CaptureAge.sourceLabel(fresh.liveAge) == "Live · 5m ago")
    #expect(fresh.scarcityExplanation == nil)
    #expect(!MenuBarFormatter.text(for: fresh, target: .realTime,
                                   display: .usedOverTarget).hasPrefix("~"))
}

@Test func theFooterStopsSayingLiveExactlyWhereAFigureGoesStale() {
    #expect(CaptureAge.sourceLabel(CaptureAge.stalenessThreshold).hasPrefix("Live"))
    #expect(CaptureAge.sourceLabel(CaptureAge.stalenessThreshold + 1).hasPrefix("Extrapolated"))
}

// MARK: - The offer's words

/// The offer says what turning it on does, in the app's own terms, and that
/// nothing has been turned on yet.
@Test func theOfferSaysWhatItWouldDoAndThatNothingRunsYet() {
    for offer in [RefreshOffer.stale(age: 3 * day), .noReading] {
        #expect(offer.title == "Refresh automatically?")
        #expect(offer.detail.contains("desktop app"))
        #expect(offer.detail.contains("/usage"))
        #expect(offer.detail.contains("Claude Code session"))
        #expect(offer.detail.contains("Nothing runs until you turn it on"))
    }
    // The button opens a confirmation rather than acting: the ellipsis says so.
    #expect(RefreshOffer.acceptLabel == "Turn on…")
    #expect(RefreshOffer.declineLabel == "No thanks")
    #expect(RefreshOffer.declineHelp.contains("Settings"))
}

/// The two states do not share a first sentence: one has a figure that has gone
/// stale, the other has none to go stale.
@Test func theOfferNamesTheStateItIsAnswering() {
    #expect(RefreshOffer.stale(age: 3 * day).detail.contains("goes stale"))
    #expect(RefreshOffer.stale(age: 3 * day).detail.contains("keep it current"))
    #expect(RefreshOffer.noReading.detail.contains("no figure"))
    #expect(RefreshOffer.noReading.detail.contains("fetch one"))
    // There is nothing to keep current, and nothing that has gone stale.
    #expect(!RefreshOffer.noReading.detail.contains("goes stale"))
    #expect(!RefreshOffer.noReading.detail.contains("keep it current"))
}
