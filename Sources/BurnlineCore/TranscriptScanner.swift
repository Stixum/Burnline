import Foundation

/// Walks Claude Code's transcripts and folds new bytes into a `ScanCache`.
///
/// A cold scan of ~2,900 files takes about 1.5 seconds; steady state re-reads
/// only appended bytes, which is why every refresh can afford to run.
public struct TranscriptScanner: Sendable {
    public let rootURL: URL
    public let weights: Weights

    public init(rootURL: URL = TranscriptScanner.defaultRoot, weights: Weights = .default) {
        self.rootURL = rootURL
        self.weights = weights
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    public func scan(cache incoming: ScanCache, now: Date) throws -> ScanCache {
        var cache = incoming.isCompatible ? incoming : ScanCache()
        let parser = TranscriptParser()
        var seen = Set<String>()

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            let path = url.path
            seen.insert(path)
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0

            var state = cache.files[path] ?? FileState()

            // A shrunken file was rewritten or truncated; its old buckets are
            // no longer trustworthy, so start it over.
            if size < state.offset {
                state = FileState()
            }

            // Untouched since last time — nothing to do.
            if state.modifiedAt == modifiedAt, state.size == size, state.offset > 0 {
                cache.files[path] = state
                continue
            }

            let (records, newOffset) = readAppended(at: url, from: state.offset, parser: parser)
            for record in records {
                let key = String(Bucket.key(for: record.timestamp))
                state.buckets[key, default: 0] += ConsumptionModel.units(for: record, weights: weights)
            }
            state.offset = newOffset
            state.size = size
            state.modifiedAt = modifiedAt
            cache.files[path] = state
        }

        // Forget files that no longer exist, then apply retention.
        cache.files = cache.files.filter { seen.contains($0.key) }
        cache.evict(before: now.addingTimeInterval(-ScanCache.retention))
        return cache
    }

    /// Reads from `offset` to the last complete line. Never advances past a
    /// partial trailing write — sessions are appended to live.
    private func readAppended(at url: URL, from offset: Int,
                              parser: TranscriptParser) -> ([UsageRecord], Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }

        if offset > 0 {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return ([], offset) }
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([], offset) }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], offset) }

        let complete = data[data.startIndex...lastNewline]
        return (parser.parse(Data(complete)), offset + complete.count)
    }
}
