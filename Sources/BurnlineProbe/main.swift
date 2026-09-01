import Foundation
import BurnlineCore

// Diagnostic only. Scans the real transcripts and prints a Snapshot.
let now = Date()
// The user's real settings, not the defaults. The probe exists to say what the
// app is doing, and targetMode / dayBoundary / menuBarMode all change what it
// displays — reading defaults here made the probe disagree with the menu bar
// and quietly report against a target the user isn't using.
var settings = SettingsStore().load()
if let weekday = ProcessInfo.processInfo.environment["BURNLINE_WEEKDAY"].flatMap(Int.init) {
    settings.resetSchedule.weekday = weekday
}
if let hour = ProcessInfo.processInfo.environment["BURNLINE_HOUR"].flatMap(Int.init) {
    settings.resetSchedule.hour = hour
}

let scanner = TranscriptScanner()

// Cold: empty cache, reads every retained file whole.
let coldStarted = Date()
let cache = try scanner.scan(cache: ScanCache(), now: now)
let elapsed = Date().timeIntervalSince(coldStarted)

// Warm: feed the cache back in. This is the path the app's 60s timer runs,
// so it is the number that decides whether the refresh interval is affordable.
let warmStarted = Date()
let warmCache = try scanner.scan(cache: cache, now: now)
let warmElapsed = Date().timeIntervalSince(warmStarted)
let drift = abs(warmCache.units(from: now.addingTimeInterval(-30 * 86_400), to: now,
                                weights: settings.weights)
    - cache.units(from: now.addingTimeInterval(-30 * 86_400), to: now, weights: settings.weights))

// Same inputs the app uses, so the probe can diagnose what the app is doing —
// including the high-water reconciliation, without persisting a new mark.
// Exactly the resolution UsageStore performs, so the probe reports what the app
// will show. Reading only the shared file here would make the probe disagree
// with the app the moment two sessions are open — which is the case the
// per-session files exist for.
func date(_ loaded: RateLimitCapture) -> RateLimitCapture {
    loaded.dated(mintedAt: loaded.transcriptPath.flatMap {
        TranscriptDating.mintedAt(transcriptPath: $0, observedAt: loaded.capturedAt)
    })
}

// One formatter for every instant this probe prints, so two sections can never
// disagree about what a timestamp looks like.
let clock = DateFormatter()
clock.dateFormat = "yyyy-MM-dd HH:mm:ss"
func instant(_ date: Date) -> String { clock.string(from: date) }
func instant(_ seconds: TimeInterval) -> String { instant(Date(timeIntervalSince1970: seconds)) }

/// A loaded capture kept next to the file it came from — and next to its own
/// UNDATED self.
///
/// The undated copy is what the `dated by` line needs: `isRepublishedCache` is a
/// strict `<`, so a capture that has already been corrected reports `false` and
/// the replay rule would look like it never fired.
struct Loaded {
    enum Kind { case session, shared, utilization }
    let kind: Kind
    let label: String
    let raw: RateLimitCapture
}
func shortSession(_ id: String?) -> String { id.map { String($0.prefix(8)) } ?? "unknown" }

let sessionCaptures = CaptureDirectory().load()
let sharedCapture = RateLimitStore().load()
let utilization = UtilizationStore().load()
// ⚠️ The SAME order `UsageStore` assembles these in. Ranking breaks a complete
// tie on first-listed, so a different order here is a different winner there.
let loaded = sessionCaptures.map {
        Loaded(kind: .session, label: "session \(shortSession($0.sessionId))", raw: $0)
    }
    + [sharedCapture].compactMap { $0 }.map {
        Loaded(kind: .shared, label: "shared file", raw: $0)
    }
    + [utilization?.asCapture()].compactMap { $0 }.map {
        Loaded(kind: .utilization, label: "utilization", raw: $0)
    }
// ⚠️ Resolution goes through `CaptureSelection.resolve`, exactly as the app
// does. Wiring only `UsageStore` once left the probe disagreeing with the app in
// precisely the case the per-session files existed for; the same trap applies to
// the allowance-epoch filter, which changes which capture wins.
//
// `CaptureDirectory.freshest` is `internal` to `BurnlineCore` so that this file
// CANNOT rank the candidates for itself. That reminder is a compile error now
// rather than a comment someone has to read.
let storedMark = HighWaterStore().load()
let resolution = CaptureSelection.resolve(loaded.map { date($0.raw) }, against: storedMark)
let onDisk = resolution.onDisk
// 🔴 Correlation back to the file is by POSITION: `resolution.candidates` is
// index-parallel to what was handed in. This used to match on `sessionId`, and
// `sessionId` does not identify a candidate: it is nil on the
// `cachedUsageUtilization` capture always, and nil on the shared
// `rate-limits.json` whenever the payload that wrote it carried no `session_id`
// — the rollback script, or an older build still in someone's bundle. With both
// of those present, `first { $0.sessionId == winner.sessionId }` returns the
// shared file no matter which of the two actually won, and the `dated by` line
// then describes the wrong source. A diagnostic that names the wrong source is
// worse than none, because it is believed.
let sources = resolution.candidates.indices.map {
    (source: loaded[$0], candidate: resolution.candidates[$0])
}
let onDiskSource = sources.first { $0.candidate.isFreshestOnDisk }
let chosenSource = sources.first { $0.candidate.isSelected }
let capture = resolution.trusted

// Which evidence dated the reading. "wall clock" means neither rule applied and
// the figure is only as honest as the writing session was fresh.
var sourcesNote = sessionCaptures.isEmpty
    ? "shared file only"
    : "\(sessionCaptures.count) session file(s)"
        + (sharedCapture == nil ? "" : " + shared file")
// Figures only, never raw JSON: ~/.claude.json also holds hundreds of project
// paths, which for consultancy work are client names.
if let utilization {
    let age = DisplayValue.seconds(now.timeIntervalSince1970 - utilization.fetchedAt)
    sourcesNote += " + utilization (fetched \(age)s ago)"
} else {
    sourcesNote += " + no utilization block"
}

var datingNote = "no capture"
if let onDiskSource {
    let raw = onDiskSource.source.raw
    let session = shortSession(raw.sessionId)
    switch onDiskSource.source.kind {
    case .utilization:
        // Not a heuristic at all — this source states its own fetch time.
        datingNote = "explicit fetchedAtMs (~/.claude.json)"
    case .session, .shared:
        // `dated(mintedAt:)` stamps `provenAt` from an exact
        // `TranscriptDating.mintedAt` and from nothing else, so its presence on
        // a statusline capture IS the transcript rule having fired. Asking the
        // capture beats re-reading the transcript to ask the question twice.
        if onDiskSource.candidate.capture.provenAt != nil {
            datingNote = "transcript, session \(session)"
        } else if raw.isRepublishedCache {
            datingNote = "five-hour replay rule (no transcript evidence)"
        } else {
            datingNote = raw.sessionId == nil
                ? "wall clock — payload carried no session_id"
                : "wall clock — session \(session) transcript unreadable"
        }
    }
}
// 🔴 EVERY argument `UsageStore.rebuild` passes, passed here too — including
// `scopedWeekly`, which nothing in this file reads back off the snapshot.
//
// The rule is not "the probe computes the same numbers", it is that the probe
// must never DISAGREE with the app; a snapshot that is merely equivalent is how
// the next field gets threaded into one call site and not the other, silently,
// because nothing compares them. Two arguments differ on purpose and only two:
// `isScanning` is false because a CLI run has already finished scanning by the
// time it builds, and `now` is the single instant this run was pinned to — the
// same one the scan and the window used — where the app re-reads the clock on a
// 10s timer.
let snapshot = SnapshotBuilder.build(cache: cache, settings: settings,
                                     rateLimit: capture, now: now, isScanning: false,
                                     rejected: resolution.rejected,
                                     scopedWeekly: utilization?.scopedWeekly,
                                     regrant: resolution.regrant)

// The per-model weekly limit, read off the SNAPSHOT rather than off the
// `cachedUsageUtilization` block it came from. It is the row the popover
// renders, and reading the source directly is exactly how a probe keeps
// printing a figure the app has stopped being handed — the divergence this
// file exists to make impossible.
let scopedNote = snapshot.scopedWeekly.map {
    "\n  per-model        \($0.modelName) \($0.percent)% · \($0.severity)"
} ?? ""

func percent(_ value: Double?) -> String {
    value.map { String(format: "%.1f%%", $0) } ?? "—"
}

func describeSource(_ source: UsageSource) -> String {
    switch source {
    case .live(let at): return "live (captured \(DisplayValue.seconds(now.timeIntervalSince(at)))s ago)"
    case .calibrated:   return "calibrated (manual anchors)"
    case .paceOnly:     return "pace only"
    }
}

var captureNote = "none on disk"
if let capture {
    let inWindow = capture.capturedDate >= snapshot.window.start
        && capture.capturedDate < snapshot.window.end
    captureNote = "\(capture.sevenDay.usedPercent)% used, resets \(capture.sevenDay.resetsDate), "
        + "captured \(DisplayValue.seconds(now.timeIntervalSince(capture.capturedDate)))s ago, "
        + "inCurrentWindow=\(inWindow)"
}

// Every open Claude Code session overwrites rate-limits.json on its own timer,
// and an idle one keeps republishing the snapshot it started with. When these
// two disagree, a stale session wrote last.
//
// The rule is `RateLimitHighWater.rejection`, read off the resolution rather
// than restated here: it is directional now — a pre-re-grant replay is refused
// while reading HIGHER than what is shown — and a second copy would go stale.
var highWaterNote = "no mark yet"
if let onDisk {
    let raw = onDisk.sevenDay.usedPercent
    highWaterNote = resolution.rejected.map {
        "on disk \(raw)% -> REJECTED as stale, using \($0.usingPercent)%"
    } ?? "on disk \(raw)% accepted"
}

// The allowance re-issued mid-window. Absent almost always; when present it is
// what the extrapolation must measure from, so a disagreement between this and
// the window start is the thing to look at first.
//
// Both spellings are reported, because they can differ and the difference is
// itself the diagnosis. A mark outlives its own window — `reconcile` clears it
// only once a capture for a *different* window arrives — so `SnapshotBuilder`
// drops an epoch that started outside the window now on screen rather than
// measuring the extrapolation from an instant that is not in it. Printing only
// `snapshot.regrant` would show "none open" while the mark on disk plainly
// holds one, which reads as the epoch having been lost.
let epochNote: String
if let epoch = snapshot.regrant {
    epochNote = "opened \(instant(epoch.startedAt)) at \(percent(epoch.startPercent))"
} else if let held = resolution.regrant {
    epochNote = "none open — the mark holds one from \(instant(held.startedAt)) at "
        + "\(percent(held.startPercent)), outside the current window, so it is not applied"
} else {
    epochNote = "none open"
}

// First line, before anything else: which directory this run is reading and
// writing. `BURNLINE_DATA_DIR` is what makes the statusline helper safe to
// exercise, and a typo'd export fails by silently using live data — so the
// probe is the place to confirm the export landed *before* running the helper.
let dataDirectoryNote = ApplicationSupport.isOverridden()
    ? "\(ApplicationSupport.directory().path)   (BURNLINE_DATA_DIR override — not live data)"
    : "\(ApplicationSupport.directory().path)   (live data)"

print("""
Burnline probe
  data dir         \(dataDirectoryNote)
  capture          \(captureNote)
  read from        \(sourcesNote)\(scopedNote)
  dated by         \(datingNote)
  high water       \(highWaterNote)
  allowance epoch  \(epochNote)
  source           \(describeSource(snapshot.source))
  auto schedule    \(snapshot.isScheduleAutomatic)
  scanned          \(cache.files.count) files
  cold scan        \(String(format: "%.2f", elapsed))s   (empty cache, reads every retained file)
  warm scan        \(String(format: "%.3f", warmElapsed))s   (cache reused — the 60s timer's path)
  re-scan drift    \(String(format: "%.0f", drift))   (must be 0: a no-op scan may not change totals)
  window           \(snapshot.window.start) → \(snapshot.window.end)
  duration         \(String(format: "%.0f", snapshot.window.totalDuration / 3600))h
  day              \(String(format: "%.2f", snapshot.window.dayIndex)) of 7
  target           \(percent(snapshot.targetPercent))
  units in window  \(String(format: "%.0f", snapshot.unitsInWindow))
  estimated        \(percent(snapshot.estimatedPercent))
  projected        \(percent(snapshot.projectedPercent))
  pace-only        \(snapshot.isPaceOnly)
  5-hour           \(snapshot.fiveHour?.rowValue ?? "—")

menu bar, every format (against \(settings.targetMode.title.lowercased()))
\(MenuBarMode.allCases.map { mode in
    "  \(mode.title.padding(toLength: 16, withPad: " ", startingAt: 0))"
        + MenuBarFormatter.text(for: snapshot, target: settings.targetMode, display: mode)
}.joined(separator: "\n"))
""")

// MARK: - Capture resolution

// Which sources reported what, which one was trusted, and why — including what
// was refused, which is the half a "winner only" line cannot show. Every fact
// below is a field on a `CaptureSelection.Candidate`, decided by the same
// `resolve` call `UsageStore` makes. This target has no tests, so a rule written
// here would be a rule nothing can check; the formatting is all it may own.
func candidateRow(_ source: Loaded, _ candidate: CaptureSelection.Candidate) -> String {
    let notes = [candidate.isSelected ? "chosen" : nil,
                 candidate.isFreshestOnDisk ? "freshest on disk" : nil,
                 candidate.isEligible ? nil : "refused by the open epoch"]
        .compactMap { $0 }
    // Provenance, not age: `proven` is an explicit `fetchedAtMs` or an exact
    // transcript mint time, and only a proven date can demote a high-water mark
    // or clear the epoch bar. `inferred` means `capturedAt` is an upper bound
    // and nothing more.
    let dating = candidate.capture.provenAt.map { "proven \(instant($0))" } ?? "inferred"
    let tail = notes.joined(separator: " · ")
    // ⚠️ `padding(toLength:)` TRUNCATES what is too long rather than clipping
    // with a marker. Latent, not a bug: the four label shapes and `instant()`'s
    // fixed-width format all sit under both caps. Widen either and a row loses
    // characters silently.
    return source.label.padding(toLength: 20, withPad: " ", startingAt: 0)
        + String(format: "%6.1f%%  ", candidate.capture.sevenDay.usedPercent)
        // Padded only when something follows it, so an unremarkable row does not
        // trail twenty spaces into a terminal.
        + (tail.isEmpty ? dating : dating.padding(toLength: 28, withPad: " ", startingAt: 0) + tail)
}

let eligibleCount = resolution.candidates.filter(\.isEligible).count
let chosenNote: String
if let chosenSource {
    chosenNote = "\(chosenSource.source.label) — freshest of \(eligibleCount) eligible candidate(s)"
} else if resolution.trusted != nil {
    chosenNote = sources.isEmpty
        ? "the high-water mark, standing in — nothing on disk to choose from"
        : "the high-water mark, standing in — none of \(sources.count) candidate(s) "
            + "could be shown to postdate the open epoch"
} else {
    chosenNote = "nothing — no capture on disk and no mark to stand in"
}

print("""

capture resolution
  candidates       \(sources.count) loaded, \(eligibleCount) eligible
\(sources.isEmpty
    ? "                     (none — no session file, no shared file, no utilization block)"
    : sources.map { "                     " + candidateRow($0.source, $0.candidate) }
        .joined(separator: "\n"))
  chose            \(chosenNote)
""")

// MARK: - Threshold notifications

// What would fire right now, and why or why not — determined from the
// emissions of a real `NotificationDecision.evaluate` call, never by
// reimplementing its predicates. Thresholds are sanitized exactly as
// `UsageStore` sanitizes at load, so the numbers shown are the ones the app
// evaluates against. The app additionally gates on system notification
// authorization, which a CLI process cannot read — this reports the decision
// layer only.
let noteSettings = settings.notifications.sanitized()
let marks = NotificationMarksStore().load()
print("\nthreshold notifications")
print("  enabled          \(noteSettings.enabled ? "on" : "off")")
if noteSettings.enabled {
    print("  note             app also gates on notification permission (not readable here)")
    let (emissions, _) = NotificationDecision.evaluate(
        snapshot: snapshot, settings: noteSettings,
        targetMode: settings.targetMode, marks: marks)
    let firing = Set(emissions.map(\.signal))
    // "mark held" only when the mark genuinely suppresses this window at this
    // threshold — a stale mark from an old window, or one minted at a since-
    // edited threshold, is not holding anything and reads "armed".
    func describe(_ label: String, signal: NotificationDecision.Signal,
                  value: Double?, threshold: Double,
                  mark: NotificationMarks.Mark?, resetsAt: TimeInterval?,
                  epochStartedAt: TimeInterval?) {
        let padded = label.padding(toLength: 17, withPad: " ", startingAt: 0)
        let state: String
        if firing.contains(signal) {
            state = "WOULD FIRE"
        } else if value == nil {
            state = "silent (no reading)"
        } else if let resetsAt, let epochStartedAt,
                  NotificationMarks.suppresses(mark, resetsAt: resetsAt,
                                               threshold: threshold,
                                               epochStartedAt: epochStartedAt) {
            state = "fired this allowance (mark held)"
        } else {
            state = "armed"
        }
        let shown = value.map { "\(DisplayValue.whole($0))" } ?? "—"
        print("  \(padded)\(shown) vs \(DisplayValue.whole(threshold)) — \(state)")
    }
    // Re-derived mark keys: must match what `evaluate` records (weekly window
    // end for the weekly signals, the capture's own reset for five-hour) and
    // the epoch each records alongside it — the open re-grant when there is
    // one, otherwise the window's own start; the five-hour window's own start
    // for five-hour, never the weekly epoch.
    let weeklyReset = snapshot.window.end.timeIntervalSince1970
    let weeklyEpoch = (snapshot.regrant?.startedAt ?? snapshot.window.start)
        .timeIntervalSince1970
    // Points behind the target — negative while under budget.
    describe("behind-pace", signal: .behindPace,
             value: snapshot.delta(settings.targetMode).map { -$0 },
             threshold: noteSettings.behindPacePoints,
             mark: marks.behindPace, resetsAt: weeklyReset,
             epochStartedAt: weeklyEpoch)
    describe("weekly", signal: .weekly,
             value: snapshot.estimatedPercent,
             threshold: noteSettings.weeklyPercent,
             mark: marks.weekly, resetsAt: weeklyReset,
             epochStartedAt: weeklyEpoch)
    describe("five-hour", signal: .fiveHour,
             value: snapshot.fiveHour?.usedPercent,
             threshold: noteSettings.fiveHourPercent,
             mark: marks.fiveHour,
             resetsAt: snapshot.fiveHour?.resetsAt.timeIntervalSince1970,
             epochStartedAt: snapshot.fiveHour?.startedAt.timeIntervalSince1970)
}

// MARK: - Usage archive

// 🔴 The probe DRIVES the archive rather than describing it: it runs exactly
// the launch sequence `UsageStore.startHistoryFill()` runs — uncovered ranges,
// fill, commit — against the resolved data directory. A print-only version
// could not produce the figure this section exists for, which is what the fill
// actually costs in wall-clock seconds on a real corpus.
//
// Writes land wherever the first line said they would. Under
// `BURNLINE_DATA_DIR` that is a scratch archive; without it, the same files the
// app itself maintains.
let historyStore = HistoryStore(directory: ApplicationSupport.historyDirectory())
let writer = HistoryWriter(store: historyStore, schedule: settings.resetSchedule)
let fill = HistoryFill(rootURL: TranscriptScanner.defaultRoot)

let fillStarted = Date()
// One day past Claude Code's 30-day `cleanupPeriodDays` default, matching the app.
let horizon = Int(now.addingTimeInterval(-31 * 86_400).timeIntervalSince1970)
let uncovered = await writer.currentCoverage()
    .uncovered(from: horizon, through: Int(now.timeIntervalSince1970))

var filesOpened = 0
var truncatedRanges = 0
for range in uncovered {
    let result = try fill.cells(from: Date(timeIntervalSince1970: Double(range.lowerBound)),
                                to: Date(timeIntervalSince1970: Double(range.upperBound)))
    // No clamping here: the span reaches into the still-filling bucket on
    // purpose, and `HistoryWriter.commit` is the one place that trims it.
    await writer.commit(payload: .init(rows: result.rows, span: range,
                                       truncated: result.truncated),
                        filledBy: "fill", observation: nil)
    filesOpened += result.filesOpened
    if result.truncated { truncatedRanges += 1 }
}
let fillElapsed = Date().timeIntervalSince(fillStarted)

// Read back through the same store the app uses, so what is reported is what a
// reader gets — deduplicated, and with the unreadable lines counted rather than
// silently dropped.
let coverage = (try? historyStore.loadCoverage()) ?? Coverage(records: [])
let coveredRanges = coverage.ranges
let archiveStart = coveredRanges.first
    .map { Date(timeIntervalSince1970: Double($0.lowerBound)) }
let archived = (try? historyStore.rows(in: (archiveStart ?? now)...now)) ?? (rows: [], skipped: 0)
// Interior holes only. `gaps(in:)` clamps to the covered extent, so "not
// reached yet" at either end is excluded — these are the permanent ones.
let gaps = coverage.gaps(in: horizon...Int(now.timeIntervalSince1970))
let windowRows = ((try? historyStore.loadWindows()) ?? []).sorted { $0.start > $1.start }
let lastObservedReset = (try? historyStore.loadManifest())?.lastObservedReset

let stamp = DateFormatter()
stamp.dateFormat = "yyyy-MM-dd HH:mm"
func moment(_ seconds: Int) -> String {
    stamp.string(from: Date(timeIntervalSince1970: Double(seconds)))
}
func extent(_ range: ClosedRange<Int>) -> String {
    let days = Double(range.upperBound - range.lowerBound) / 86_400
    return "\(moment(range.lowerBound)) → \(moment(range.upperBound))"
        + String(format: "  (%.1fd)", days)
}
func indented(_ lines: [String], empty: String) -> String {
    lines.isEmpty ? empty : "\n" + lines.map { "                     \($0)" }.joined(separator: "\n")
}

print("""

usage archive
  archive dir      \(historyStore.directory.path)
  fill             \(String(format: "%.2f", fillElapsed))s   \
(\(uncovered.count) uncovered range(s), \(filesOpened) transcript file(s) opened\
\(truncatedRanges > 0 ? ", \(truncatedRanges) truncated" : ""))
  cell rows        \(archived.rows.count)
  skipped lines    \(archived.skipped)   (unreadable — never fatal, never silent)
  coverage begins  \(archiveStart.map(stamp.string(from:)) ?? "—   (nothing archived)")
  coverage         \(indented(coveredRanges.map(extent), empty: "none"))
  gaps             \(indented(gaps.map(extent), empty: "none"))
  last reset seen  \(lastObservedReset.map(stamp.string(from:)) ?? "—   (no capture has ever landed)")
  windows          \(windowRows.count) row(s)\
\(indented(windowRows.prefix(3).map { row in
    "\(stamp.string(from: row.start)) → \(stamp.string(from: row.end))"
        + "  \(row.boundsSource.rawValue)"
        + "  final \(row.finalPercent.map { String(format: "%.1f%%", $0) } ?? "—")"
}, empty: "   (none complete yet)"))
""")
