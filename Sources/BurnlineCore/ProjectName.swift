import Foundation

/// Encoded transcript directory → display name.
///
/// Transcript directories are encoded absolute paths like
/// `-Users-seanmccauley-Projects-Burnline`. The archive stores the basename
/// (`Burnline`) — strictly less exposure than `scan-cache.json` already
/// carries (full absolute paths, a property examined and deliberately
/// accepted). A basename collision (two projects named `Analyzer` under
/// different parents) gains one parent path component so the two remain
/// distinguishable in the archive.
public enum ProjectName {
    public static func resolve(_ directories: some Sequence<String>) -> [String: String] {
        let components = directories.reduce(into: [String: [String]]()) { table, dir in
            table[dir] = dir.split(separator: "-").map(String.init)
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
}
