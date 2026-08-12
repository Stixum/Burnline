import Foundation
import BurnlineCore

// Claude Code pipes session JSON on stdin after every assistant response and
// renders whatever we print as the status line. Two jobs: capture the rate
// limits for Burnline.app, and print a line worth having.
//
// This process runs inside someone's terminal prompt. It must never exit
// non-zero and never write to stderr — Claude Code renders failures inline, on
// every single response. A missed capture is a minor inconvenience; a noisy
// failure is a serious one. Hence: no `try!`, no fatalError, no early exit.

// Claude Code may close the pipe before we write. Default SIGPIPE disposition
// kills the process with signal 13 — a non-zero exit, which this program is
// not allowed to produce.
signal(SIGPIPE, SIG_IGN)

// `readDataToEndOfFile()` raises an uncatchable Objective-C exception on a
// read failure (closed fd, a directory piped in, ...) — `try?` cannot catch
// it, and it crashes with a non-zero exit and a stderr backtrace. The
// throwing `readToEnd()` reports the same failures as a catchable Swift
// error instead.
let input = (try? FileHandle.standardInput.readToEnd()) ?? Data()

guard let payload = try? JSONDecoder().decode(StatuslinePayload.self, from: input) else {
    // Empty stdin, malformed JSON, a type mismatch, or a number too large for
    // Double all land here — the equivalent of the bash's `2>/dev/null ||
    // printf 'burnline'`.
    print(StatusLineRenderer.fallback)
    exit(0)
}

// Capture first, print second, and print even when the capture is skipped —
// the ordering the bash script had.
if let capture = payload.capture(capturedAt: Date().timeIntervalSince1970) {
    // Best-effort. A failed write must not cost the user their status line.
    try? RateLimitStore().save(capture)
}

print(StatusLineRenderer.render(payload))
exit(0)
