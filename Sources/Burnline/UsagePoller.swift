import Foundation
import BurnlineCore

/// Refreshes the usage anchor by running `/usage` in a short-lived Claude Code
/// session.
///
/// **Why this is necessary at all.** A session's `rate_limits` refreshes only
/// when *that session* calls the API, and only sessions rendering a status line
/// publish. So an idle terminal republishes a two-hour-old reading every 30s
/// while a desktop session burns quota and never publishes. Measured
/// 2026-08-12: the menu bar sat on a stale 75% for 2h18m against a true 76%,
/// and nothing on the machine would have moved it.
///
/// **Why it costs nothing.** `/usage` refreshes `~/.claude.json`'s
/// `cachedUsageUtilization` — confirmed twice by watching `fetchedAtMs` move to
/// the second the command was sent — and produces **no assistant turn**: pty
/// sessions running only `/usage` left no transcript and no usage records.
///
/// ⚠️ **A pipe will not do.** Claude Code renders a status line only when it
/// believes it has a terminal, and it is the act of being a real session that
/// makes `/usage` available at all. Hence `openpty`.
@MainActor
final class UsagePoller {
    private var running: Process?

    /// Diagnostics for a path that is deliberately silent in normal operation:
    /// it runs behind the user's back and must never print. Without this the
    /// only symptom of a broken poll is a figure that quietly never refreshes,
    /// which is indistinguishable from the bug it exists to fix.
    ///
    /// `BURNLINE_POLL_LOG=/tmp/poll.log swift run Burnline`
    private static func log(_ message: String) {
        guard let path = ProcessInfo.processInfo.environment["BURNLINE_POLL_LOG"] else { return }
        let line = "\(Date()) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    /// Delegates to `ClaudeExecutable`, which lives in BurnlineCore so the
    /// not-found branch is covered by tests — the branch that will rot, and
    /// whose failure is otherwise invisible.
    private static func resolveClaude() -> String? { ClaudeExecutable.resolve() }

    /// How long to wait for the TUI to come up before sending the command, and
    /// how long to let it settle afterwards. Generous on purpose — a poll that
    /// fires too early does nothing, and the whole operation is invisible.
    /// Measured, not guessed: at 6s the command lands before Claude Code has
    /// finished booting (MCP servers, plugins, settings) and is simply lost —
    /// the poll ran, cleaned up, and refreshed nothing. The working manual
    /// harness waited ~25s. 18s clears it with margin; the whole operation is
    /// invisible and runs at most once every 15 minutes, so there is nothing to
    /// gain by being tight.
    private static let startupDelay: TimeInterval = 18
    /// `/usage` updates the cache within a second of registering, so this only
    /// has to cover the round trip.
    private static let settleDelay: TimeInterval = 8

    /// Refreshes the cache, or returns having done nothing. Never throws: this
    /// runs on a timer behind the user's back and a failure must cost nothing
    /// more than a stale figure, which is the state it was already in.
    func poll() async {
        Self.log("poll requested")
        guard running == nil else { Self.log("skipped: already running"); return }

        var primary: Int32 = 0
        var replica: Int32 = 0
        // ⚠️ The window size is not optional in practice. With a 0x0 terminal
        // the TUI never lays out, so the command written to the pty is simply
        // dropped — the poll runs, exits cleanly, and refreshes nothing, which
        // looks identical to the staleness bug it exists to fix.
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &replica, nil, nil, &size) == 0 else {
            Self.log("FAILED: openpty")
            return
        }

        guard let executable = Self.resolveClaude() else {
            Self.log("FAILED: claude not found on PATH or in any known location")
            close(primary)
            close(replica)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // Haiku so that if a future Claude Code version ever does make a model
        // call at startup, it is the cheapest one.
        process.arguments = ["--model", "haiku"]
        process.standardInput = FileHandle(fileDescriptor: replica)
        process.standardOutput = FileHandle(fileDescriptor: replica)
        process.standardError = FileHandle(fileDescriptor: replica)

        // ⚠️ Its own statusline captures go to a throwaway directory, never the
        // real one. A session start publishes a capture seeded from the cache
        // with NO transcript, so it gets dated by wall clock and looks fresh
        // whether or not it is — which would launder a stale reading as a new
        // one, the exact bug class this app spent 2026-08-12 removing. The poll
        // exists only to refresh ~/.claude.json, which carries its own honest
        // timestamp.
        var environment = ProcessInfo.processInfo.environment
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnline-poll-\(UUID().uuidString)")
        environment[ApplicationSupport.overrideKey] = scratch.path
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        // A Finder-launched app has cwd `/`, and an unfamiliar directory makes
        // Claude Code open a trust prompt — which would hang the session at a
        // dialog the user never sees. Home is already a known project.
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        do {
            try process.run()
            Self.log("launched pid \(process.processIdentifier): \(executable) --model haiku")
        } catch {
            Self.log("FAILED to launch \(executable): \(error)")
            close(primary)
            close(replica)
            return
        }
        running = process
        defer {
            running = nil
            try? FileManager.default.removeItem(at: scratch)
        }

        // The parent keeps only the primary side; holding the replica open would
        // stop the child ever seeing EOF.
        close(replica)
        defer { close(primary) }

        // ⚠️ **The pty MUST be drained, and not only for diagnostics.** A TUI
        // redraws constantly; the pty buffer is a few KB. Once it fills, the
        // child blocks on write and stops processing input — so the command
        // never registers and the poll refreshes nothing, silently. The manual
        // harness that proved this approach read continuously; this is the part
        // that was missing when the Swift version "ran" but did nothing.
        // `primary` is a mutable local; Swift 6 refuses to send that into a
        // detached task. Copy it first.
        let fd = primary
        let drain = Task.detached { () -> String in
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(fd, &buffer, buffer.count)
                guard n > 0 else { break }
                if output.count < 200_000 { output.append(contentsOf: buffer[0..<n]) }
            }
            return String(decoding: output, as: UTF8.self)
        }

        try? await Task.sleep(for: .seconds(Self.startupDelay))
        _ = "/usage\r".withCString { write(primary, $0, strlen($0)) }
        Self.log("sent /usage")
        try? await Task.sleep(for: .seconds(Self.settleDelay))
        Self.log("child still running: \(process.isRunning)")

        // Terminate, then make sure. Sessions accumulated to eight unnoticed
        // during the 2026-08-11 investigation; this one must never join them.
        process.terminate()
        try? await Task.sleep(for: .seconds(1))
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        if ProcessInfo.processInfo.environment["BURNLINE_POLL_LOG"] != nil {
            drain.cancel()
            let text = (try? await drain.value) ?? ""
            let plain = text
                .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "",
                                      options: .regularExpression)
                .split(separator: "\n").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            Self.log("tui tail: " + plain.suffix(6).joined(separator: " | ").suffix(600))
        }
    }
}
