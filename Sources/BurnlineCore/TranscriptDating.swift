import Foundation

/// When a session's `rate_limits` block was actually minted.
///
/// **The rule:** an assistant message *is* an API response, and `rate_limits`
/// refreshes only when that session calls the API. So the last assistant turn at
/// or before the moment the helper saw the payload is when the reading was
/// minted.
///
/// This is exact, where `RateLimitCapture.correctedForRepublishing` gives only an
/// upper bound. It also covers two cases that rule cannot see at all: plans that
/// never report `five_hour`, and a replay younger than five hours — which is
/// most of them, since a session republishes on a 30-second timer.
///
/// Deliberately not used by the `burnline-statusline` helper. This is file I/O,
/// and the helper runs every 30s inside every open session under a contract that
/// it never fails and never delays the user's prompt.
public enum TranscriptDating {
    /// Transcripts run to megabytes and only the end is interesting. 256 KB is
    /// thousands of lines; a session whose last assistant turn is further back
    /// than that has not called the API in a very long time, and returning `nil`
    /// there falls back correctly rather than guessing.
    static let tailBytes = 256 * 1024

    public static func mintedAt(transcriptPath: String,
                                observedAt: TimeInterval) -> TimeInterval? {
        guard let data = tail(of: URL(fileURLWithPath: transcriptPath)) else { return nil }

        // Reuse the shipped parser rather than adding a second JSON path: it
        // already filters to assistant lines carrying usage, handles both
        // ISO8601 shapes, and skips malformed lines silently.
        return TranscriptParser().parse(data)
            .map(\.timestamp.timeIntervalSince1970)
            .filter { $0 <= observedAt }
            .max()
    }

    /// The last `tailBytes`, advanced past the first newline so the parser never
    /// sees a partial line. The tail almost always starts mid-line, so this is
    /// the normal path rather than an edge case.
    private static func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return nil }

        // Read from the top: the first line is whole, keep it.
        guard start > 0 else { return data }
        guard let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return Data(data[(firstNewline + 1)...])
    }
}
