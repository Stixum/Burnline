import Foundation
import BurnlineCore

// Diagnostic only. Scans the real transcripts and prints a Snapshot.
let now = Date()
var settings = BurnlineSettings.default
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

let snapshot = SnapshotBuilder.build(cache: cache, settings: settings,
                                     now: now, isScanning: false)

func percent(_ value: Double?) -> String {
    value.map { String(format: "%.1f%%", $0) } ?? "—"
}

print("""
Burnline probe
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
""")
