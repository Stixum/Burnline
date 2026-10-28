import Foundation

/// Encoded transcript folder → the project name the archive files it under,
/// **assigned once and never re-derived**. Lives at `history/projects.json`,
/// written only by `HistoryWriter`.
///
/// 🔴 Names used to be derived again on every flush and fill, from whichever
/// folders that path held: a parent was added only on a basename collision,
/// so a name flipped as the set changed. On a copy of the real archive
/// `ConcertTracker/iOS` and `iOS` were one project, and a bucket written twice
/// across a flip was counted twice — dedupe keys on the name. A name here, once
/// given, is never computed again.
public struct ProjectRegistry: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var names: [String: String]

    public init(version: Int = ProjectRegistry.currentVersion, names: [String: String] = [:]) {
        self.version = version
        self.names = names
    }

    public var isCompatible: Bool { version == Self.currentVersion }

    /// A name for every folder in `workingDirectories` (folder → the `cwd`
    /// values its transcripts named), registering the ones it can.
    ///
    /// - A registered folder keeps its name.
    /// - A string without the leading `-` of an encoded absolute path is
    ///   already a name, and passes through.
    /// - A folder with a root (a `cwd` that re-encodes to it) is registered:
    ///   the longest suffix of its path the archive already files cells under,
    ///   when no other folder in the batch claims the same one; else the
    ///   shortest suffix nobody holds, folders contesting one stepping up a
    ///   level together, as the old collision rule did.
    /// - A folder with no root gets a guess that does not depend on the set —
    ///   the longest archived name its folder split ends with, else its last
    ///   word — and is NOT registered, so a later `cwd` can still correct it.
    ///
    /// `existing` reads every cell file, so it is called only when some folder
    /// needs a new name.
    public mutating func names(for workingDirectories: [String: Set<String>],
                               existing: () -> Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        var unnamed: [(folder: String, suffixes: [String])] = []
        var guesses: [(folder: String, suffixes: [String])] = []

        for (folder, candidates) in workingDirectories {
            if let name = names[folder] {
                result[folder] = name
            } else if !folder.hasPrefix("-") {
                result[folder] = folder
            } else if let root = ProjectName.root(of: folder, among: candidates),
                      case let suffixes = ProjectName.suffixes(of: Self.components(root, "/")),
                      !suffixes.isEmpty {
                unnamed.append((folder, suffixes))
            } else {
                guesses.append((folder, ProjectName.suffixes(of: Self.components(folder, "-"))))
            }
        }
        guard !unnamed.isEmpty || !guesses.isEmpty else { return result }
        let archived = existing()

        for guess in guesses {
            result[guess.folder] = guess.suffixes.last(where: archived.contains)
                ?? guess.suffixes.first ?? "unknown"
        }

        var taken = Set(names.values)
        func assign(_ folder: String, _ name: String) {
            names[folder] = name
            result[folder] = name
            taken.insert(name)
        }

        // Seeds: the most specific name the archive already uses for this
        // path, unless another folder in the batch claims the same one.
        unnamed.sort { $0.folder < $1.folder }
        let seeds = unnamed.map { entry in
            entry.suffixes.last { archived.contains($0) && !taken.contains($0) }
        }
        var claims: [String: Int] = [:]
        for seed in seeds.compactMap({ $0 }) { claims[seed, default: 0] += 1 }
        var pending: [(folder: String, suffixes: [String])] = []
        for (entry, seed) in zip(unnamed, seeds) {
            if let seed, claims[seed] == 1 { assign(entry.folder, seed) } else { pending.append(entry) }
        }

        // Fresh: the shortest suffix nobody holds. Contested, everyone in the
        // contest steps up; a full path is unique, so this ends.
        var depth = 0
        while !pending.isEmpty {
            let candidates = pending.map { $0.suffixes[min(depth, $0.suffixes.count - 1)] }
            var counts: [String: Int] = [:]
            for candidate in candidates { counts[candidate, default: 0] += 1 }
            var next: [(folder: String, suffixes: [String])] = []
            for (entry, candidate) in zip(pending, candidates) {
                let free = !taken.contains(candidate) && counts[candidate] == 1
                if free || depth >= entry.suffixes.count - 1 {
                    assign(entry.folder, candidate)
                } else {
                    next.append(entry)
                }
            }
            pending = next
            depth += 1
        }
        return result
    }

    private static func components(_ path: String, _ separator: Character) -> [String] {
        path.split(separator: separator).map(String.init)
    }
}
