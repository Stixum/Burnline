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
let sessionCaptures = CaptureDirectory().load()
let sharedCapture = RateLimitStore().load()
let utilization = UtilizationStore().load()
let allCandidates = sessionCaptures
    + [sharedCapture].compactMap { $0 }
    + [utilization?.asCapture()].compactMap { $0 }
let onDisk = CaptureDirectory.freshest(of: allCandidates.map(date))
let rawOnDisk = onDisk.flatMap { resolved in
    allCandidates.first { $0.sessionId == resolved.sessionId }
}
let storedMark = HighWaterStore().load()
let capture = onDisk.map { RateLimitHighWater.reconcile($0, against: storedMark).capture }

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
    if let scoped = utilization.scopedWeekly {
        sourcesNote += "\n  per-model        \(scoped.modelName) \(scoped.percent)% · \(scoped.severity)"
    }
} else {
    sourcesNote += " + no utilization block"
}

var datingNote = "no capture"
if let raw = rawOnDisk, raw == utilization?.asCapture() {
    // Not a heuristic at all — this source states its own fetch time.
    datingNote = "explicit fetchedAtMs (~/.claude.json)"
} else if let raw = rawOnDisk {
    let minted = raw.transcriptPath.flatMap {
        TranscriptDating.mintedAt(transcriptPath: $0, observedAt: raw.capturedAt)
    }
    let session = raw.sessionId.map { String($0.prefix(8)) } ?? "unknown"
    if minted != nil {
        datingNote = "transcript, session \(session)"
    } else if raw.isRepublishedCache {
        datingNote = "five-hour replay rule (no transcript evidence)"
    } else {
        datingNote = raw.sessionId == nil
            ? "wall clock — payload carried no session_id"
            : "wall clock — session \(session) transcript unreadable"
    }
}
let snapshot = SnapshotBuilder.build(cache: cache, settings: settings,
                                     rateLimit: capture, now: now, isScanning: false)

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
var highWaterNote = "no mark yet"
if let onDisk {
    let raw = onDisk.sevenDay.usedPercent
    let used = capture?.sevenDay.usedPercent ?? raw
    highWaterNote = used > raw
        ? "on disk \(raw)% -> REJECTED as stale, using \(used)%"
        : "on disk \(raw)% accepted"
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
  read from        \(sourcesNote)
  dated by         \(datingNote)
  high water       \(highWaterNote)
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
    let (emissions, _) = NotificationDecision.evaluate(
        snapshot: snapshot, settings: noteSettings,
        targetMode: settings.targetMode, marks: marks)
    let firing = Set(emissions.map(\.signal))
    // "mark held" only when the mark genuinely suppresses this window at this
    // threshold — a stale mark from an old window, or one minted at a since-
    // edited threshold, is not holding anything and reads "armed".
    func describe(_ label: String, signal: NotificationDecision.Signal,
                  value: Double?, threshold: Double,
                  mark: NotificationMarks.Mark?, resetsAt: TimeInterval?) {
        let padded = label.padding(toLength: 17, withPad: " ", startingAt: 0)
        let state: String
        if firing.contains(signal) {
            state = "WOULD FIRE"
        } else if value == nil {
            state = "silent (no reading)"
        } else if let resetsAt,
                  NotificationMarks.suppresses(mark, resetsAt: resetsAt,
                                               threshold: threshold) {
            state = "fired this window (mark held)"
        } else {
            state = "armed"
        }
        let shown = value.map { "\(DisplayValue.whole($0))" } ?? "—"
        print("  \(padded)\(shown) vs \(DisplayValue.whole(threshold)) — \(state)")
    }
    // Re-derived mark keys: must match what `evaluate` records (weekly window
    // end for the weekly signals, the capture's own reset for five-hour).
    let weeklyReset = snapshot.window.end.timeIntervalSince1970
    // Points behind the target — negative while under budget.
    describe("behind-pace", signal: .behindPace,
             value: snapshot.delta(settings.targetMode).map { -$0 },
             threshold: noteSettings.behindPacePoints,
             mark: marks.behindPace, resetsAt: weeklyReset)
    describe("weekly", signal: .weekly,
             value: snapshot.estimatedPercent,
             threshold: noteSettings.weeklyPercent,
             mark: marks.weekly, resetsAt: weeklyReset)
    describe("five-hour", signal: .fiveHour,
             value: snapshot.fiveHour?.usedPercent,
             threshold: noteSettings.fiveHourPercent,
             mark: marks.fiveHour,
             resetsAt: snapshot.fiveHour?.resetsAt.timeIntervalSince1970)
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
