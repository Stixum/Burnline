import Foundation

public struct CacheStore: Sendable {
    private let url: URL

    public init(directory: URL = ApplicationSupport.directory()) {
        url = directory.appendingPathComponent("scan-cache.json")
    }

    /// A cache from an incompatible version is discarded rather than migrated —
    /// it rebuilds from the transcripts in a few seconds.
    public func load() -> ScanCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(ScanCache.self, from: data),
              cache.isCompatible
        else { return ScanCache() }
        return cache
    }

    public func save(_ cache: ScanCache) throws {
        try JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }
}
