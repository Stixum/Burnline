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

let scanner = TranscriptScanner(weights: settings.weights)

// Cold: empty cache, reads every retained file whole.
let coldStarted = Date()
let cache = try scanner.scan(cache: ScanCache(), now: now)
let elapsed = Date().timeIntervalSince(coldStarted)

// Warm: feed the cache back in. This is the path the app's 60s timer runs,
// so it is the number that decides whether the refresh interval is affordable.
let warmStarted = Date()
let warmCache = try scanner.scan(cache: cache, now: now)
let warmElapsed = Date().timeIntervalSince(warmStarted)
let drift = abs(warmCache.units(from: now.addingTimeInterval(-30 * 86_400), to: now)
    - cache.units(from: now.addingTimeInterval(-30 * 86_400), to: now))

// Same inputs the app uses, so the probe can diagnose what the app is doing —
// including the high-water reconciliation, without persisting a new mark.
let rawOnDisk = RateLimitStore().load()
// Same dating the app applies, so the probe reports what the app will show.
let onDisk = rawOnDisk.map { loaded in
    loaded.dated(mintedAt: loaded.transcriptPath.flatMap {
        TranscriptDating.mintedAt(transcriptPath: $0, observedAt: loaded.capturedAt)
    })
}
let storedMark = HighWaterStore().load()
let capture = onDisk.map { RateLimitHighWater.reconcile($0, against: storedMark).capture }

// Which evidence dated the reading. "wall clock" means neither rule applied and
// the figure is only as honest as the writing session was fresh.
var datingNote = "no capture"
if let raw = rawOnDisk {
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
