import Foundation

/// Encoded transcript directory → display name.
///
/// Transcript directories are encoded absolute paths like
/// `-Users-me-Projects-Burnline`. The archive stores the basename
/// (`Burnline`) — strictly less exposure than `scan-cache.json` already
/// carries (full absolute paths, a property examined and deliberately
/// accepted). A basename collision (two projects named `Analyzer` under
/// different parents) gains one parent path component so the two remain
/// distinguishable in the archive.
///
/// ⚠️ The encoding cannot be undone. Every character but an ASCII letter or
/// digit becomes `-`, so `train-times`, `train/times` and `train.times` all
/// encode alike, and splitting on `-` named a kebab-case project by its last
/// word. The path comes from the transcripts' own `cwd` instead, and only one
/// that re-encodes to the folder name counts: a session that `cd`s elsewhere
/// names that folder too. The folder split is the fallback when none does.
public enum ProjectName {
    /// Folder names alone, for callers with no transcript to read from.
    public static func resolve(_ directories: some Sequence<String>) -> [String: String] {
        resolve(workingDirectories: Dictionary(directories.map { ($0, Set<String>()) },
                                               uniquingKeysWith: { first, _ in first }))
    }

    /// Encoded folder → the `cwd` values its transcripts named.
    public static func resolve(workingDirectories: [String: Set<String>]) -> [String: String] {
        let components = workingDirectories.reduce(into: [String: [String]]()) { table, entry in
            let (dir, candidates) = entry
            // Sorted, so the choice cannot depend on set order.
            if let root = candidates.sorted().first(where: { encoded($0) == dir }) {
                table[dir] = root.split(separator: "/").map(String.init)
            } else {
                table[dir] = dir.split(separator: "-").map(String.init)
            }
        }
        var counts: [String: Int] = [:]
        for parts in components.values { counts[parts.last ?? "unknown", default: 0] += 1 }

        var result: [String: String] = [:]
        for (dir, parts) in components {
            let base = parts.last ?? "unknown"
            if counts[base, default: 0] > 1, parts.count >= 2 {
                result[dir] = "\(parts[parts.count - 2])/\(base)"
            } else {
                result[dir] = base
            }
        }
        return result
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
