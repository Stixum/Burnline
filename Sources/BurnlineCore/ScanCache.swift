import Foundation

/// What we know about one transcript file.
public struct FileState: Equatable, Sendable, Codable {
    public var modifiedAt: Date
    public var size: Int
    /// Byte offset of the end of the last *complete* line consumed.
    public var offset: Int
    /// Bucket key (as a string, so it survives JSON) → model → raw counts.
    ///
    /// Nested rather than a `"\(bucket)|\(model)"` composite: a delimiter
    /// appearing in a model id would silently corrupt the key.
    public var cells: [String: [String: TokenCounts]]

    public init(modifiedAt: Date = .distantPast, size: Int = 0, offset: Int = 0,
                cells: [String: [String: TokenCounts]] = [:]) {
        self.modifiedAt = modifiedAt
        self.size = size
        self.offset = offset
        self.cells = cells
    }
}

/// Persistent incremental scan state. Lives at
/// `~/Library/Application Support/Burnline/scan-cache.json`.
public struct ScanCache: Equatable, Sendable, Codable {
    public static let currentVersion = 2
    /// Files untouched for longer than this are dropped.
    public static let retention: TimeInterval = 14 * 86_400

    public var version: Int
    public var files: [String: FileState]

    public init(version: Int = ScanCache.currentVersion, files: [String: FileState] = [:]) {
        self.version = version
        self.files = files
    }

    public var isCompatible: Bool { version == Self.currentVersion }

    /// Total weighted units in `[start, end)`, weighted at READ time.
    ///
    /// Deliberately an explicit overload rather than a defaulted `weights:`
    /// parameter: a default argument generator is emitted into each *caller's*
    /// object file, so adding a default renames the symbol every caller
    /// references. This project has been bitten by exactly that before.
    public func units(from start: Date, to end: Date, weights: Weights) -> Double {
        let lower = Bucket.key(for: start)
        let upper = Bucket.key(for: end)
        let resolved = ConsumptionModel.ResolvedMultipliers(models: modelsPresent, weights: weights)
        var total = 0.0
        for state in files.values {
            for (rawKey, byModel) in state.cells {
                guard let key = Int(rawKey), key >= lower, key < upper else { continue }
                for (model, counts) in byModel {
                    total += ConsumptionModel.units(for: counts, multiplier: resolved[model],
                                                    weights: weights)
                }
            }
        }
        return total
    }

    /// Every model id in the cache, for one-shot multiplier resolution.
    var modelsPresent: Set<String> {
        var models = Set<String>()
        for state in files.values {
            for byModel in state.cells.values { models.formUnion(byModel.keys) }
        }
        return models
    }

    /// Drops files not modified since `cutoff`, and stale buckets inside the
    /// files that survive.
    ///
    /// If an evicted file is touched again it re-reads from zero; the buckets it
    /// recomputes fall outside any live window, so the double-read is harmless.
    ///
    /// The per-bucket half matters for the opposite case: a file appended to
    /// continuously never ages out, so without it that file's buckets would
    /// accumulate forever. Retention is longer than any window, so a bucket
    /// below the cutoff can never be counted again.
    public mutating func evict(before cutoff: Date) {
        let oldestKey = Bucket.key(for: cutoff)
        files = files.compactMapValues { state in
            guard state.modifiedAt >= cutoff else { return nil }
            var state = state
            state.cells = state.cells.filter { key, _ in
                guard let key = Int(key) else { return false }
                return key >= oldestKey
            }
            return state
        }
    }
}
