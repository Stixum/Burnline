import Foundation

/// The path arithmetic behind a project's name. Assigning names is
/// `ProjectRegistry`'s; this only answers questions about one folder.
///
/// Transcript folders are encoded absolute paths like
/// `-Users-me-Projects-Burnline`. The archive stores a short suffix of the
/// path (`Burnline`) — strictly less exposure than `scan-cache.json` already
/// carries (full absolute paths, a property examined and deliberately
/// accepted).
///
/// ⚠️ The encoding cannot be undone. Every character but an ASCII letter or
/// digit becomes `-`, so `train-times`, `train/times` and `train.times` all
/// encode alike, and splitting on `-` named a kebab-case project by its last
/// word. The path comes from the transcripts' own `cwd` instead, and only one
/// that re-encodes to the folder name counts: a session that `cd`s elsewhere
/// names that folder too.
enum ProjectName {
    /// The project root among `candidates`: the one that encodes to `folder`.
    /// Sorted, so the choice cannot depend on set order.
    static func root(of folder: String, among candidates: Set<String>) -> String? {
        candidates.sorted().first { encoded($0) == folder }
    }

    /// Every trailing run of `components`, shortest first:
    /// `["iOS", "ConcertTracker/iOS", "projects/ConcertTracker/iOS", …]`.
    static func suffixes(of components: [String]) -> [String] {
        components.indices.reversed().map { components[$0...].joined(separator: "/") }
    }

    /// Claude Code's folder name for a path. Observed for ASCII paths; per
    /// UTF-16 unit beyond that is an assumption (JavaScript's
    /// `replace(/[^a-zA-Z0-9]/g, "-")`), and getting it wrong only means the
    /// folder split is used instead.
    static func encoded(_ path: String) -> String {
        let dash = UInt16(UInt8(ascii: "-"))
        let units = path.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: unit
            default: dash
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
