import Foundation

/// Whether `BurnlineProbe` may run the archive fill.
///
/// The probe drives the fill — uncovered ranges, fill, commit — to measure
/// what it costs on a real corpus. Against the live data directory that makes
/// it a second writer on `history/` while the app is running: `HistoryWriter`
/// serializes within a process only, and two processes appending to the same
/// JSONL files is the situation the single-instance guard exists to prevent.
///
/// So: free under `BURNLINE_DATA_DIR` (a scratch archive), and against live
/// data only when asked for by name. The read-back report runs either way.
public enum ProbeArchivePolicy {
    public static let fillKey = "BURNLINE_PROBE_FILL"

    public static func shouldFill(environment: [String: String]) -> Bool {
        if ApplicationSupport.isOverridden(environment: environment) { return true }
        return environment[fillKey].map { !$0.isEmpty } ?? false
    }
}
