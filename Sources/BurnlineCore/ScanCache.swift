import Foundation

/// What we know about one transcript file.
public struct FileState: Equatable, Sendable, Codable {
    public var modifiedAt: Date
    public var size: Int
    /// Byte offset of the end of the last *complete* line consumed.
    public var offset: Int
    /// Bucket key (as a string, so it survives JSON) → weighted units.
    public var buckets: [String: Double]

    public init(modifiedAt: Date = .distantPast, size: Int = 0, offset: Int = 0,
                buckets: [String: Double] = [:]) {
        self.modifiedAt = modifiedAt
        self.size = size
        self.offset = offset
        self.buckets = buckets
    }
}

/// Persistent incremental scan state. Lives at
/// `~/Library/Application Support/Burnline/scan-cache.json`.
public struct ScanCache: Equatable, Sendable, Codable {
    public static let currentVersion = 1
    /// Files untouched for longer than this are dropped.
    public static let retention: TimeInterval = 14 * 86_400

    public var version: Int
    public var files: [String: FileState]
    /// The weights the buckets were scored with.
    ///
    /// Buckets hold *weighted* units, so a cache says nothing about any other
    /// weight set — and the scale can't be recovered after the fact. `nil` means
    /// a cache written before this was tracked, which is equally unusable.
    public var weights: Weights?

    public init(version: Int = ScanCache.currentVersion, files: [String: FileState] = [:],
                weights: Weights? = nil) {
        self.version = version
        self.files = files
        self.weights = weights
    }

    public var isCompatible: Bool { version == Self.currentVersion }

    /// Total weighted units in `[start, end)`.
    public func units(from start: Date, to end: Date) -> Double {
        let lower = Bucket.key(for: start)
        let upper = Bucket.key(for: end)
        var total = 0.0
        for state in files.values {
            for (rawKey, units) in state.buckets {
                guard let key = Int(rawKey), key >= lower, key < upper else { continue }
                total += units
            }
        }
        return total
    }

    /// Drops files not modified since `cutoff`. If such a file is touched again
    /// it re-reads from zero; the buckets it recomputes fall outside any live
    /// window, so the double-read is harmless.
    public mutating func evict(before cutoff: Date) {
        files = files.filter { $0.value.modifiedAt >= cutoff }
    }
}
